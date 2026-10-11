"""Streaming Whisper over WebSocket (Cloud Run GPU), for the app's "Whisper Live" tab.

Protocol (WS /stream, header `Authorization: Bearer <WHISPER_POC_TOKEN>`):
    client → {"type": "start", "terms": [...], "language": "en"}        (text, first message)
    client → <binary> 16 kHz mono PCM16 little-endian, any chunk size   (repeated)
    client → {"type": "stop"}                                            (text)
    server → {"type": "update", "committed": "...", "pending": "..."}   (as text firms up)
    server → {"type": "final", "text": "..."}                            (after stop, then close)

Whisper has no native streaming, so this uses the LocalAgreement-2 policy (as in ufal's
whisper_streaming): every ~1 s the recent audio is re-transcribed, and the words two consecutive
passes agree on are committed. Committed audio is trimmed from the buffer so each pass stays short.
Committed text is normalized with vocab.normalize; `pending` is the unconfirmed tail.
"""

import asyncio
import json
import os
import time

import numpy as np
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from faster_whisper import WhisperModel

import vocab

MODEL_PATH = os.environ.get("WHISPER_MODEL_PATH", "/opt/whisper-model")
POC_TOKEN = os.environ.get("WHISPER_POC_TOKEN", "")

SAMPLE_RATE = 16_000
MIN_NEW_AUDIO_S = 1.0       # re-transcribe once this much unprocessed audio has arrived
MAX_BUFFER_S = 20.0         # force-commit the hypothesis if the buffer grows past this
PROMPT_CONTEXT_CHARS = 200  # tail of committed text fed back as context

model = WhisperModel(MODEL_PATH, device="cuda", compute_type="float16")
# One GPU: serialize inference across connections.
gpu_lock = asyncio.Lock()
app = FastAPI()


@app.get("/health")
def health():
    return {"status": "ok"}


class StreamSession:
    def __init__(self, terms: list[str], language: str | None):
        self.terms = terms
        self.language = language or None
        self.vocab_prompt = vocab.build_prompt(terms)
        self.buffer = np.zeros(0, dtype=np.float32)
        self.buffer_offset_s = 0.0          # stream time of buffer[0]
        self.unprocessed_s = 0.0
        self.committed_words: list[str] = []
        self.committed_until_s = 0.0        # stream time up to which words are committed
        self.previous_hypothesis: list[tuple[float, float, str]] = []

    def add_audio(self, pcm16: bytes) -> None:
        samples = np.frombuffer(pcm16, dtype="<i2").astype(np.float32) / 32768.0
        self.buffer = np.concatenate([self.buffer, samples])
        self.unprocessed_s += len(samples) / SAMPLE_RATE

    @property
    def committed_text(self) -> str:
        return " ".join(self.committed_words)

    def _prompt(self) -> str:
        context = self.committed_text[-PROMPT_CONTEXT_CHARS:]
        return f"{self.vocab_prompt}. {context}".strip(". ") if context else self.vocab_prompt

    def _transcribe(self) -> list[tuple[float, float, str]]:
        segments, _ = model.transcribe(
            self.buffer,
            language=self.language,
            initial_prompt=self._prompt() or None,
            word_timestamps=True,
            beam_size=5,
            vad_filter=True,
            condition_on_previous_text=False,
        )
        words = []
        for segment in segments:
            for word in segment.words or []:
                start = self.buffer_offset_s + word.start
                end = self.buffer_offset_s + word.end
                # Skip words already committed (they're re-transcribed while still in the buffer).
                if end > self.committed_until_s + 0.05:
                    words.append((start, end, word.word.strip()))
        return words

    def process(self, final: bool = False) -> tuple[str, str]:
        """Runs one pass; returns (newly committed text, pending text)."""
        self.unprocessed_s = 0.0
        if len(self.buffer) < SAMPLE_RATE * 0.3:
            return "", ""

        hypothesis = self._transcribe()

        if final:
            agreed = hypothesis
        else:
            # LocalAgreement-2: commit the longest prefix both passes agree on.
            agreed = []
            for current, previous in zip(hypothesis, self.previous_hypothesis):
                if current[2].lower().strip(".,?!") != previous[2].lower().strip(".,?!"):
                    break
                agreed.append(current)
            if not agreed and self._buffer_seconds() > MAX_BUFFER_S:
                agreed = hypothesis[: max(1, len(hypothesis) - 2)]

        newly_committed = [w for _, _, w in agreed]
        if agreed:
            self.committed_words.extend(newly_committed)
            self.committed_until_s = agreed[-1][1]
            self._trim_buffer(self.committed_until_s)

        pending_words = hypothesis[len(agreed):]
        self.previous_hypothesis = pending_words
        pending = " ".join(w for _, _, w in pending_words)
        return " ".join(newly_committed), pending

    def _buffer_seconds(self) -> float:
        return len(self.buffer) / SAMPLE_RATE

    def _trim_buffer(self, until_s: float) -> None:
        cut = int((until_s - self.buffer_offset_s) * SAMPLE_RATE)
        if cut > 0:
            self.buffer = self.buffer[cut:]
            self.buffer_offset_s = until_s


def _normalized(session: StreamSession, text: str) -> str:
    return vocab.normalize(text, session.language, session.terms)


@app.websocket("/stream")
async def stream(websocket: WebSocket):
    if websocket.headers.get("authorization") != f"Bearer {POC_TOKEN}":
        await websocket.close(code=4401)
        return
    await websocket.accept()

    session: StreamSession | None = None
    try:
        while True:
            message = await websocket.receive()
            if message["type"] == "websocket.disconnect":
                return

            if message.get("bytes") is not None:
                if session is None:
                    continue
                session.add_audio(message["bytes"])
                if session.unprocessed_s >= MIN_NEW_AUDIO_S and not gpu_lock.locked():
                    start = time.perf_counter()
                    async with gpu_lock:
                        _, pending = await asyncio.to_thread(session.process)
                    await websocket.send_json({
                        "type": "update",
                        "committed": _normalized(session, session.committed_text),
                        "pending": _normalized(session, pending),
                        "inferenceMs": int((time.perf_counter() - start) * 1000),
                    })
                continue

            payload = json.loads(message.get("text") or "{}")
            if payload.get("type") == "start":
                terms = [t.strip() for t in payload.get("terms", []) if t.strip()]
                session = StreamSession(terms, payload.get("language", "en"))
            elif payload.get("type") == "stop" and session is not None:
                async with gpu_lock:
                    await asyncio.to_thread(session.process, True)
                await websocket.send_json({
                    "type": "final",
                    "text": _normalized(session, session.committed_text),
                })
                await websocket.close()
                return
    except WebSocketDisconnect:
        return
