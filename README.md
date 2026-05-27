# Crypto Data Pipeline (learning project)

A free-tier data engineering pipeline on Google Cloud:

```
CoinGecko API  →  Cloud Storage (raw)  →  BigQuery (raw)  →  dbt (transform)
   Extract            Land                  Load              Transform
            \____________ every 5 min via Cloud Scheduler ____________/
```

Goal: learn **environments (dev/prod), CI/CD, and cloud** end-to-end at **~$0/month**.

## Cost guardrails (do these FIRST)

1. **Set a budget alert** — GCP Console → Billing → Budgets & alerts → create budget
   `$5`, alert at 50% / 90% / 100%. This emails you before any surprise.
2. **Never enable Cloud Composer / Dataflow / large clusters** — those are the only
   things that cost real money. We run Airflow locally instead (later step).
3. Use **batch loads** (this code does) — they're free. Avoid streaming inserts.

Expected cost for this project: **$0** (well within Always Free + the $300 credit).

## One-time setup

### 0. Install tools (not yet on this machine)
```bash
# gcloud CLI
curl https://sdk.cloud.google.com | bash && exec -l $SHELL

# Python deps for local runs (in a virtualenv)
cd crypto-pipeline/ingestion
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
```

### 1. GCP project + auth
```bash
gcloud auth login
gcloud config set project YOUR_PROJECT_ID
gcloud auth application-default login          # lets local code use your creds

# Enable the APIs we need
gcloud services enable storage.googleapis.com bigquery.googleapis.com \
    cloudfunctions.googleapis.com cloudscheduler.googleapis.com run.googleapis.com
```

### 2. Create the bucket + datasets with Terraform (Infrastructure as Code)
```bash
cd ../terraform
cp terraform.tfvars.example terraform.tfvars   # edit: set your project_id
terraform init
terraform apply        # creates the bucket + 4 datasets (raw/analytics × dev/prod)
```
This provisions all your **environments** reproducibly:
`crypto_raw_dev`, `crypto_raw`, `crypto_analytics_dev`, `crypto_analytics`.

> Prefer manual setup to learn the primitives first? The equivalent commands are:
> ```bash
> gcloud storage buckets create gs://$PROJECT_ID-crypto-raw --location=US
> bq --location=US mk --dataset $PROJECT_ID:crypto_raw_dev
> bq --location=US mk --dataset $PROJECT_ID:crypto_raw
> bq --location=US mk --dataset $PROJECT_ID:crypto_analytics_dev
> bq --location=US mk --dataset $PROJECT_ID:crypto_analytics
> ```

## Run the ingestion locally

```bash
cd crypto-pipeline/ingestion
source .venv/bin/activate
export GCP_PROJECT=$PROJECT_ID
export RAW_BUCKET=$PROJECT_ID-crypto-raw
export BQ_DATASET=crypto_raw_dev        # write to DEV while testing
python main.py
```
You should see a raw `.jsonl` file appear in the bucket and rows land in
`crypto_raw_dev.prices`. Run it a few times — each run appends a new time-series snapshot.

Inspect in BigQuery:
```sql
SELECT coin, price_usd, ingested_at
FROM `YOUR_PROJECT_ID.crypto_raw_dev.prices`
ORDER BY ingested_at DESC
LIMIT 20;
```

## Transform with dbt

```bash
cd ../dbt
export GCP_PROJECT=$PROJECT_ID
export DBT_PROFILES_DIR=$PWD        # use the profiles.yml in this folder
export RAW_DATASET=crypto_raw_dev   # read raw from the dev dataset

dbt deps                    # install dbt_utils
dbt build                   # runs models + tests against DEV (default target)
dbt build --target prod     # build the PROD analytics dataset
```
What the models do:
- `stg_crypto__prices` — cleans/types the raw snapshots (a **view**, free to maintain)
- `fct_crypto_prices` — **incremental + partitioned** time-series fact; each run only
  processes new rows, adds price-change-since-previous-poll. Stays in the free 1 TB.

## Deploy the every-5-min automation

```bash
cd ../ingestion
PROJECT_ID=$PROJECT_ID ./deploy.sh
```
Deploys the gen2 **Cloud Function** (`ingest`) and a **Cloud Scheduler** job
(`*/5 * * * *`) that invokes it securely via a dedicated service account.

## CI/CD (GitHub Actions)

`.github/workflows/dbt-ci.yml` runs automatically:
- **Pull request** → `dbt build` + tests against **dev**
- **Merge to main** → `dbt build` + tests against **prod**

Add two repo secrets (Settings → Secrets → Actions):
- `GCP_PROJECT` — your project id
- `GCP_SA_KEY` — JSON key of a service account with BigQuery + Storage access

## Done — full pipeline

- [x] **Ingestion** — CoinGecko → GCS → BigQuery (`ingestion/main.py`)
- [x] **Cloud Function + Cloud Scheduler** — every 5 min (`ingestion/deploy.sh`)
- [x] **dbt** — incremental + partitioned models, dev/prod targets (`dbt/`)
- [x] **GitHub Actions** — dbt CI/CD (`.github/workflows/dbt-ci.yml`)
- [x] **Terraform** — bucket + datasets as IaC (`terraform/`)

## Project layout
```
crypto-pipeline/
  ingestion/             # Extract + Load: API → GCS → BigQuery
    main.py              #   the function (runs locally or as Cloud Function)
    requirements.txt
    deploy.sh            #   deploy Cloud Function + 5-min Scheduler
  dbt/                   # Transform: staging views + incremental marts
    dbt_project.yml
    profiles.yml         #   dev/prod targets, env-driven auth
    packages.yml
    models/
      staging/           #   _crypto__sources.yml, stg_crypto__prices.sql
      marts/             #   fct_crypto_prices.sql (incremental), _marts.yml
  terraform/             # Infrastructure as Code: bucket + 4 datasets
    main.tf  variables.tf  outputs.tf  terraform.tfvars.example
  .github/workflows/
    dbt-ci.yml           # CI/CD: dbt on PR (dev) and merge (prod)
```
