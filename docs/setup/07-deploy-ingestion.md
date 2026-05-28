# 07 — Seed raw tables + deploy the Cloud Function

Each env's `crypto_raw.prices` table must exist before dbt sources resolve. Then deploy
the gen2 Cloud Function + Cloud Scheduler to **staging (paused)** and **prod (every 5 min)**.

## What you'll have when done
- `crypto_raw.prices` table populated in **all three** env projects (~4 rows each)
- `crypto-ingest` Cloud Function deployed in staging + prod (running as
  `crypto-ingest-fn@<env-project>`)
- Cloud Scheduler `crypto-ingest-staging` exists, scheduled `0 */6 * * *`, **PAUSED**
- Cloud Scheduler `crypto-ingest-prod` exists, scheduled `*/5 * * * *`, **ENABLED**
- Dev intentionally has no deployed function — developers run `python ingestion/main.py`
  locally

## Fast path

### Seed all three env raws (one-time, ~10 seconds each)
```bash
set -a && source .env && set +a

# dev — uses .env defaults
.venv/bin/python ingestion/main.py

# staging
GCP_PROJECT=$GCP_PROJECT_STAGING RAW_BUCKET=$GCP_PROJECT_STAGING-crypto-raw \
   .venv/bin/python ingestion/main.py

# prod
GCP_PROJECT=$GCP_PROJECT_PROD    RAW_BUCKET=$GCP_PROJECT_PROD-crypto-raw \
   .venv/bin/python ingestion/main.py
```

### Deploy the function (env-aware)
Each deploy takes 2–3 min for the gen2 container build.
```bash
ENV=staging PROJECT_ID=$GCP_PROJECT_STAGING ./ingestion/deploy.sh
# Creates function, scheduler '0 */6 * * *', then PAUSES the scheduler.

ENV=prod    PROJECT_ID=$GCP_PROJECT_PROD    ./ingestion/deploy.sh
# Creates function, scheduler '*/5 * * * *' running.
```

## Manual operate

### staging — operator workflow (resume → run → pause)
The scheduler is paused; force-running a paused scheduler errors. To trigger:
```bash
gcloud scheduler jobs resume crypto-ingest-staging --location=us-central1 --project=$GCP_PROJECT_STAGING
gcloud scheduler jobs run    crypto-ingest-staging --location=us-central1 --project=$GCP_PROJECT_STAGING
gcloud scheduler jobs pause  crypto-ingest-staging --location=us-central1 --project=$GCP_PROJECT_STAGING
```

### prod — usually just watch
```bash
gcloud functions logs read crypto-ingest --gen2 --region=us-central1 \
  --project=$GCP_PROJECT_PROD --limit=20
```

### Pause prod (planned outage / quota check)
```bash
gcloud scheduler jobs pause crypto-ingest-prod --location=us-central1 --project=$GCP_PROJECT_PROD
# resume when ready:
gcloud scheduler jobs resume crypto-ingest-prod --location=us-central1 --project=$GCP_PROJECT_PROD
```

## What deploy.sh actually creates
- gen2 Cloud Function `crypto-ingest`:
  - source = `ingestion/`, entry point = `ingest`, runtime = `python311`
  - runs as `crypto-ingest-fn@<env-project>` SA
  - env vars: `GCP_PROJECT`, `RAW_BUCKET`, `BQ_DATASET=crypto_raw`
- Cloud Scheduler job `crypto-ingest-<env>`:
  - cron: `*/5 * * * *` (prod) or `0 */6 * * *` (staging, paused)
  - HTTP POST → function URI, signed with OIDC token by `crypto-scheduler@<env-project>`

## Verify
```bash
# raw populated in all three
for env in dev stg prod; do
  PROJECT=crypto-pipeline-${env}-260528
  echo -n "$PROJECT.crypto_raw.prices rows: "
  bq query --use_legacy_sql=false --project_id=$PROJECT --format=csv --quiet \
    "SELECT COUNT(*) FROM \`$PROJECT.crypto_raw.prices\`" | tail -1
done

# function state
for proj in $GCP_PROJECT_STAGING $GCP_PROJECT_PROD; do
  gcloud functions describe crypto-ingest --gen2 --region=us-central1 \
    --project=$proj --format='value(state)'
done
# → ACTIVE, ACTIVE

# scheduler states
gcloud scheduler jobs describe crypto-ingest-staging --location=us-central1 \
  --project=$GCP_PROJECT_STAGING --format='value(state,schedule)'
# → PAUSED 0 */6 * * *

gcloud scheduler jobs describe crypto-ingest-prod    --location=us-central1 \
  --project=$GCP_PROJECT_PROD    --format='value(state,schedule)'
# → ENABLED */5 * * * *
```

→ continue to [`08-verify.md`](08-verify.md).
