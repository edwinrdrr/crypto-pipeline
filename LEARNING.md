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

- [x] **1. Git + PR flow** ← the universal foundation ✅ DONE
  - [x] init git repo, first commit, push to private GitHub repo (`edwinrdrr/crypto-pipeline`)
  - [x] create a feature branch (`feature/add-price-change-pct`)
  - [x] make a change to a dbt model (added `price_change_pct_since_prev`)
  - [x] open PR #1, watch CI run — CI caught a real bug (`dbt-utils` pip error), then failed on missing secrets
  - [x] provision GCP (project, budget, Terraform, CI service account + secrets)
  - [x] CI green → merge to main → CD built prod → verified new column live in `crypto_analytics`
- [x] **2. Environment isolation** — `staging` tier + per-PR/per-dev schemas ✅ DONE (PR #5)
  - [x] `generate_schema_name` macro (clean per-env names, no prefixing)
  - [x] dev dataset env-driven via `DBT_DATASET`; CI builds each PR into `dbt_ci_pr_<n>` and **drops it**
  - [x] `crypto_analytics_staging` dataset (Terraform) + CI hop **dev(ephemeral) → staging → prod**
        (prod job `needs: staging`); verified ephemeral build+drop and staging→prod promotion
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

## Live project facts

- **GCP project:** `crypto-pipeline-260527-18241` (billing-linked, IDR account)
- **GitHub repo:** `edwinrdrr/crypto-pipeline` (private)
- **Bucket:** `crypto-pipeline-260527-18241-crypto-raw`
- **Datasets:** `crypto_raw_dev`, `crypto_raw`, `crypto_analytics_dev`, `crypto_analytics_staging`, `crypto_analytics` (+ ephemeral `dbt_ci_pr_<n>` per PR, auto-dropped)
- **CI service account:** `dbt-ci@crypto-pipeline-260527-18241.iam.gserviceaccount.com`
- **Function runtime SA:** `crypto-ingest-fn@...` (BigQuery + bucket Storage roles)
- **Scheduler SA:** `crypto-scheduler@...` (run.invoker)
- **Cloud Function:** `crypto-ingest` (gen2, us-central1) · **Scheduler:** `crypto-ingest-5min` (`*/5 * * * *`, ENABLED)
- **Budget:** "crypto-pipeline-learn (~$5)" = 80,000 IDR, alerts 50/90/100%
- **Tooling:** gcloud at `~/google-cloud-sdk/bin`, terraform at `~/bin/terraform` (v1.9.8),
  dbt in `.venv` (v1.11.11). Note: stock `/usr/local/bin/terraform` v1.6.0 has a GPG bug — use `~/bin`.

## Log

- 2026-05-27: Built full pipeline scaffold.
- 2026-05-27: **Completed step 1 (git + PR flow) end-to-end.** Code change → PR #1 → CI
  (caught a real `dbt-utils` bug, then failed on missing secrets) → provisioned GCP
  (fresh project, $5 budget, Terraform infra, CI service account + GitHub secrets) →
  seeded raw tables → CI green → merged → CD built prod → verified `price_change_pct_since_prev`
  live in `crypto_analytics.fct_crypto_prices`.
- 2026-05-27: Documented the journey via **PR #2** (+ committed dbt/Terraform lockfiles).
- 2026-05-27: **Deployed the 5-min automation** (`deploy.sh`). Found the function wrote no rows
  because it ran as the default compute SA (no perms on a new project); fixed by giving it a
  dedicated **`crypto-ingest-fn`** runtime SA, then verified a new snapshot landed in `crypto_raw`.
  Updated `deploy.sh` to create/use the runtime SA automatically.
- 2026-05-28: Added cost projection to README (PR #4): ~$0–0.50/yr running 24/7, with caveats.
- 2026-05-28: **Completed step 2 (environment isolation)** via **PR #5**. Added `generate_schema_name`
  macro + env-driven `DBT_DATASET`; CI now builds each PR into an ephemeral `dbt_ci_pr_<n>` schema
  and drops it; added `crypto_analytics_staging` + a **dev→staging→prod** CI/CD promotion (prod
  `needs: staging`). Verified: PR #5 built+dropped `dbt_ci_pr_5`; merge built staging then prod.
- 2026-05-28: Added **reproducibility scripts** (`scripts/install-tools.sh`, `bootstrap.sh`,
  `teardown.sh`) — idempotent, all gotcha-fixes baked in, so a future rebuild is auth + one script.
  **Next: step 3 (Slim CI — `state:modified+`).**
