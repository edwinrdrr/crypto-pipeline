# Setup — reproduce this project end-to-end

Follow these docs **in order** to reproduce the entire Level-3 architecture (4 GCP
projects + WIF + GitHub Environments + Cloud Function + dbt CI) from nothing.

Total time: **~30–45 min** of mostly waiting. Total cost: **~$0/year** (Always Free tier).

## Read order

| # | Doc | What it covers | Time |
|---|-----|----------------|------|
| 0 | [`environments.md`](environments.md) | concept overview — what gets created and why | 5 min |
| 1 | [`01-prerequisites.md`](01-prerequisites.md) | install tools, authenticate (gcloud / gh) | 5 min |
| 2 | [`02-gcp-projects.md`](02-gcp-projects.md) | provision the 4 GCP projects + tfstate bucket | ~5 min |
| 3 | [`03-terraform.md`](03-terraform.md) | apply per-env Terraform (buckets, datasets, SAs, WIF) | ~5 min |
| 4 | [`04-github-repo.md`](04-github-repo.md) | repo + branch protection + go public + secret-history sweep | 5 min |
| 5 | [`05-github-environments-wif.md`](05-github-environments-wif.md) | GitHub Environments + per-env secrets + WIF binding | 2 min |
| 6 | [`06-dbt-local.md`](06-dbt-local.md) | local dbt + `.env` + first build against dev | 5 min |
| 7 | [`07-deploy-ingestion.md`](07-deploy-ingestion.md) | seed raw tables + deploy function to staging + prod | ~5 min |
| 8 | [`08-verify.md`](08-verify.md) | end-to-end verification | 5 min |

## Prerequisites
- A Google account with a billing account (free trial is fine; **5-project quota** matters
  — see doc 02).
- A GitHub account.
- Linux/macOS (the install scripts assume this).

## The fast path (one-shot)

Once tools are installed and you're authenticated, **two scripts and a deploy** get you
all the way:

```bash
# 1. provision 4 projects + Terraform + WIF (idempotent; safe to re-run)
BILLING_ACCOUNT_ID=YOUR-BILLING-ACCOUNT-ID ./scripts/bootstrap.sh

# 2. configure GitHub Environments + per-env secrets + required-reviewer
./scripts/setup-github-environments.sh

# 3. seed raw tables + deploy the Cloud Function to staging (paused) + prod (live)
cp .env.example .env && set -a && source .env && set +a
.venv/bin/python ingestion/main.py
GCP_PROJECT=$GCP_PROJECT_STAGING RAW_BUCKET=$GCP_PROJECT_STAGING-crypto-raw \
   .venv/bin/python ingestion/main.py
GCP_PROJECT=$GCP_PROJECT_PROD    RAW_BUCKET=$GCP_PROJECT_PROD-crypto-raw \
   .venv/bin/python ingestion/main.py
ENV=staging PROJECT_ID=$GCP_PROJECT_STAGING ./ingestion/deploy.sh
ENV=prod    PROJECT_ID=$GCP_PROJECT_PROD    ./ingestion/deploy.sh
```

Each numbered doc explains the **manual path** for the same step so you can understand
what the scripts do.

## Teardown
```bash
PROJECT_ID=crypto-pipeline-prod-260528  ./scripts/teardown.sh    # repeat for each
```
Projects enter `DELETE_REQUESTED` and are recoverable for 30 days
(`gcloud projects undelete <id>`).

## When something breaks
- See the **Gotchas** sections in `LEARNING.md` and `CLAUDE.md` — all the real-world
  surprises we hit are documented (billing quota, ADC quota project, `gh repo view` vs
  `gh api`, terraform plan locking, bash apostrophe traps, paused scheduler force-run).
- The scripts are **idempotent** — safe to re-run from any failure point.
