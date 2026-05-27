# CLAUDE.md — crypto-pipeline quickstart & cheat-sheet

A free-tier GCP data engineering project. ELT pipeline that ingests CoinGecko
prices every 5 minutes and transforms them with dbt across dev/prod environments.

## Architecture
```
CoinGecko API → Cloud Storage (raw) → BigQuery (raw) → dbt → BigQuery (analytics)
        \________ Cloud Scheduler every 5 min ________/
```

## Environments (the dev/test/prod concept)
Same code, different datasets — selected by env vars:

| Env  | Raw dataset      | Analytics dataset       | When used                 |
|------|------------------|-------------------------|---------------------------|
| dev  | `crypto_raw_dev` | `crypto_analytics_dev`  | local work, PRs in CI     |
| prod | `crypto_raw`     | `crypto_analytics`      | scheduled job, merge→main |

## Run order (first-time setup)
1. **Install tools:** `gcloud` CLI + `pip install dbt-bigquery dbt-utils` (see README step 0)
2. **Budget alert FIRST:** GCP Billing → Budgets → $5, alert at 50/90/100%
3. **Auth:** `gcloud auth login && gcloud auth application-default login`
4. **Provision infra:** `cd terraform && cp terraform.tfvars.example terraform.tfvars` (edit project_id) `&& terraform init && terraform apply`
5. **Test ingestion locally:** see env vars below, then `python ingestion/main.py`
6. **Transform:** `cd dbt && dbt deps && dbt build`
7. **Automate:** `cd ingestion && PROJECT_ID=... ./deploy.sh`
8. **CI/CD:** push to GitHub, add secrets `GCP_PROJECT` and `GCP_SA_KEY`

## Env vars — just load `.env` (one source of truth)
```bash
cp .env.example .env               # first time only (.env is gitignored)
set -a && source .env && set +a    # run from the repo root; sets ALL local vars
```
`.env` holds GCP_PROJECT, RAW_BUCKET, BQ_DATASET, DBT_METHOD=oauth, DBT_TARGET=dev,
RAW_DATASET, DBT_DATASET, DBT_PROFILES_DIR. No manual `export`s. To target a different
env for one command, override inline, e.g. `DBT_TARGET=prod dbt build`.
(CI/cloud don't use `.env` — they inject the same vars themselves. Secrets never go in `.env`.)

## Common commands
```bash
# Run ingestion once locally
python ingestion/main.py

# dbt: build everything against dev, then prod
dbt build                      # dev (default)
dbt build --target prod
dbt test                       # run tests only
dbt run --select fct_crypto_prices   # one model

# Inspect data
bq query --use_legacy_sql=false \
  'SELECT coin, price_usd, ingested_at FROM `'"$GCP_PROJECT"'.crypto_raw_dev.prices` ORDER BY ingested_at DESC LIMIT 10'

# Watch the deployed function
gcloud functions logs read crypto-ingest --gen2 --region=us-central1

# Pause / resume the 5-min schedule (stop ingestion without deleting it)
gcloud scheduler jobs pause  crypto-ingest-5min --location=us-central1
gcloud scheduler jobs resume crypto-ingest-5min --location=us-central1
```

## Service-account key for CI (the GCP_SA_KEY secret)
```bash
PROJECT_ID=your-project-id
gcloud iam service-accounts create dbt-ci --display-name="dbt CI" --project=$PROJECT_ID

SA=dbt-ci@$PROJECT_ID.iam.gserviceaccount.com
for role in roles/bigquery.dataEditor roles/bigquery.jobUser roles/storage.objectViewer; do
  gcloud projects add-iam-policy-binding $PROJECT_ID --member="serviceAccount:$SA" --role="$role"
done

gcloud iam service-accounts keys create sa-key.json --iam-account=$SA   # gitignored
# Paste the FULL contents of sa-key.json into the GitHub secret GCP_SA_KEY,
# then delete the local file:  rm sa-key.json
```

## Cost rules (keep it $0)
- ✅ Batch loads only (the code does this). ❌ Never streaming inserts.
- ✅ Incremental + partitioned dbt mart (only scans new rows).
- ❌ NEVER enable Cloud Composer / Dataflow / large clusters — that's the only real cost.
- GCS raw files auto-delete after 30 days; `crypto_raw_dev` tables expire after 14 days.

## Gotchas
- **dbt can't find profile** → set `DBT_PROFILES_DIR=$PWD/dbt` (or copy profiles.yml to `~/.dbt/`).
- **oauth fails in CI** → CI sets `DBT_METHOD=service-account`; locally it's `oauth` (needs `gcloud auth application-default login`).
- **Scheduler 403 calling function** → the SA needs `roles/run.invoker` (deploy.sh sets this).
- **CoinGecko 429 (rate limit)** → free tier ~30 calls/min; 5-min polling is fine. Add coins, not frequency.
