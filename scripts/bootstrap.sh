#!/usr/bin/env bash
# Reproduce the ENTIRE project on a fresh GCP project, in one command.
# Idempotent: safe to re-run; each phase checks before acting.
#
# Prerequisites (one-time, interactive — see scripts/install-tools.sh):
#   - tools installed: gcloud, terraform (~/bin), gh, and .venv with dbt+deps
#   - authenticated:   gcloud auth login && gcloud auth application-default login && gh auth login
#
# Usage:
#   PROJECT_ID=crypto-pipeline-$(date +%y%m%d)-$RANDOM \
#   BILLING_ACCOUNT_ID=XXXXXX-XXXXXX-XXXXXX \
#   ./scripts/bootstrap.sh
#
# Optional env: REGION (us-central1), LOCATION (US), BUDGET_AMOUNT (80000 — native currency
# of your billing account; use 5 for a USD account), GITHUB_REPO (crypto-pipeline).

set -euo pipefail
export PATH="$HOME/google-cloud-sdk/bin:$HOME/bin:$PATH"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

: "${PROJECT_ID:?set PROJECT_ID}"
: "${BILLING_ACCOUNT_ID:?set BILLING_ACCOUNT_ID (gcloud billing accounts list)}"
REGION="${REGION:-us-central1}"
LOCATION="${LOCATION:-US}"
BUDGET_AMOUNT="${BUDGET_AMOUNT:-80000}"     # native currency; budget currency MUST match the account
GITHUB_REPO="${GITHUB_REPO:-crypto-pipeline}"
BUCKET="$PROJECT_ID-crypto-raw"
PY="$REPO_ROOT/.venv/bin/python"
DBT="$REPO_ROOT/.venv/bin/dbt"

echo "########## Bootstrap: $PROJECT_ID ##########"

# ── Phase 1: project + billing + APIs ────────────────────────────────────────
echo "==> [1] Project, billing, APIs"
if ! gcloud projects describe "$PROJECT_ID" >/dev/null 2>&1; then
  gcloud projects create "$PROJECT_ID" --name="crypto-pipeline-learn"
fi
gcloud billing projects link "$PROJECT_ID" --billing-account="$BILLING_ACCOUNT_ID" >/dev/null
gcloud config set project "$PROJECT_ID" >/dev/null
gcloud auth application-default set-quota-project "$PROJECT_ID" >/dev/null 2>&1 || true
gcloud services enable \
  storage.googleapis.com bigquery.googleapis.com \
  cloudfunctions.googleapis.com cloudscheduler.googleapis.com run.googleapis.com \
  cloudbuild.googleapis.com artifactregistry.googleapis.com eventarc.googleapis.com \
  billingbudgets.googleapis.com --project="$PROJECT_ID"

# ── Phase 2: $5 budget (skip if one already targets this project) ────────────
echo "==> [2] Budget alert (~budget $BUDGET_AMOUNT in account currency)"
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')
if ! gcloud billing budgets list --billing-account="$BILLING_ACCOUNT_ID" \
      --format='value(budgetFilter.projects)' 2>/dev/null | grep -q "projects/$PROJECT_NUMBER"; then
  gcloud billing budgets create --billing-account="$BILLING_ACCOUNT_ID" \
    --display-name="crypto-pipeline-learn (~\$5)" \
    --budget-amount="$BUDGET_AMOUNT" \
    --threshold-rule=percent=0.5 --threshold-rule=percent=0.9 --threshold-rule=percent=1.0 \
    --filter-projects="projects/$PROJECT_NUMBER" >/dev/null
  echo "    budget created"
else
  echo "    budget already exists for this project — skipping"
fi

# ── Phase 3: infrastructure (bucket + 5 datasets) ────────────────────────────
echo "==> [3] Terraform (bucket + 5 datasets)"
( cd terraform
  printf 'project_id = "%s"\nregion     = "%s"\nlocation   = "%s"\n' \
    "$PROJECT_ID" "$REGION" "$LOCATION" > terraform.tfvars
  terraform init -input=false >/dev/null
  terraform apply -auto-approve -input=false >/dev/null )
echo "    infra applied"

# ── Phase 4: seed raw tables (dev + prod) so dbt source() has data ───────────
echo "==> [4] Seed raw tables (crypto_raw_dev + crypto_raw)"
for ds in crypto_raw_dev crypto_raw; do
  GCP_PROJECT="$PROJECT_ID" RAW_BUCKET="$BUCKET" BQ_DATASET="$ds" "$PY" ingestion/main.py
done

# ── Phase 5: GitHub repo (create + push main if no remote yet) ───────────────
echo "==> [5] GitHub repo"
if [ ! -d .git ]; then git init -b main >/dev/null && git add -A && git commit -q -m "Initial commit"; fi
if ! git remote get-url origin >/dev/null 2>&1; then
  gh repo create "$GITHUB_REPO" --private --source=. --remote=origin --push
else
  git push -u origin main 2>/dev/null || true
fi

# ── Phase 6: CI service account + GitHub secrets ─────────────────────────────
echo "==> [6] CI service account + GitHub secrets"
CI_SA="dbt-ci@$PROJECT_ID.iam.gserviceaccount.com"
if ! gcloud iam service-accounts describe "$CI_SA" --project="$PROJECT_ID" >/dev/null 2>&1; then
  gcloud iam service-accounts create dbt-ci --display-name="dbt CI" --project="$PROJECT_ID"
fi
for role in roles/bigquery.dataEditor roles/bigquery.jobUser roles/bigquery.dataOwner; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:$CI_SA" --role="$role" --condition=None >/dev/null
done
# storage on the bucket for the Slim CI manifest (read on PR, write on prod)
gcloud storage buckets add-iam-policy-binding "gs://$BUCKET" \
  --member="serviceAccount:$CI_SA" --role=roles/storage.objectAdmin >/dev/null
TMPKEY="$(mktemp)"
gcloud iam service-accounts keys create "$TMPKEY" --iam-account="$CI_SA" >/dev/null 2>&1
gh secret set GCP_PROJECT --body "$PROJECT_ID" >/dev/null
gh secret set GCP_SA_KEY < "$TMPKEY" >/dev/null
rm -f "$TMPKEY"
echo "    secrets set (key deleted locally)"

# ── Phase 7: deploy the 5-min automation (creates runtime SA + scheduler) ────
echo "==> [7] Deploy Cloud Function + Scheduler"
( cd ingestion && PROJECT_ID="$PROJECT_ID" REGION="$REGION" RAW_BUCKET="$BUCKET" bash deploy.sh )

# ── Phase 8: verify (don't trust 'deployed' — trust rows) ────────────────────
echo "==> [8] Verify"
gcloud scheduler jobs run crypto-ingest-5min --location="$REGION" --project="$PROJECT_ID" >/dev/null 2>&1 || true
echo "    raw prod snapshots:"
bq query --use_legacy_sql=false --project_id="$PROJECT_ID" --format=pretty \
  "SELECT COUNT(*) AS rows_total, COUNT(DISTINCT ingested_at) AS snapshots
   FROM \`$PROJECT_ID.crypto_raw.prices\`" || true

echo
echo "########## Done. ##########"
echo "Final state: bucket + 5 datasets, 5-min ingestion running, GitHub repo with CI/CD."
echo "Trigger the dbt prod build by pushing a dbt change (CI runs PR->staging->prod)."
echo "Pause ingestion:  gcloud scheduler jobs pause crypto-ingest-5min --location=$REGION"
