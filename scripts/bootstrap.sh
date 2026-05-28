#!/usr/bin/env bash
# Multi-project bootstrap for the Level-3 crypto-pipeline.
#
# Creates 4 GCP projects (infra + dev + staging + prod), enables APIs,
# sets budgets, creates the tfstate bucket, then applies Terraform per env.
# Idempotent — safe to re-run.
#
# Prerequisites (one-time, interactive):
#   - scripts/install-tools.sh has been run (gcloud, terraform, dbt-bigquery, gh)
#   - gcloud auth login && gcloud auth application-default login
#   - gh auth login
#
# Required env:
#   BILLING_ACCOUNT_ID=XXXXXX-XXXXXX-XXXXXX   (gcloud billing accounts list)
#
# Optional env (with defaults):
#   PROJECT_SUFFIX=$(date +%y%m%d)            # appended to all 4 project ids
#   REGION=us-central1
#   LOCATION=US                               # multi-region for BQ + GCS
#   BUDGET_AMOUNT=80000                       # in your billing account's native currency
#                                              # (80,000 IDR ≈ $5; for a USD account use 5)
#   GITHUB_REPO=edwinrdrr/crypto-pipeline

set -euo pipefail
export PATH="$HOME/google-cloud-sdk/bin:$HOME/bin:$PATH"

: "${BILLING_ACCOUNT_ID:?set BILLING_ACCOUNT_ID (run: gcloud billing accounts list)}"
PROJECT_SUFFIX="${PROJECT_SUFFIX:-$(date +%y%m%d)}"
REGION="${REGION:-us-central1}"
LOCATION="${LOCATION:-US}"
BUDGET_AMOUNT="${BUDGET_AMOUNT:-80000}"
GITHUB_REPO="${GITHUB_REPO:-edwinrdrr/crypto-pipeline}"

INFRA_PROJECT="crypto-pipeline-infra-$PROJECT_SUFFIX"
DEV_PROJECT="crypto-pipeline-dev-$PROJECT_SUFFIX"
STG_PROJECT="crypto-pipeline-stg-$PROJECT_SUFFIX"
PROD_PROJECT="crypto-pipeline-prod-$PROJECT_SUFFIX"
TFSTATE_BUCKET="${INFRA_PROJECT}-tfstate"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

echo "##########  Level-3 bootstrap  ##########"
echo "  infra:   $INFRA_PROJECT"
echo "  dev:     $DEV_PROJECT"
echo "  staging: $STG_PROJECT"
echo "  prod:    $PROD_PROJECT"
echo "  tfstate: gs://$TFSTATE_BUCKET"
echo

# ── helpers ─────────────────────────────────────────────────────────────────
create_project() {
  local p=$1 name=$2
  if ! gcloud projects describe "$p" >/dev/null 2>&1; then
    echo "==> creating project $p"
    gcloud projects create "$p" --name="$name"
  else
    echo "    project $p already exists — skipping create"
  fi
  # Only attempt link if not already linked — re-linking an already-linked project
  # is counted as a fresh "link attempt" by the billing API and fails when the
  # account is at its project-link quota.
  if gcloud billing projects describe "$p" --format='value(billingEnabled)' 2>/dev/null | grep -q "True"; then
    echo "    billing already linked for $p — skipping"
  else
    echo "    linking billing for $p"
    gcloud billing projects link "$p" --billing-account="$BILLING_ACCOUNT_ID" >/dev/null
  fi
}

ensure_budget() {
  local p=$1
  local pn ; pn=$(gcloud projects describe "$p" --format='value(projectNumber)')
  if ! gcloud billing budgets list --billing-account="$BILLING_ACCOUNT_ID" \
        --format='value(budgetFilter.projects)' 2>/dev/null | grep -q "projects/$pn"; then
    gcloud billing budgets create --billing-account="$BILLING_ACCOUNT_ID" \
      --display-name="$p (~\$5)" \
      --budget-amount="$BUDGET_AMOUNT" \
      --threshold-rule=percent=0.5 \
      --threshold-rule=percent=0.9 \
      --threshold-rule=percent=1.0 \
      --filter-projects="projects/$pn" >/dev/null
    echo "    budget created for $p"
  else
    echo "    budget already exists for $p — skipping"
  fi
}

# ── Phase 1: create the 4 projects + link billing ──────────────────────────
echo "==> [1/5] Creating projects + linking billing"
create_project "$INFRA_PROJECT" "crypto-pipeline-infra"
create_project "$DEV_PROJECT"   "crypto-pipeline-dev"
create_project "$STG_PROJECT"   "crypto-pipeline-stg"
create_project "$PROD_PROJECT"  "crypto-pipeline-prod"

# Make sure gcloud's active project + ADC quota project both point at a project
# that still exists (avoid stale references to a deleted project breaking API
# calls like `gcloud billing budgets`).
gcloud config set project "$INFRA_PROJECT" >/dev/null
gcloud auth application-default set-quota-project "$INFRA_PROJECT" >/dev/null 2>&1 || true

# ── Phase 2: enable APIs (per role) ────────────────────────────────────────
echo "==> [2/5] Enabling APIs (may take ~30s/project)"
COMMON_APIS="storage.googleapis.com bigquery.googleapis.com cloudresourcemanager.googleapis.com iam.googleapis.com"
FUNCTION_APIS="$COMMON_APIS cloudfunctions.googleapis.com run.googleapis.com cloudbuild.googleapis.com artifactregistry.googleapis.com eventarc.googleapis.com cloudscheduler.googleapis.com"
INFRA_APIS="$COMMON_APIS iamcredentials.googleapis.com sts.googleapis.com billingbudgets.googleapis.com"
gcloud services enable $INFRA_APIS     --project="$INFRA_PROJECT"  >/dev/null
gcloud services enable $COMMON_APIS    --project="$DEV_PROJECT"    >/dev/null
gcloud services enable $FUNCTION_APIS  --project="$STG_PROJECT"    >/dev/null
gcloud services enable $FUNCTION_APIS  --project="$PROD_PROJECT"   >/dev/null

# ── Phase 3: per-project budget alerts ─────────────────────────────────────
echo "==> [3/5] Per-project budget alerts"
ensure_budget "$INFRA_PROJECT"
ensure_budget "$DEV_PROJECT"
ensure_budget "$STG_PROJECT"
ensure_budget "$PROD_PROJECT"

# ── Phase 4: tfstate bucket + per-env tfvars + apply data projects ────────
echo "==> [4/5] Bootstrap tfstate bucket + apply Terraform per env"

if ! gcloud storage buckets describe "gs://$TFSTATE_BUCKET" --project="$INFRA_PROJECT" >/dev/null 2>&1; then
  gcloud storage buckets create "gs://$TFSTATE_BUCKET" \
    --project="$INFRA_PROJECT" \
    --location="$LOCATION" \
    --uniform-bucket-level-access >/dev/null
  gcloud storage buckets update "gs://$TFSTATE_BUCKET" --versioning >/dev/null
  echo "    created tfstate bucket"
else
  echo "    tfstate bucket already exists"
fi

# Note: backend.tf in each env points at this bucket name (hardcoded). If the
# user picked a different PROJECT_SUFFIX, the backend.tf would need updating.
# For learning, the default suffix matches the backend.tf default.

apply_env() {
  local env=$1 proj=$2
  echo "==> applying terraform/envs/$env  (project $proj)"
  cat > "terraform/envs/$env/terraform.tfvars" <<EOF
project_id = "$proj"
region     = "$REGION"
location   = "$LOCATION"
EOF
  ( cd "terraform/envs/$env"
    terraform init -input=false -reconfigure
    terraform apply -auto-approve -input=false )
}

apply_env dev     "$DEV_PROJECT"
apply_env staging "$STG_PROJECT"
apply_env prod    "$PROD_PROJECT"

# ── Phase 5: apply infra (WIF + cross-project IAM) ────────────────────────
echo "==> [5/5] Applying infra (WIF pool/provider + cross-project IAM)"

REPO_ID=$(gh api "repos/$GITHUB_REPO" --jq .id)
[ -n "$REPO_ID" ] || { echo "Could not get repo numeric id"; exit 1; }

cat > terraform/envs/infra/terraform.tfvars <<EOF
project_id           = "$INFRA_PROJECT"
region               = "$REGION"
location             = "$LOCATION"
dev_project_id       = "$DEV_PROJECT"
staging_project_id   = "$STG_PROJECT"
prod_project_id      = "$PROD_PROJECT"
github_repository    = "$GITHUB_REPO"
github_repository_id = "$REPO_ID"
EOF

( cd terraform/envs/infra
  terraform init -input=false -reconfigure
  # tfstate bucket already exists (we created it manually above) — import it
  # so Terraform manages it going forward. Safe to run repeatedly.
  if ! terraform state list 2>/dev/null | grep -q '^google_storage_bucket\.tfstate$'; then
    terraform import google_storage_bucket.tfstate "$TFSTATE_BUCKET" || true
  fi
  terraform apply -auto-approve -input=false )

echo
echo "##########  DONE  ##########"
echo "WIF provider name (use as workload_identity_provider in workflows):"
( cd terraform/envs/infra && terraform output -raw wif_provider_name )
echo
echo "Next: PR D wires the workflows to WIF + makes deploy.sh env-aware."
