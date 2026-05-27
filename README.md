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

### 0. Install tools
```bash
# gcloud CLI — non-interactive install into your home dir (no sudo needed)
cd ~
curl -sSL -o gcloud-cli.tar.gz \
  https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-linux-x86_64.tar.gz
tar -xzf gcloud-cli.tar.gz && rm gcloud-cli.tar.gz
./google-cloud-sdk/install.sh --quiet --path-update=true
exec -l $SHELL          # reload shell so `gcloud`/`bq` are on PATH

# dbt — in a project-level virtualenv (dbt-bigquery pulls in dbt-core)
cd ~/Documents/learning/crypto-pipeline
python3 -m venv .venv && source .venv/bin/activate
pip install dbt-bigquery
```

### 1. GCP auth + a fresh dedicated project
```bash
gcloud auth login                              # user account (for gcloud/bq)
gcloud auth application-default login          # ADC (for Terraform + local dbt)

# Find your billing account id
gcloud billing accounts list

# Create a fresh project so this stays isolated + easy to delete later
PROJECT_ID="crypto-pipeline-$(date +%y%m%d)-$RANDOM"
gcloud projects create "$PROJECT_ID" --name="crypto-pipeline-learn"
gcloud billing projects link "$PROJECT_ID" --billing-account=YOUR_BILLING_ACCOUNT_ID
gcloud config set project "$PROJECT_ID"
gcloud auth application-default set-quota-project "$PROJECT_ID"   # avoids quota warnings

# Enable the APIs we need
gcloud services enable storage.googleapis.com bigquery.googleapis.com \
    cloudfunctions.googleapis.com cloudscheduler.googleapis.com run.googleapis.com
```
> **Note on cost / free trial:** this pipeline lives inside the **Always Free tier**
> (BigQuery 1 TB queries + 10 GB storage, GCS 5 GB, Cloud Functions, Scheduler), which
> never expires. So it costs ~$0/month even if your $300 trial credit is gone. The credit
> is just a buffer for anything beyond free — which we deliberately avoid.

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

## Git + CI/CD workflow (the real-world loop)

The day-to-day loop a data engineer runs. Never commit to `main` directly:

```bash
# 1. Branch off main (your sandbox)
git checkout main && git pull
git checkout -b feature/my-change

# 2. Edit a model, commit
git add -A && git commit -m "Add X metric to fct_crypto_prices"

# 3. Push + open a PR  → CI runs automatically against DEV
git push -u origin feature/my-change
gh pr create --fill

# 4. Watch CI; fix anything it catches, push again (CI re-runs on the same PR)
gh pr checks <PR#>
gh run view <RUN_ID> --log-failed     # read a failure

# 5. CI green + reviewed → merge → CD builds PROD
gh pr merge <PR#> --squash --delete-branch
```

Branch = sandbox · `main` = source of truth · merging = promotion to prod.

## Project status

Full pipeline scaffold + git/CI-CD loop:

- [x] **Ingestion** — CoinGecko → GCS → BigQuery (`ingestion/main.py`) — *run manually; works*
- [x] **dbt** — incremental + partitioned models, dev/prod targets (`dbt/`) — *builds + tests pass*
- [x] **GitHub Actions** — dbt CI/CD (`.github/workflows/dbt-ci.yml`) — *green; PR→dev, merge→prod*
- [x] **Terraform** — bucket + 4 datasets as IaC (`terraform/`) — *applied*
- [x] **Git repo + PR flow** — branch → PR → CI → merge (repo: `edwinrdrr/crypto-pipeline`)
- [x] **CI green + first prod merge** — PR #1 merged; new column verified live in `crypto_analytics` ✅
- [ ] **Cloud Function + Cloud Scheduler** — coded (`ingestion/deploy.sh`) but **not yet deployed**
      (data is seeded manually for now; deploy this to auto-ingest every 5 min)
- [ ] **Step 2: environment isolation** — `staging` tier + per-PR ephemeral schemas (next)

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

## Companion docs

- **`CLAUDE.md`** — quickstart cheat-sheet: env vars, common commands, the CI service-account
  recipe, cost rules, and gotchas. Read this when you sit back down to work.
- **`LEARNING.md`** — the learning tracker: concepts (stages/CI-CD/cloud), the staged learning
  path (git flow → isolation → Slim CI → orchestration), vocabulary, and a dated log.

## What we actually did, in order (the real journey log)

The true chronological sequence of this session — not an idealized order:

1. **Learned the concepts first (no code)** — what dev/test/staging/prod environments are,
   how CI/CD promotes code through them, how cloud + the GCP free tier make it ~$0, and the
   config-vs-secrets rule. (See `LEARNING.md` for the write-up.)
2. **Chose the design** — CoinGecko API, and the **ELT-via-Cloud-Storage** pattern
   (API → GCS raw → BigQuery → dbt) rather than loading the API straight into BigQuery.
3. **Built the ingestion first** — `ingestion/main.py` (+ `requirements.txt`, `.gitignore`,
   first `README`).
4. **Built the rest of the pipeline** — dbt project (`dbt/`), Cloud Function + Scheduler
   deploy (`ingestion/deploy.sh`), GitHub Actions CI/CD (`.github/workflows/`), Terraform (`terraform/`).
5. **Wrote `CLAUDE.md`** — the quickstart cheat-sheet.
6. **Detoured into theory** — secrets/`.env` vs secret managers, then how stages + CI/CD work
   in real-world DE. Created **`LEARNING.md`** as the tracker.
7. **Started the git + PR loop** — `git init -b main`, first commit, a feature branch
   (`feature/add-price-change-pct`), changed a model, committed.
8. **Cleaned history + published** — stripped the `Co-Authored-By` trailer from all commits,
   created a **private** GitHub repo, pushed `main`, then pushed the branch and opened **PR #1**.
9. **CI ran and caught a real bug** 💡 — first run failed because `dbt-utils` was wrongly in the
   `pip install` line, but it's a **dbt package** (from `packages.yml` via `dbt deps`), not PyPI.
   Fixed it on the branch, pushed → CI re-ran and got further, then failed at `dbt build`
   because **no GCP secrets existed yet**. 💡 Lesson: a red PR is a gate — you don't merge it.
10. **Decided to do GCP properly** → only *then* installed tooling: gcloud CLI (home-dir
    tarball) + `dbt-bigquery` in `.venv`.
11. **Authenticated** — `gcloud auth login` + `application-default login` (as `edwinrdrr@gmail.com`).
12. **Created a fresh dedicated project** — `crypto-pipeline-260527-18241`, linked billing,
    set it active + set the ADC quota project.
13. **Provisioned GCP** — created the **$5 budget** (project-scoped), enabled APIs,
    `terraform apply` → bucket + 4 datasets.
14. **Wired CI auth** — created the `dbt-ci` service account (BigQuery dataEditor + jobUser),
    generated a key, loaded `GCP_PROJECT` + `GCP_SA_KEY` as GitHub secrets, then **deleted the
    local key file** (it only lives in GitHub now).
15. **Seeded raw data** — ran ingestion once into `crypto_raw_dev` *and* `crypto_raw` (prod)
    so dbt's `source()` had a table to read.
16. **Closed the loop** 🎉 — re-ran CI on PR #1 → **GREEN** → merged (squash) → CD built prod →
    verified `price_change_pct_since_prev` is live in `crypto_analytics.fct_crypto_prices`.

### Gotchas we hit (so future-you doesn't lose time)

- **Budget currency must match the billing account.** The account is **IDR**, so `--budget-amount=5USD`
  failed with `INVALID_ARGUMENT`. Fix: omit the currency (`--budget-amount=80000`) so it uses the
  account's native currency (80,000 IDR ≈ $5).
- **Terraform v1.6.0 had a GPG "key expired" error** installing the google provider. Fix: use a
  newer Terraform — we put **v1.9.8 in `~/bin/terraform`** (the stock `/usr/local/bin/terraform` is old).
- **`bq` needs `gcloud` on PATH** — run `export PATH="$HOME/google-cloud-sdk/bin:$PATH"` first.
- **Seed the raw table before CI runs** — dbt fails if `source('crypto_raw','prices')` doesn't exist yet.

### Live project facts (this run)

| Thing | Value |
|-------|-------|
| GCP project | `crypto-pipeline-260527-18241` |
| GitHub repo | `edwinrdrr/crypto-pipeline` (private) |
| Bucket | `crypto-pipeline-260527-18241-crypto-raw` |
| Datasets | `crypto_raw_dev`, `crypto_raw`, `crypto_analytics_dev`, `crypto_analytics` |
| CI service account | `dbt-ci@crypto-pipeline-260527-18241.iam.gserviceaccount.com` |
| Budget | "crypto-pipeline-learn (~$5)" = 80,000 IDR, alerts 50/90/100% |

> **Key ordering insight:** we built *all the code and the entire git/CI loop before touching
> GCP at all.* That's deliberate — you can develop and let CI catch bugs long before any cloud
> resources (or costs) exist. Cloud provisioning is the *last* step, not the first.

> **To redo cleanly later:** delete the GCP project (`gcloud projects delete <id>`) and the
> GitHub repo, then start again from step 7 (the code already exists in this folder). If
> starting on a new machine, do setup §0 (install tooling) first.
