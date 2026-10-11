#!/bin/sh
# Removes the model from the endpoint so the GPU stops billing. The model and image are kept.
set -e
. "$(dirname "$0")/env.sh"

for ID in $(gcloud ai endpoints describe $ENDPOINT_ID --region=$REGION --project=$PROJECT \
    --format="value(deployedModels[].id)" | tr ';' ' '); do
  echo "Undeploying $ID…"
  gcloud ai endpoints undeploy-model $ENDPOINT_ID --region=$REGION --project=$PROJECT --deployed-model-id=$ID
done
echo "Nothing deployed — GPU billing stopped."
