#!/usr/bin/env bash
# Env-aware deploy of the gen2 Cloud Function + Cloud Scheduler.
#
# Usage:
#   ENV=prod    PROJECT_ID=crypto-pipeline-prod-260528 ./deploy.sh   # 5-min schedule
#   ENV=staging PROJECT_ID=crypto-pipeline-stg-260528  ./deploy.sh   # scheduler PAUSED
#
# Dev intentionally has NO deployed function — developers run `python main.py`
# locally with .env pointing at the dev project.
#
# The function + scheduler service accounts already exist in the project
# (created by Terraform in PR C). This script only deploys the code + job.
set -euo pipefail
export PATH="$HOME/google-cloud-sdk/bin:$PATH"

: "${ENV:?set ENV=staging or ENV=prod}"
: "${PROJECT_ID:?set PROJECT_ID to the GCP project id for this env}"
case "$ENV" in
  staging|prod) ;;
  *) echo "ENV must be staging or prod (got: $ENV)"; exit 1 ;;
esac

REGION="${REGION:-us-central1}"
RAW_BUCKET="${RAW_BUCKET:-$PROJECT_ID-crypto-raw}"
BQ_DATASET="${BQ_DATASET:-crypto_raw}"
FUNCTION_NAME="crypto-ingest"
SCHEDULER_JOB="crypto-ingest-${ENV}"

# Different ingestion cadences per env:
#   prod:    every 5 min   (continuous)
#   staging: every 6 h, but PAUSED on create — operators trigger via
#            `gcloud scheduler jobs run`. Keeps the deploy path validated
#            without burning quota.
if [ "$ENV" = "prod" ]; then
  SCHEDULE="*/5 * * * *"
  PAUSE_AFTER_CREATE=false
else
  SCHEDULE="0 */6 * * *"
  PAUSE_AFTER_CREATE=true
fi

RUNTIME_SA="crypto-ingest-fn@${PROJECT_ID}.iam.gserviceaccount.com"
SCHEDULER_SA="crypto-scheduler@${PROJECT_ID}.iam.gserviceaccount.com"

echo "==> Deploying function $FUNCTION_NAME to project $PROJECT_ID ..."
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
  --run-service-account="$RUNTIME_SA" \
  --set-env-vars="GCP_PROJECT=$PROJECT_ID,RAW_BUCKET=$RAW_BUCKET,BQ_DATASET=$BQ_DATASET" \
  --project="$PROJECT_ID"

FUNCTION_URI=$(gcloud functions describe "$FUNCTION_NAME" \
  --gen2 --region="$REGION" --project="$PROJECT_ID" \
  --format='value(serviceConfig.uri)')
echo "==> Function URI: $FUNCTION_URI"

# Allow the scheduler SA to invoke this function.
gcloud run services add-iam-policy-binding "$FUNCTION_NAME" \
  --region="$REGION" --project="$PROJECT_ID" \
  --member="serviceAccount:$SCHEDULER_SA" \
  --role="roles/run.invoker" >/dev/null

echo "==> Creating/updating scheduler $SCHEDULER_JOB (schedule: $SCHEDULE) ..."
if gcloud scheduler jobs describe "$SCHEDULER_JOB" --location="$REGION" --project="$PROJECT_ID" >/dev/null 2>&1; then
  ACTION=update
else
  ACTION=create
fi
gcloud scheduler jobs "$ACTION" http "$SCHEDULER_JOB" \
  --location="$REGION" \
  --schedule="$SCHEDULE" \
  --uri="$FUNCTION_URI" \
  --http-method=POST \
  --oidc-service-account-email="$SCHEDULER_SA" \
  --oidc-token-audience="$FUNCTION_URI" \
  --project="$PROJECT_ID"

if [ "$PAUSE_AFTER_CREATE" = "true" ] && [ "$ACTION" = "create" ]; then
  echo "==> Pausing scheduler (staging is operator-triggered) ..."
  gcloud scheduler jobs pause "$SCHEDULER_JOB" --location="$REGION" --project="$PROJECT_ID" >/dev/null
fi

echo "==> Done. ENV=$ENV   schedule=$SCHEDULE   paused=$PAUSE_AFTER_CREATE"
echo "    Logs:   gcloud functions logs read $FUNCTION_NAME --gen2 --region=$REGION --project=$PROJECT_ID"
echo "    Manual: gcloud scheduler jobs run $SCHEDULER_JOB --location=$REGION --project=$PROJECT_ID"
