"""Whisper (faster-whisper) serving container for a Vertex AI endpoint.

Request  (POST $AIP_PREDICT_ROUTE):
    {"instances": [{"audio_b64": "<base64 m4a/wav/...>", "terms": ["Paiza", ...], "language": "en"}]}
Response:
    {"predictions": [{"text": "...", "raw_text": "...", "prompt": "...", "language": "en",
                      "duration": 3.2, "inference_ms": 410}]}

`terms` (or the seed list in vocab.py when empty) becomes Whisper's initial_prompt, biasing decoding
towards the custom vocabulary; the transcript is then normalized by vocab.normalize (known
mishearings, ZH aliases, fuzzy snapping to vocabulary). `raw_text` is Whisper's unmodified output.
"""

import base64
import io
import os
import time

from fastapi import FastAPI, HTTPException
from faster_whisper import WhisperModel
from pydantic import BaseModel

import vocab

MODEL_DIR = os.environ.get("WHISPER_MODEL_PATH", "/opt/whisper-model")
HEALTH_ROUTE = os.environ.get("AIP_HEALTH_ROUTE", "/health")
PREDICT_ROUTE = os.environ.get("AIP_PREDICT_ROUTE", "/predict")

model = WhisperModel(MODEL_DIR, device="cuda", compute_type="float16")
app = FastAPI()


class Instance(BaseModel):
    audio_b64: str
    terms: list[str] = []
    language: str | None = "en"


class PredictRequest(BaseModel):
    instances: list[Instance]


@app.get(HEALTH_ROUTE)
def health():
    return {"status": "ok"}


@app.post(PREDICT_ROUTE)
def predict(request: PredictRequest):
    predictions = []
    for instance in request.instances:
        try:
            audio = io.BytesIO(base64.b64decode(instance.audio_b64))
        except ValueError as error:
            raise HTTPException(status_code=400, detail=f"Invalid audio_b64: {error}")

        terms = [t.strip() for t in instance.terms if t.strip()]
        prompt = vocab.build_prompt(terms)

        start = time.perf_counter()
        segments, info = model.transcribe(
            audio,
            language=instance.language or None,
            initial_prompt=prompt or None,
            beam_size=5,
            vad_filter=True,
        )
        raw_text = " ".join(segment.text.strip() for segment in segments).strip()
        predictions.append({
            "text": vocab.normalize(raw_text, info.language, terms),
            "raw_text": raw_text,
            "prompt": prompt,
            "language": info.language,
            "duration": round(info.duration, 2),
            "inference_ms": int((time.perf_counter() - start) * 1000),
        })
    return {"predictions": predictions}
