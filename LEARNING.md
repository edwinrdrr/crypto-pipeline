# Data Engineering Learning Tracker

Tracking my journey learning **environments (stages) + CI/CD + cloud** for data
engineering, using the `crypto-pipeline` project (CoinGecko → GCS → BigQuery → dbt on GCP).

## Core concepts (the "why")

- **Stages/environments** = isolated code + isolated data per tier (dev / staging / prod).
  In DE you promote the *transformation logic*, not the data. Selected by config/env vars.
- **CI/CD** = git PR flow is the engine. Branch → PR → CI (tests) → merge → deploy.
  CI = run tests on every PR. CD = promote to staging/prod on merge.
- **Cloud** = makes cheap, disposable, reproducible environments possible (BigQuery, GCS, etc).
- **Config vs secrets**: config from env (`.env` local only); secrets from a secret manager.
- Three CI/CD flows in real DE: transform code (dbt), orchestration (Airflow DAGs), infra (Terraform).

## Project pieces built ✅

- [x] Ingestion: CoinGecko → GCS → BigQuery (`ingestion/main.py`)
- [x] Automation: Cloud Function + Cloud Scheduler every 5 min (`ingestion/deploy.sh`)
- [x] Transform: dbt staging + incremental partitioned mart, dev/prod targets (`dbt/`)
- [x] CI/CD: GitHub Actions, PR→dev / merge→prod (`.github/workflows/dbt-ci.yml`)
- [x] IaC: Terraform bucket + 4 datasets (`terraform/`)

## Stages + CI/CD learning path

> All four are real-world — they're layers used *together*, learned in this order.

- [ ] **1. Git + PR flow** ← the universal foundation (IN PROGRESS)
  - [ ] init git repo, first commit
  - [ ] create a feature branch
  - [ ] make a change to a dbt model
  - [ ] open a PR, watch CI run
  - [ ] merge to main → prod deploy
- [ ] **2. Environment isolation** — add a `staging` tier + per-PR/per-dev schemas
  - [ ] `generate_schema_name` macro for per-PR dev schemas
  - [ ] add `analytics_staging` dataset + CI hop dev→staging→prod
- [ ] **3. Slim CI** — `state:modified+` so CI only rebuilds changed models (cheap/fast)
  - [ ] store prod manifest as CI artifact for `--defer` / `state:` comparison
- [ ] **4. Orchestration** — local Airflow DAG (free) running ingestion + dbt
  - [ ] docker-compose Airflow
  - [ ] DAG: ingest → dbt build → dbt test

## Real-world patterns / vocabulary to know

- **Slim CI** — only rebuild changed models + downstream (`state:modified+`).
- **Write-Audit-Publish (WAP) / blue-green** — build into a clone, test, then swap into prod.
- **Per-PR ephemeral schemas** — each PR builds into a throwaway schema, dropped on merge.
- **Promotion via config, not code** — same code, different target/env var.
- **Tests as the gate** — `dbt test`, freshness, row-count anomalies fail the pipeline.
- **12-Factor config** — config in the environment; secrets in a secret manager (not `.env` in prod).

## Cost rules (stay $0)

- Batch loads only (free); never streaming inserts.
- Incremental + partitioned dbt mart (scans only new rows).
- NEVER enable Cloud Composer / Dataflow / large clusters.
- $5 budget alert set in GCP Billing.

## Log

- 2026-05-27: Built full pipeline scaffold. Started step 1 (git + PR flow).
