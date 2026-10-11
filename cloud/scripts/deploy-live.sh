#!/bin/sh
# Deploys the Whisper Live streaming service (Cloud Run, 1x L4, scales to zero).
set -e
. "$(dirname "$0")/env.sh"
gcloud run deploy whisper-live --project=$PROJECT --region=asia-southeast1 \
  --image=asia-southeast1-docker.pkg.dev/speechpoc-whisper/whisper/whisper-server:v4 \
  --command=python --args="-m,uvicorn,stream_server:app,--host,0.0.0.0,--port,8080" --port=8080 \
  --gpu=1 --gpu-type=nvidia-l4 --no-gpu-zonal-redundancy --cpu=4 --memory=16Gi --no-cpu-throttling \
  --min-instances=0 --max-instances=1 --concurrency=4 --timeout=3600 --allow-unauthenticated \
  --set-secrets=WHISPER_POC_TOKEN=WHISPER_POC_TOKEN:latest \
  --startup-probe=tcpSocket.port=8080,initialDelaySeconds=0,periodSeconds=10,failureThreshold=24,timeoutSeconds=5
