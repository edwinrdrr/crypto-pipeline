# 03 — GCP projects, billing, APIs, budgets, tfstate bucket

Create the 4 GCP projects and prep the cloud side.

## Why 4 projects (not 3)
- 3 env projects (`dev`, `staging`, `prod`) — one per environment, real-world Level-3
  isolation.
- 1 **shared infra project** for cross-cutting state:
  - **tfstate bucket** (single canonical home for all envs' Terraform state)
  - **ci-state bucket** (Slim CI manifest shared by all CI runs)
  - **WIF pool + provider** (Google best practice: single pool, not duplicated)
  - **`tf-runner` SA** (read-only across env projects, for `terraform plan` on PR)

Putting these in a fourth project keeps prod free of "infrastructure plumbing" and lets
you grant `tf-runner` `roles/viewer` per env project without polluting any env's IAM.

## What you'll have when done
- 4 GCP projects, all billing-linked:
  - `crypto-pipeline-infra-260528` — shared infra (tfstate, ci-state, WIF)
  - `crypto-pipeline-dev-260528`
  - `crypto-pipeline-stg-260528`
  - `crypto-pipeline-prod-260528`
- All necessary APIs enabled per project
- A **per-project budget alert** at ~$5 (in your billing account's native currency)
- A **versioned tfstate bucket** in the infra project
  (`gs://<infra>-tfstate`, object versioning ON, lifecycle to retain 30 versions)

## ⚠️ Billing-account quota — read this first
**GCP billing accounts cap the number of linked projects** (default 5 for newer/free-trial
accounts). Adding 4 new projects will overflow if you already have ≥2 linked. Solutions:
- **Delete unused linked projects** (`gcloud billing projects list --billing-account=…`).
- Request quota increase via Cloud Console → Billing → Quotas (takes hours/days).
- Use a different/secondary billing account.

`bootstrap.sh` will fail loudly with `FAILED_PRECONDITION: Cloud billing quota exceeded` if
you hit this. Resolve and re-run — it's idempotent.

## Fast path
```bash
BILLING_ACCOUNT_ID=YOUR-BILLING-ACCOUNT-ID ./scripts/bootstrap.sh
```
That runs Phases 1–5 in `scripts/bootstrap.sh`:
1. Create projects + link billing.
2. Reset gcloud active project + ADC quota project to the infra project.
3. Enable APIs per project.
4. Per-project budgets.
5. Create the tfstate bucket (versioning + lifecycle).

(Phases 6–8 run Terraform — that's doc 04. Phase 8 reads `repos/<you>/<repo>` via
`gh api`, which is why doc 02 — creating the repo — comes before this.)

Find your `BILLING_ACCOUNT_ID` via:
```bash
gcloud billing accounts list   # ACCOUNT_ID column
```

## Manual path

### Create projects (the names matter — backend.tf hardcodes `…-infra-260528`)
```bash
SUFFIX=260528    # if you change this, update terraform/envs/*/backend.tf
for env in infra dev stg prod; do
  PROJECT="crypto-pipeline-${env}-${SUFFIX}"
  gcloud projects create "$PROJECT" --name="crypto-pipeline-${env}"
  gcloud billing projects link "$PROJECT" --billing-account=YOUR-BILLING-ID
done
```

### Reset gcloud + ADC to a *live* project
After project creation/deletion gcloud may still reference a stale project as quota target:
```bash
gcloud config set project crypto-pipeline-infra-260528
gcloud auth application-default set-quota-project crypto-pipeline-infra-260528
```

### Enable APIs (different per project role)
```bash
COMMON="storage.googleapis.com bigquery.googleapis.com cloudresourcemanager.googleapis.com iam.googleapis.com"
FUNCTION="cloudfunctions.googleapis.com run.googleapis.com cloudbuild.googleapis.com artifactregistry.googleapis.com eventarc.googleapis.com cloudscheduler.googleapis.com"
INFRA="iamcredentials.googleapis.com sts.googleapis.com billingbudgets.googleapis.com"

gcloud services enable $COMMON $INFRA   --project=crypto-pipeline-infra-260528
gcloud services enable $COMMON          --project=crypto-pipeline-dev-260528
gcloud services enable $COMMON $FUNCTION --project=crypto-pipeline-stg-260528
gcloud services enable $COMMON $FUNCTION --project=crypto-pipeline-prod-260528
```

### Per-project budget alerts (~$5)
```bash
# The amount currency MUST match your billing account's currency.
# If your account is USD use --budget-amount=5USD.
# If it's another currency (e.g. IDR), OMIT the currency and pass the native amount
# (80000 IDR ≈ $5). Otherwise you get INVALID_ARGUMENT.
for env in infra dev stg prod; do
  PROJECT="crypto-pipeline-${env}-260528"
  PN=$(gcloud projects describe "$PROJECT" --format='value(projectNumber)')
  gcloud billing budgets create \
    --billing-account=YOUR-BILLING-ID \
    --display-name="$PROJECT (~\$5)" \
    --budget-amount=80000 \
    --threshold-rule=percent=0.5 \
    --threshold-rule=percent=0.9 \
    --threshold-rule=percent=1.0 \
    --filter-projects="projects/$PN"
done
```

### tfstate bucket (versioned)
```bash
gcloud storage buckets create gs://crypto-pipeline-infra-260528-tfstate \
  --project=crypto-pipeline-infra-260528 \
  --location=US \
  --uniform-bucket-level-access
gcloud storage buckets update gs://crypto-pipeline-infra-260528-tfstate --versioning
```

## Verify
```bash
gcloud billing projects list --billing-account=YOUR-BILLING-ID \
  | grep -E "crypto-pipeline-(infra|dev|stg|prod)-260528"
# 4 lines, all BILLING_ENABLED=True

gcloud storage buckets describe gs://crypto-pipeline-infra-260528-tfstate \
  --format='value(versioning.enabled)'   # → True
```

→ continue to [`04-terraform.md`](04-terraform.md).
