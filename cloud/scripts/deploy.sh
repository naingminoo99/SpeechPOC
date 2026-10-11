#!/bin/sh
# Deploys the Whisper model onto the endpoint (1x L4). Billing starts now; run undeploy.sh when done.
set -e
. "$(dirname "$0")/env.sh"

MODEL_ID=$(gcloud ai models list --region=$REGION --project=$PROJECT \
  --filter="displayName=$MODEL_NAME" --format="value(name)" 2>/dev/null | head -1)
if [ -z "$MODEL_ID" ]; then
  echo "Uploading model $MODEL_NAME…"
  gcloud ai models upload --region=$REGION --project=$PROJECT --display-name=$MODEL_NAME \
    --container-image-uri=$IMAGE --container-ports=8080 \
    --container-health-route=/health --container-predict-route=/predict
  MODEL_ID=$(gcloud ai models list --region=$REGION --project=$PROJECT \
    --filter="displayName=$MODEL_NAME" --format="value(name)" | head -1)
fi

echo "Deploying model $MODEL_ID to endpoint $ENDPOINT_ID (takes ~10–20 min)…"
gcloud ai endpoints deploy-model $ENDPOINT_ID --region=$REGION --project=$PROJECT \
  --model=$MODEL_ID --display-name=$MODEL_NAME \
  --machine-type=g2-standard-8 --accelerator=type=nvidia-l4,count=1 \
  --min-replica-count=1 --max-replica-count=1 --traffic-split=0=100
