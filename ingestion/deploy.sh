#!/usr/bin/env bash
# Deploy the ingestion as a gen2 Cloud Function and schedule it every 5 minutes.
# Usage:  PROJECT_ID=your-project ./deploy.sh
set -euo pipefail

: "${PROJECT_ID:?set PROJECT_ID, e.g. PROJECT_ID=my-proj ./deploy.sh}"
REGION="${REGION:-us-central1}"
RAW_BUCKET="${RAW_BUCKET:-$PROJECT_ID-crypto-raw}"
BQ_DATASET="${BQ_DATASET:-crypto_raw}"        # prod dataset by default
FUNCTION_NAME="crypto-ingest"
SCHEDULER_JOB="crypto-ingest-5min"

echo "==> Deploying Cloud Function '$FUNCTION_NAME' ..."
gcloud functions deploy "$FUNCTION_NAME" \
  --gen2 \
  --runtime=python311 \
  --region="$REGION" \
  --source=. \
  --entry-point=ingest \
  --trigger-http \
  --no-allow-unauthenticated \
  --memory=256Mi \
  --timeout=120s \
  --set-env-vars="GCP_PROJECT=$PROJECT_ID,RAW_BUCKET=$RAW_BUCKET,BQ_DATASET=$BQ_DATASET" \
  --project="$PROJECT_ID"

FUNCTION_URI=$(gcloud functions describe "$FUNCTION_NAME" \
  --gen2 --region="$REGION" --project="$PROJECT_ID" \
  --format='value(serviceConfig.uri)')
echo "==> Function URI: $FUNCTION_URI"

# A dedicated service account lets Scheduler call the private function securely.
SA_NAME="crypto-scheduler"
SA_EMAIL="$SA_NAME@$PROJECT_ID.iam.gserviceaccount.com"
if ! gcloud iam service-accounts describe "$SA_EMAIL" --project="$PROJECT_ID" >/dev/null 2>&1; then
  echo "==> Creating scheduler service account ..."
  gcloud iam service-accounts create "$SA_NAME" \
    --display-name="Crypto ingest scheduler" --project="$PROJECT_ID"
fi
# Allow that SA to invoke the function.
gcloud run services add-iam-policy-binding "$FUNCTION_NAME" \
  --region="$REGION" --project="$PROJECT_ID" \
  --member="serviceAccount:$SA_EMAIL" \
  --role="roles/run.invoker" >/dev/null

echo "==> Creating/updating Cloud Scheduler job (every 5 min) ..."
if gcloud scheduler jobs describe "$SCHEDULER_JOB" --location="$REGION" --project="$PROJECT_ID" >/dev/null 2>&1; then
  ACTION=update
else
  ACTION=create
fi
gcloud scheduler jobs "$ACTION" http "$SCHEDULER_JOB" \
  --location="$REGION" \
  --schedule="*/5 * * * *" \
  --uri="$FUNCTION_URI" \
  --http-method=POST \
  --oidc-service-account-email="$SA_EMAIL" \
  --oidc-token-audience="$FUNCTION_URI" \
  --project="$PROJECT_ID"

echo "==> Done. The function now runs every 5 minutes."
echo "    Watch logs:  gcloud functions logs read $FUNCTION_NAME --gen2 --region=$REGION"
