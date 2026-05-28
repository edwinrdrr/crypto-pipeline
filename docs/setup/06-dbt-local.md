# 06 — dbt locally: `.env`, profiles, first build against DEV

Configure the laptop side so `dbt build` works against the dev project.

## What you'll have when done
- `.env` (gitignored) holding the 3 project ids + dbt config; targets DEV by default.
- `dbt deps` installed (dbt_utils).
- A first successful `dbt parse` / `dbt debug` against the dev project.

## Background — what's where
- `dbt/profiles.yml` (committed) — three targets `dev`/`staging`/`prod`. Each reads
  `project: env_var('GCP_PROJECT_<ENV>')`. **Same dataset name everywhere** (`crypto_analytics`)
  because the **project IS the env** (Level 3).
- `dbt/macros/generate_schema_name.sql` — dbt-recommended pattern using
  `target.name == 'prod'` (NOT the anti-pattern that uses `custom_schema_name` directly).
- `.env.example` (committed) — template for the gitignored `.env`.
- **`DBT_PROFILES_DIR`** tells dbt where to find `profiles.yml`. Our `.env` sets it to
  `$PWD/dbt` so it resolves to the repo's `dbt/` folder when sourced from repo root.
  (Default dbt behavior is `~/.dbt/profiles.yml`, which we don't want — profile lives in
  the repo.)

## Fast path
```bash
cp .env.example .env
# (edit .env if your project ids differ from the defaults)
set -a && source .env && set +a    # MUST run from the repo root (uses $PWD/dbt)
cd dbt && dbt deps && dbt debug
```
Expected `dbt debug` output:
```
profiles.yml file [OK found and valid]
dbt_project.yml file [OK found and valid]
Connection:
  method: oauth
  ...
Connection test: OK connection ok
```

## Manual path

### `.env` (what it contains)
```bash
GCP_PROJECT_DEV=crypto-pipeline-dev-260528
GCP_PROJECT_STAGING=crypto-pipeline-stg-260528
GCP_PROJECT_PROD=crypto-pipeline-prod-260528

DBT_TARGET=dev
DBT_METHOD=oauth                  # local auth via gcloud ADC; CI uses WIF (still oauth method)
DBT_PROFILES_DIR=$PWD/dbt          # resolves to <repo>/dbt when sourced from repo root

# Local ingestion defaults — point at dev's bucket/dataset.
GCP_PROJECT=$GCP_PROJECT_DEV
RAW_BUCKET=$GCP_PROJECT_DEV-crypto-raw
BQ_DATASET=crypto_raw
```

### Load it
```bash
cd ~/Documents/learning/crypto-pipeline
set -a && source .env && set +a    # set -a auto-exports each assignment; set +a turns it off
```
Re-load every new shell.

### Install dbt deps
```bash
cd dbt
.venv/bin/dbt deps                # installs dbt_utils per packages.yml
```

### First build against DEV — but first the source table must exist
The source `crypto_raw.prices` must exist in dev. **Doc 07 seeds it.** Once seeded:
```bash
.venv/bin/dbt build --target dev
# writes into <dev-project>.crypto_analytics.* + tests pass
```

## Check source freshness (is raw data flowing?)
The sources declare freshness; `dbt source freshness` will warn/error if `crypto_raw.prices`
hasn't been updated recently.
```bash
.venv/bin/dbt source freshness --target dev      # against your local dev project
.venv/bin/dbt source freshness --target prod     # against prod (read-only check)
```
A stale prod source = ingestion stopped. See `10-troubleshooting.md`.

## Switch target locally (rare)
```bash
DBT_TARGET=staging dbt build --target staging    # writes into <stg-project>
# Don't write to prod from local — let CI do it via the PR flow.
```

## Personal dev schema (recommended for multi-engineer teams)
```bash
DBT_TARGET=dev DBT_DATASET=dbt_$USER dbt build
# writes into <dev-project>.dbt_<your-username> instead of crypto_analytics
```

→ continue to [`07-deploy-ingestion.md`](07-deploy-ingestion.md).
