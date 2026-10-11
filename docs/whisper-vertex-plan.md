# Whisper on Vertex AI — POC Plan

Goal: add a **Whisper** tab next to the existing **Local** (Apple SpeechAnalyzer) tab, so the same
spoken script and the same custom vocabulary can be compared side by side. POC only — throwaway,
not carried to the Azure implementation.

## Architecture

```
iOS app
 ├─ Tab "Local"   → SpeechAnalyzer on-device (existing)
 └─ Tab "Whisper" → record .m4a → POST /transcribe ──▶ Cloud Function (Firebase, 2nd gen)
                                                         │ service account auth
                                                         ▼
                                                  Vertex AI Endpoint
                                                  Whisper large-v3 on 1× L4 GPU
```

- Shared `VocabularyStore` feeds both tabs. Whisper receives it as the `prompt` (initial prompt).
- The iOS app never holds Google credentials. The function authenticates to Vertex with its
  service account and checks a simple shared POC token from the app.

## Decisions (please confirm / change)

| # | Decision | Default |
|---|---|---|
| D1 | New GCP/Firebase project ID | `speechpoc-whisper` (suffix added if taken) |
| D2 | Region | `asia-southeast1` (Singapore); fallback `us-central1` if no L4 quota/capacity |
| D3 | Model | Model Garden **Whisper large-v3** first; fall back to custom `faster-whisper` container if the vocabulary prompt isn't supported (see Phase 3 gate) |
| D4 | Machine | `g2-standard-8` + 1× NVIDIA L4, min=max=1 replica |
| D5 | App → function auth | Shared bearer token (Secret Manager on server, gitignored `.xcconfig` in app). No App Check for the POC |
| D6 | Recording mode | Record whole utterance, upload on Stop (no live streaming) |

## Phases

### Phase 0 — Prerequisites (you)
Things I can't/shouldn't do for you:
1. **Install gcloud** (not on this machine): `brew install --cask google-cloud-sdk`
2. **Log in**: `gcloud auth login` and `gcloud auth application-default login` (browser sign-in).
3. **Link billing** to the new project after I create it (Console → Billing). Vertex GPUs and
   Cloud Functions both need the Blaze/billing-enabled plan.
4. **GPU quota**: new projects often have **0 L4 quota** for Vertex online prediction. If the deploy
   fails with a quota error, request `Custom model serving L4 GPUs per region` = 1 in IAM → Quotas
   (approval can take minutes to a day+). This is the most likely blocker.

### Phase 1 — Project setup (me, after your OK)
1. Create Firebase/GCP project `speechpoc-whisper` (Firebase MCP).
2. *(you link billing)*
3. Enable APIs: `aiplatform`, `cloudfunctions`, `cloudbuild`, `run`, `artifactregistry`,
   `secretmanager`.
4. `firebase init functions` (TypeScript) in `cloud/` of this repo; add `.firebaserc`.

### Phase 2 — Deploy Whisper to Vertex (me)
1. Deploy Whisper large-v3 from Model Garden to a new endpoint (`gcloud ai model-garden models deploy`,
   or console one-click if CLI path is unavailable).
2. Record endpoint ID + region in `cloud/README.md`.
3. Smoke-test with `curl … :predict` using a short sample `.wav`.

### Phase 3 — Vocabulary gate (me, reported to you)
Send the same clip with and without the vocabulary prompt
(`Paiza Chairman, Paiza Diamond, Sands Lifestyle, SRC, Sands Rewards Club, GRA`).
- **Prompt accepted & affects output** → continue with Model Garden.
- **Not supported** → build a small `faster-whisper` + FastAPI container (`cloud/whisper-server/`)
  via Cloud Build, upload as a Vertex Model, deploy to the same kind of endpoint. Same downstream
  steps. (+~1–2 h of work)

### Phase 4 — `transcribe` Cloud Function (me)
- `POST /transcribe` — multipart: `audio` (m4a/wav, ≤ 25 MB), `prompt` (string).
- Checks `Authorization: Bearer <POC token>` (Secret Manager `WHISPER_POC_TOKEN`).
- Base64-encodes audio → Vertex `:predict` → returns `{ "text": "...", "latencyMs": n }`.
- Region same as endpoint; timeout 120 s; memory 1 GiB.

### Phase 5 — iOS changes (me)
1. `VocabularyStore` (@Observable), shared by both tabs; `SpeechTranscriptionModel` reads from it.
2. `ContentView` → `LocalTranscriptionView`; new `RootTabView` with **Local** / **Whisper** tabs.
3. `WhisperTranscriptionModel`: mic permission, `AVAudioRecorder` (AAC, mono, 16 kHz),
   multipart upload via `URLSession`, states `isRecording` / `isUploading` / `errorMessage`.
4. `WhisperTranscriptionView`: same layout as Local + latency label.
5. `Config.xcconfig` (gitignored) with `WHISPER_BASE_URL` and `WHISPER_POC_TOKEN`, read via Info.plist.

Note: this machine only has Command Line Tools selected (`xcodebuild` unavailable), so you'll build
& run on device from Xcode; I'll keep changes compile-clean by inspection.

### Phase 6 — Test & compare (you + me)
Same script on both tabs; compare vocabulary hit rate and latency.

## Cost & teardown
- L4 endpoint bills **every hour it's deployed, even idle** (roughly ~$1–1.5/h; check current
  Vertex pricing for your region). Functions/Build/Storage are pennies.
- After each test session: undeploy the model from the endpoint (I'll add
  `cloud/scripts/undeploy.sh` and `redeploy.sh`).
- End of POC: delete the project.

## What I need from you to start
1. Approve / edit decisions D1–D6.
2. Phase 0 steps 1–2 (gcloud install + login).
3. OK to create the project (Phase 1.1), then link billing.
