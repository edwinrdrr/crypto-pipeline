# Crypto Data Pipeline (Level-3 multi-project, learning project)

A free-tier data engineering pipeline on Google Cloud built to learn **real-world
environments, CI/CD, and cloud** end-to-end. **Architecturally complete** — uses the
real-world project-per-environment isolation pattern, Workload Identity Federation
(keyless auth), GitHub Environments with a required-reviewer gate on prod, multi-env
Terraform with remote state, and Slim CI.

```
CoinGecko API  →  Cloud Storage (raw)  →  BigQuery (raw)  →  dbt (transform)
   Extract            Land                  Load              Transform

per env: prod every 5 min · staging on-demand (paused scheduler) · dev local-only
```

## Live architecture

**4 GCP projects** (one per env + shared infra):

| Project | Holds |
|---------|-------|
| `crypto-pipeline-infra-260528` | **tfstate** bucket (versioned), **ci-state** bucket (Slim CI manifest), **WIF pool + provider**, **tf-runner** SA |
| `crypto-pipeline-dev-260528` | `crypto-raw` bucket, `crypto_raw` + `crypto_analytics` datasets, `dbt-ci@` SA — *no deployed function (local-only ingestion)* |
| `crypto-pipeline-stg-260528` | same + `crypto-ingest-fn` + `crypto-scheduler` SAs + Cloud Function + Scheduler (every 6h, **PAUSED**; operators trigger) |
| `crypto-pipeline-prod-260528` | same + Cloud Function + Scheduler (every 5 min, **ENABLED**) |

**WIF provider** (`workload_identity_provider` in workflows):  
`projects/101866768306/locations/global/workloadIdentityPools/github-actions/providers/github`

**GitHub Environments** (per-env-scoped secrets + protection):
- `dev` — used by `pr-ephemeral` (Slim CI builds into dev project)
- `staging` — used by the `staging` job on merge
- `production` — **required-reviewer rule** (manual approval before prod deploy)

## How config flows through the layers

```
Local (laptop) ────►  .env  ────►  dbt/ingestion target DEV project (DBT_TARGET=dev)
GitHub Actions ────► Environment env: + secrets ────► dbt-ci@<env-project> via WIF
Cloud Function ────► --set-env-vars baked at deploy ────► runs as crypto-ingest-fn@<env>
Terraform     ────► terraform.tfvars (per env folder)  ────► remote state in infra bucket
```

`.env` (laptop, gitignored) is the **only** place secrets-adjacent local config lives. CI and
the deployed function inject their config differently — see `docs/setup/environments.md`.

## Reproduce from scratch

**Every step is in [`docs/setup/`](docs/setup/README.md).** Read that folder's index for
the order; each numbered doc has a fast path (one script) AND a manual path (so you can
understand what the scripts do).

The fast path in one block:
```bash
./scripts/install-tools.sh
export PATH="$HOME/google-cloud-sdk/bin:$HOME/bin:$PATH"
gcloud auth login && gcloud auth application-default login && gh auth login

gh repo create crypto-pipeline --source=. --remote=origin --push # doc 02
gh repo edit --visibility public                                 # doc 02
BILLING_ACCOUNT_ID=YOUR-ID ./scripts/bootstrap.sh                # docs 03-04
./scripts/setup-github-environments.sh                           # doc 05
cp .env.example .env && set -a && source .env && set +a          # doc 06

# doc 07 (seed + deploy)
.venv/bin/python ingestion/main.py
GCP_PROJECT=$GCP_PROJECT_STAGING RAW_BUCKET=$GCP_PROJECT_STAGING-crypto-raw \
   .venv/bin/python ingestion/main.py
GCP_PROJECT=$GCP_PROJECT_PROD    RAW_BUCKET=$GCP_PROJECT_PROD-crypto-raw \
   .venv/bin/python ingestion/main.py
ENV=staging PROJECT_ID=$GCP_PROJECT_STAGING ./ingestion/deploy.sh
ENV=prod    PROJECT_ID=$GCP_PROJECT_PROD    ./ingestion/deploy.sh

# verify per doc 08
```

> **Cost guardrail**: every project has a budget alert at ~$5 in your account's native
> currency. Total realistic cost across all 4 projects: ~$0/year (within Always Free).
> Largest single risk: don't enable Cloud Composer.

## Local dev workflow (the loop)

```
git checkout main && git pull
git checkout -b feature/my-change                         # always branch
# edit dbt models, run locally against DEV
set -a && source .env && set +a
.venv/bin/python ingestion/main.py                        # if you need fresh dev raw
( cd dbt && dbt build --target dev )                      # writes crypto-pipeline-dev-260528.crypto_analytics
git push -u origin feature/my-change && gh pr create --fill
# CI runs: pr-ephemeral builds Slim CI into dbt_ci_pr_<n> in dev project, drops it after
# review + merge → staging job → prod job (paused for your approval) → manifest republished
```

## What's in the repo

```
crypto-pipeline/
├── terraform/
│   ├── modules/
│   │   ├── data-project/        # reusable: bucket + datasets + SAs + IAM + labels
│   │   └── wif/                 # WIF pool + OIDC provider + SA impersonation
│   └── envs/
│       ├── dev/                 # data-project (deploy_function=false)
│       ├── staging/             # data-project (deploy_function=true)
│       ├── prod/                # data-project (deploy_function=true)
│       └── infra/               # tfstate bucket + ci-state bucket + WIF + tf-runner SA
├── dbt/
│   ├── profiles.yml             # per-target `project: env_var('GCP_PROJECT_<ENV>')`
│   ├── macros/generate_schema_name.sql  # dbt-recommended pattern (target.name conditional)
│   └── models/                  # staging view + incremental mart + latest-prices view
├── ingestion/
│   ├── main.py                  # CoinGecko -> GCS -> BigQuery (env-driven)
│   └── deploy.sh                # ENV-aware: staging PAUSED, prod every 5 min
├── .github/workflows/
│   ├── dbt-ci.yml               # WIF + Environments: dev (Slim CI) → staging → prod
│   ├── scheduled-dbt.yml        # cron every 6h, prod refresh, required-reviewer
│   └── terraform-ci.yml         # plan-on-PR per env, posted as PR comment
├── scripts/
│   ├── install-tools.sh         # pinned versions
│   ├── bootstrap.sh             # multi-project orchestrator (idempotent)
│   └── teardown.sh              # delete projects (recoverable for 30 days)
├── airflow/                     # local Airflow (dev/learning only)
├── docs/                        # see the doc set below
├── .env.example                 # local config — copy to .env
├── README.md                    # this file
├── LEARNING.md                  # dated journey log
└── CLAUDE.md                    # quick command reference
```

## Companion docs

| Doc | Read when |
|-----|-----------|
| **`docs/start-here-mental-model.md`** | first read — what environments, push, CI/CD actually mean |
| **`docs/walkthrough-one-change.md`** | a real recorded trace of one change dev→staging→prod |
| **`docs/faq.md`** | the consolidated Q&A (every question we worked through) |
| **`docs/environments-and-cicd.md`** | the conceptual deep-dive |
| **`docs/howto-playbook.md`** | day-to-day task recipes |
| **`docs/setup/environments.md`** | how to set up and use environments — practical (Level 3) |
| **`docs/dashboard.md`** | put a free Looker Studio dashboard on top |
| **`docs/alerts.md`** | free monitoring + notifications when the pipeline breaks |
| **`docs/data-warehouse-setup.md`** | lead's phased new-project runbook |

All docs above are **synced to the Level-3 architecture** (4 GCP projects, WIF, GitHub
Environments). Conceptual patterns and concrete commands match what's currently live.

## What's running right now

- **Prod Cloud Function** ingests CoinGecko prices every 5 min into `crypto-pipeline-prod-260528.crypto_raw.prices`.
- **Scheduled dbt** workflow refreshes prod analytics every 6h (paused for required-reviewer approval).
- **No 5-min ingestion in dev or staging** by design.

## Status

| Layer | State |
|-------|-------|
| 4 GCP projects | provisioned ✅ |
| WIF (keyless GitHub Actions → GCP) | live ✅ |
| GitHub Environments (dev, staging, production) | configured, prod has required-reviewer ✅ |
| Per-env Terraform with remote state | applied ✅ |
| Cloud Function deployed to staging + prod | done ✅ |
| Slim CI working (Level-3) | verified by PR #28 merge run ✅ |
| Old project torn down | deleted (DELETE_REQUESTED, ~30-day recoverable) ✅ |
| Terraform CI (plan-on-PR) | wired in PR G ✅ |
| Docs fully synced to Level 3 | ✅ all docs (CLAUDE + 8 under docs/) rewritten for the current architecture |
