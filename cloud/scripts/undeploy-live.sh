#!/bin/sh
# Deletes the Whisper Live Cloud Run service so its GPU can't bill. Bring it back with deploy-live.sh.
set -e
. "$(dirname "$0")/env.sh"
gcloud run services delete whisper-live --project=$PROJECT --region=asia-southeast1 --quiet
