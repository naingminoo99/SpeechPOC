# Whisper POC — cloud side

POC only. GCP project `speechpoc-whisper`, function in `asia-southeast1`, Vertex endpoint in `us-central1` (Singapore had no L4 capacity).

```
iOS Whisper tab ──m4a + terms──▶ Cloud Function `transcribe` ──▶ Vertex endpoint `whisper-poc`
                                  (POC bearer token)               faster-whisper large-v3-turbo, 1× L4
```

| Piece | Where |
|---|---|
| Function URL | `https://asia-southeast1-speechpoc-whisper.cloudfunctions.net/transcribe` |
| Vertex endpoint | `5382659723533221888` (`whisper-poc`, us-central1) |
| Image | `asia-southeast1-docker.pkg.dev/speechpoc-whisper/whisper/whisper-server:v3` |
| Live streaming (Whisper Live tab) | Cloud Run `whisper-live`, asia-southeast1, 1× L4, scales to zero — `wss://whisper-live-760247120919.asia-southeast1.run.app/stream` |
| POC token | Secret Manager `WHISPER_POC_TOKEN`; local copy in `cloud/.secret.local` (gitignored) |

- `whisper-server/` — FastAPI + faster-whisper container. `vocab.py` builds the initial prompt from
  the app's terms (seed list fallback) and normalizes output (mishearings, ZH aliases, fuzzy match).
  Response includes `raw_text` so the effect of normalization is visible.
- `whisper-server/stream_server.py` — WebSocket streaming (same image, run on Cloud Run). Re-transcribes
  recent audio ~1×/s and commits words two passes agree on (LocalAgreement-2).
- `functions/` — Node proxy: checks the token, base64s the audio, calls Vertex `:predict`.
  Recordings are capped at ~1 MB (~4 min at 32 kbps) by Vertex's 1.5 MB request limit.

## Day-to-day

```sh
scripts/deploy.sh      # put the model on the GPU (~15 min). Billing starts.
scripts/undeploy.sh    # take it off — do this after every test session
scripts/test.sh clip.m4a
```

The Vertex L4 bills every hour it's deployed, idle or not. The Cloud Run `whisper-live` service scales to
zero ~15 min after the last connection (first connect after that is a ~30–60 s cold start). Delete the project when the POC ends.

## Rebuilding the server

```sh
cd whisper-server
gcloud builds submit --region=asia-southeast1 --config=cloudbuild.yaml \
  --substitutions=_IMAGE=asia-southeast1-docker.pkg.dev/speechpoc-whisper/whisper/whisper-server:vN .
# then bump IMAGE / MODEL_NAME in scripts/env.sh, undeploy.sh, deploy.sh
```

## iOS

`SpeechPOC/WhisperSecrets.swift` (gitignored) holds the function URL and token — template in
`WhisperSecrets.swift.example`.
