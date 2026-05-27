# Crypto Data Pipeline (learning project)

A free-tier data engineering pipeline on Google Cloud:

```
CoinGecko API  →  Cloud Storage (raw)  →  BigQuery (raw)  →  dbt (transform)
   Extract            Land                  Load              Transform
            \____________ every 5 min via Cloud Scheduler ____________/
```

Goal: learn **environments (dev/prod), CI/CD, and cloud** end-to-end at **~$0/month**.

## Cost guardrails (do these FIRST)

1. **Set a budget alert** — `$5`, alert at 50% / 90% / 100% (emails you before any surprise).
   See setup **§1b** for the exact CLI command (or do it in Console → Billing → Budgets & alerts).
2. **Never enable Cloud Composer / Dataflow / large clusters** — those are the only
   things that cost real money. We run Airflow locally instead (later step).
3. Use **batch loads** (this code does) — they're free. Avoid streaming inserts.

Expected cost for this project: **$0** (well within Always Free + the $300 credit).

### Cost projection — running the 5-min pipeline 24/7 for a full year

**Bottom line: ~$0–$0.50/year.** At 105,120 runs/year, everything stays inside the
Always Free tier; the only thing that can register at all is GCS write operations.

| Component | Yearly usage | Free tier | Cost |
|-----------|--------------|-----------|------|
| Cloud Scheduler | 1 job | 3 jobs free, forever | $0 |
| Cloud Function (invocations) | 105,120/yr | 2M/month free | $0 |
| Cloud Function (compute) | ~4k vCPU-sec + 6k GiB-sec/mo | 180k vCPU-sec + 360k GiB-sec/mo | $0 |
| BigQuery load jobs | 105,120 loads/yr | batch loads always free | $0 |
| BigQuery storage | ~24 MB/yr (measured: 57 B/row) | 10 GB free | $0 |
| BigQuery queries | none recurring (dbt runs only in CI) | 1 TB/mo free | $0 |
| Cloud Storage (storage) | ~9 MB (30-day auto-delete) | tiny | ~$0 |
| Cloud Storage (write ops) | ~8,640 Class-A/mo | 5,000/mo free* | ~$0–0.04/mo |

Two things keep it this cheap (both already built in): **batch loads** (free regardless of
frequency) and the **30-day GCS lifecycle rule** (Terraform) so raw files never accumulate.

> **Accuracy / caveats (be honest with future-you):**
> - Based on GCP pricing knowledge (≈Jan 2026), **not** verified against live pricing pages or
>   the actual billing console. The BigQuery storage input *was* measured against the real table.
> - \* The always-free GCS operations allowance (5,000 Class-A/mo) is **region-specific**
>   (us-east1/west1/central1). Our bucket is **multi-region `US`**, which may not qualify — in
>   that case all ~8,640 writes/mo are billable → **~$0.50/year** (the realistic ceiling).
> - Want literal $0? Batch several coins into fewer files, or drop to every 15 min. Not worth it
>   for ~$0.30/yr. The $5 budget alert (§1b) will catch anything unexpected regardless.

## Reproduce from scratch (the fast path)

Three scripts in `scripts/` make a full rebuild near-one-command. The detailed manual
steps below (§0–§2) are what these scripts automate — read them to understand, run the
scripts to go fast.

```bash
# 1. Install pinned tools (gcloud, terraform 1.9.8, dbt venv, gh check) — once per machine
./scripts/install-tools.sh
export PATH="$HOME/google-cloud-sdk/bin:$HOME/bin:$PATH"

# 2. Authenticate (interactive — only you can do these)
gcloud auth login && gcloud auth application-default login
gh auth login

# 3. Build EVERYTHING on a fresh project (idempotent; safe to re-run)
PROJECT_ID="crypto-pipeline-$(date +%y%m%d)-$RANDOM" \
BILLING_ACCOUNT_ID=XXXXXX-XXXXXX-XXXXXX \
./scripts/bootstrap.sh
```
`bootstrap.sh` runs all 8 phases in order: project + billing + APIs → budget → Terraform
(bucket + 5 datasets) → seed raw tables → GitHub repo → CI service account + secrets →
deploy Cloud Function + Scheduler → verify rows landed. Every gotcha-fix is baked in.

Tear down to rebuild clean: `PROJECT_ID=... ./scripts/teardown.sh`.

> **What "reproducible" means here (honest scope):**
> - ✅ **Identical** infrastructure, datasets, pipeline logic, CI/CD, and final wiring.
> - 🔁 The **project id** differs each run (must be globally unique — it's parameterized).
> - 📈 The **data values** differ — it's the live CoinGecko market, so prices/timestamps won't
>   match a previous run. The schema and behaviour are identical; the numbers are fresh.
> - ⚠️ Tool versions are pinned, but **GCP pricing / free-tier terms can change** over time.
> - The scripts are syntax- and idempotency-validated; a full end-to-end run needs a fresh project.

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

# Terraform — install a recent version into ~/bin
# (older builds like v1.6.0 fail with an "openpgp: key expired" GPG error)
mkdir -p ~/bin && cd ~
curl -sSL -o tf.zip https://releases.hashicorp.com/terraform/1.9.8/terraform_1.9.8_linux_amd64.zip
unzip -oq tf.zip terraform -d ~/bin && rm tf.zip
export PATH="$HOME/bin:$PATH"   # add to ~/.bashrc to make permanent
terraform version
```
> `gh` (GitHub CLI) is also required for the CI/CD steps — install from https://cli.github.com
> and run `gh auth login` once.

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

# Enable ALL the APIs this project uses (the gen2 function needs cloudbuild,
# artifactregistry and eventarc too — easy to miss and the deploy fails without them)
gcloud services enable \
    storage.googleapis.com bigquery.googleapis.com \
    cloudfunctions.googleapis.com cloudscheduler.googleapis.com run.googleapis.com \
    cloudbuild.googleapis.com artifactregistry.googleapis.com eventarc.googleapis.com \
    billingbudgets.googleapis.com
```

### 1b. Set a $5 budget alert (do this before provisioning)
```bash
BILLING_ACCOUNT_ID=YOUR_BILLING_ACCOUNT_ID    # from `gcloud billing accounts list`
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')

# NOTE: the amount currency MUST match your billing account's currency.
# If your account is USD use `--budget-amount=5USD`. If it's another currency
# (e.g. IDR), OMIT the currency and pass the native amount (80000 IDR ≈ $5),
# otherwise you get `INVALID_ARGUMENT`.
gcloud billing budgets create \
  --billing-account="$BILLING_ACCOUNT_ID" \
  --display-name="crypto-pipeline-learn (~\$5)" \
  --budget-amount=80000 \
  --threshold-rule=percent=0.5 \
  --threshold-rule=percent=0.9 \
  --threshold-rule=percent=1.0 \
  --filter-projects="projects/$PROJECT_NUMBER"
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
terraform apply        # creates the bucket + 5 datasets
```
This provisions all your **environments** reproducibly:
`crypto_raw_dev`, `crypto_raw`, `crypto_analytics_dev`, `crypto_analytics_staging`, `crypto_analytics`.
(Per-PR `dbt_ci_pr_<n>` schemas are created/dropped by CI on the fly — not managed here.)

> Prefer manual setup to learn the primitives first? The equivalent commands are:
> ```bash
> gcloud storage buckets create gs://$PROJECT_ID-crypto-raw --location=US
> bq --location=US mk --dataset $PROJECT_ID:crypto_raw_dev
> bq --location=US mk --dataset $PROJECT_ID:crypto_raw
> bq --location=US mk --dataset $PROJECT_ID:crypto_analytics_dev
> bq --location=US mk --dataset $PROJECT_ID:crypto_analytics_staging
> bq --location=US mk --dataset $PROJECT_ID:crypto_analytics
> ```

## Local config: one `.env` (do this once)

All local commands read their env vars from a single gitignored `.env`. Set it up once,
load it each shell — **no manual `export`s anywhere**:
```bash
cd ~/Documents/learning/crypto-pipeline
source .venv/bin/activate
cp .env.example .env               # first time; edit GCP_PROJECT if yours differs
set -a && source .env && set +a    # load it (run from the repo root)
```
> `.env` only sets vars on your laptop and points local runs at **dev**. CI/cloud inject the
> same vars themselves. Config only — secrets go in GitHub Secrets / a secret manager.

## Run the ingestion locally

```bash
python ingestion/main.py           # uses GCP_PROJECT / RAW_BUCKET / BQ_DATASET from .env (dev)
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
cd dbt
dbt deps                    # install dbt_utils
dbt build                   # runs models + tests against DEV (target/datasets from .env)
dbt build --target prod     # build the PROD analytics dataset
```
(All the `DBT_*` / `RAW_DATASET` vars come from `.env` — nothing to export by hand.)
What the models do:
- `stg_crypto__prices` — cleans/types the raw snapshots (a **view**, free to maintain)
- `fct_crypto_prices` — **incremental + partitioned** time-series fact; each run only
  processes new rows, adds price-change-since-previous-poll. Stays in the free 1 TB.

## Deploy the every-5-min automation

```bash
cd ../ingestion
PROJECT_ID=$PROJECT_ID ./deploy.sh
```
`deploy.sh` sets up **two** service accounts (this is the part that's easy to get wrong):

1. **`crypto-ingest-fn`** — the function's *runtime* identity, with `bigquery.dataEditor`,
   `bigquery.jobUser`, and `storage.objectAdmin` on the bucket. ⚠️ **Do not** rely on the
   default compute SA — on new projects it has no permissions, so the function deploys
   fine but **fails silently at runtime** (no rows land, often no error in logs).
2. **`crypto-scheduler`** — the identity Cloud Scheduler uses to invoke the private
   function (granted `run.invoker`), via an OIDC token.

It deploys the gen2 **Cloud Function** (`ingest`) and a **Cloud Scheduler** job (`*/5 * * * *`).

**Verify it actually works** (don't trust "deployed" — trust rows landing):
```bash
gcloud scheduler jobs run crypto-ingest-5min --location=us-central1   # force a run now
# then confirm a NEW snapshot appears (count should grow each run):
bq query --use_legacy_sql=false \
  'SELECT COUNT(DISTINCT ingested_at) FROM `'"$PROJECT_ID"'.crypto_raw.prices`'
# pause / resume the schedule any time:
gcloud scheduler jobs pause  crypto-ingest-5min --location=us-central1
gcloud scheduler jobs resume crypto-ingest-5min --location=us-central1
```

## CI/CD (GitHub Actions) — environment-isolated

`.github/workflows/dbt-ci.yml` runs automatically with **per-PR isolation + staged promotion**:

```
Pull request ─► pr-ephemeral : SLIM build (only changed models) into dbt_ci_pr_<PR#>,
                               run tests, then DROP it (if: always)
Merge to main ─► staging : build + test crypto_analytics_staging
                  │
                  └─► prod : (needs: staging) promote → crypto_analytics
                             then PUBLISH manifest.json to GCS (next PR's baseline)
```

- **Per-PR ephemeral schema** — each PR builds into its own `dbt_ci_pr_<n>` dataset (set via
  `DBT_DATASET`), so two open PRs never overwrite each other, and shared dev stays clean. The
  schema is dropped at the end (even on failure).
- **Slim CI** — the PR job runs `dbt build --select state:modified.body+ --defer --state <prod>`,
  so it builds **only the models whose SQL changed** (plus downstream) and **defers** unchanged
  models to the prod tables instead of rebuilding them. The baseline is the prod `manifest.json`,
  which the `prod` job uploads to `gs://<bucket>/dbt-state/manifest.json` after each deploy.
  On a project with hundreds of models this turns a full rebuild into seconds.
- **Staged promotion** — merging deploys to **staging** first; **prod** only runs if staging is
  green (`needs: staging`). That's the dev → staging → prod gate.
- The `generate_schema_name` macro (`dbt/macros/`) makes dbt use each env's dataset name as-is.

> **Why `.body` and not plain `state:modified`?** Plain `modified` also compares each model's
> *target relation* (schema). Our prod manifest uses `crypto_analytics` but PRs build into
> `dbt_ci_pr_<n>` — so every model would look "modified" and Slim CI would rebuild everything.
> `state:modified.body` compares only the compiled SQL, which is what we actually care about.

> **Want a manual approval before prod?** Add a GitHub **Environment** (`environment: production`)
> with required reviewers on the `prod` job. Note: environment protection rules need a public repo
> or a paid plan for private repos — otherwise the `needs: staging` gate is your automated stand-in.

Create a CI service account, generate a key, and load the two repo secrets (via the
`gh` CLI — no clicking needed):
```bash
# 1. CI service account with the roles CI needs:
#    dataEditor (build) + jobUser (run jobs) + dataOwner (drop ephemeral PR datasets)
gcloud iam service-accounts create dbt-ci --display-name="dbt CI" --project=$PROJECT_ID
SA="dbt-ci@$PROJECT_ID.iam.gserviceaccount.com"
for role in roles/bigquery.dataEditor roles/bigquery.jobUser roles/bigquery.dataOwner; do
  gcloud projects add-iam-policy-binding $PROJECT_ID --member="serviceAccount:$SA" \
    --role="$role" --condition=None
done
# Storage on the bucket so CI can read/write the Slim-CI manifest state
gcloud storage buckets add-iam-policy-binding gs://$PROJECT_ID-crypto-raw \
  --member="serviceAccount:$SA" --role=roles/storage.objectAdmin

# 2. Key file (temporary — gitignored)
gcloud iam service-accounts keys create sa-key.json --iam-account=$SA

# 3. Load secrets into GitHub, then DELETE the local key
gh secret set GCP_PROJECT --body "$PROJECT_ID"
gh secret set GCP_SA_KEY < sa-key.json
rm sa-key.json
```
> ⚠️ **Seed the raw tables before CI runs.** dbt's `source('crypto_raw','prices')` fails if
> the table doesn't exist. Run the ingestion once into **both** `crypto_raw_dev` (for PR/dev
> CI) and `crypto_raw` (for the merge/prod build) — see "Run the ingestion locally" above,
> changing `BQ_DATASET` each time.

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

## Orchestration (Step 4)

Three layers, by what actually runs them:

| What | Tool | Runs where | Cost |
|------|------|-----------|------|
| **Ingestion** every 5 min | **Cloud Scheduler** → Cloud Function | GCP, 24/7 | free |
| **Transform** on a schedule | **GitHub Actions cron** (`.github/workflows/scheduled-dbt.yml`) | GitHub, 24/7 | free* |
| **Learning the orchestrator** | **local Airflow** (`airflow/`) | your machine (dev only) | free |

- **Cloud Scheduler** is a *timer* — fires one trigger, no pipeline logic. Already deployed.
- **GitHub Actions cron** runs `dbt build --target prod` every 6h — the free, 24/7 way to keep
  `crypto_analytics` fresh (the gap, since dbt otherwise only runs on merge). *\*Private repos get
  2,000 free Action-min/mo; every-6h ≈ 240 min/mo. Don't make it hourly (~1,800 min/mo).*
- **Local Airflow** (`airflow/`) is the real *orchestrator* — a DAG `extract_load → dbt_run →
  dbt_test` with dependencies, retries, and a UI. It's **dev/learning only** (runs only while your
  machine + Docker are up); production Airflow means Cloud Composer (~$300+/mo), which we avoid.
  See `airflow/README.md` to run it locally.

> Why three? A **timer** triggers one thing; a **CI runner** runs a script of steps on a cron; an
> **orchestrator** runs a *graph* with retries/backfills/observability. You learn the orchestrator
> locally, but use the free timer + runner for actual 24/7 work at this scale.

Branch = sandbox · `main` = source of truth · merging = promotion to prod.

## Project status

Full pipeline scaffold + git/CI-CD loop:

- [x] **Ingestion** — CoinGecko → GCS → BigQuery (`ingestion/main.py`) — *run manually; works*
- [x] **dbt** — incremental + partitioned models; dev/staging/prod targets (`dbt/`) — *builds + tests pass*
- [x] **GitHub Actions** — dbt CI/CD (`.github/workflows/dbt-ci.yml`) — *PR→ephemeral, merge→staging→prod*
- [x] **Terraform** — bucket + 5 datasets as IaC (`terraform/`) — *applied*
- [x] **Git repo + PR flow** — branch → PR → CI → merge (repo: `edwinrdrr/crypto-pipeline`)
- [x] **CI green + first prod merge** — PR #1 merged; new column verified live in `crypto_analytics` ✅
- [x] **Docs PR** — PR #2 merged (journey log + committed lockfiles)
- [x] **Cloud Function + Cloud Scheduler** — deployed & verified; runs every 5 min as a
      dedicated runtime SA, writing to `crypto_raw`. ✅
- [x] **Step 2: environment isolation** — per-PR ephemeral `dbt_ci_pr_<n>` schemas + `staging` tier;
      dev→staging→prod promotion (PR #5). ✅
- [x] **Step 3: Slim CI** — PRs build only changed models (`state:modified.body+ --defer`) against the
      prod manifest in GCS (PR #8). ✅
- [x] **Step 4: orchestration** — local Airflow DAG (`extract_load→dbt_run→dbt_test`, verified) for
      learning the tool + a free GitHub Actions cron (`scheduled-dbt.yml`) for real 24/7 transforms. ✅

## Project layout
```
crypto-pipeline/
  ingestion/             # Extract + Load: API → GCS → BigQuery
    main.py              #   the function (runs locally or as Cloud Function)
    requirements.txt
    deploy.sh            #   deploy Cloud Function + 5-min Scheduler
  dbt/                   # Transform: staging views + incremental marts
    dbt_project.yml
    profiles.yml         #   dev/staging/prod targets, env-driven auth + dataset
    packages.yml
    macros/              #   generate_schema_name.sql (clean per-env / per-PR schemas)
    models/
      staging/           #   _crypto__sources.yml, stg_crypto__prices.sql
      marts/             #   fct_crypto_prices.sql (incremental), _marts.yml
  terraform/             # Infrastructure as Code: bucket + 5 datasets
    main.tf  variables.tf  outputs.tf  terraform.tfvars.example
  .github/workflows/
    dbt-ci.yml           # CI/CD: PR→ephemeral schema, merge→staging→prod
    scheduled-dbt.yml    # cron: dbt build --target prod every 6h (free 24/7 transform)
  airflow/               # Local Airflow (learning the orchestrator; dev only)
    docker-compose.yaml  #   LocalExecutor + Postgres
    dags/crypto_pipeline_dag.py   # extract_load → dbt_run → dbt_test
  scripts/               # Reproducibility
    install-tools.sh     #   gcloud + terraform + dbt venv + gh (pinned versions)
    bootstrap.sh         #   one command: provision + deploy + verify (idempotent)
    teardown.sh          #   delete the project to rebuild clean
  docs/
    start-here-mental-model.md # read first: environments=cloud DBs, what push/CI-CD really do
    walkthrough-one-change.md  # real recorded run: one change traced dev→staging→prod
    environments-and-cicd.md   # concept guide: why environments/CI-CD/cloud work this way
    howto-playbook.md          # operator's playbook: how to use it day-to-day (recipes)
```

## Companion docs

- **`docs/start-here-mental-model.md`** — read this FIRST. Untangles the core confusion from
  zero: environments are *cloud databases*, "local" is just your laptop, and what `git push` /
  CI/CD actually do (branch→dev, merge→staging→prod). Grounded in a real trace from this repo.
- **`docs/environments-and-cicd.md`** — the concept guide: *why* environments, CI/CD, cloud,
  and orchestration work the way they do, grounded in this project.
- **`docs/walkthrough-one-change.md`** — a *real recorded run* (PR #16) tracing one tiny change
  through dev → staging → prod, annotating at each step where it ran vs which database it touched.
- **`docs/howto-playbook.md`** — the operator's playbook: *how to actually use it* day-to-day
  (ship a change, add a model/test, debug a red CI, backfill, roll back). Copy-paste recipes.
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
17. **Documented it all via PR #2** — wrote this journey log + committed the dbt and Terraform
    **lockfiles** (gitignored the machine-specific `dbt/.user.yml`). CI ran again (because the PR
    touched `dbt/**`) → green → merged.
18. **Deployed the 5-min automation** — ran `deploy.sh`: gen2 Cloud Function `crypto-ingest`
    + Cloud Scheduler `crypto-ingest-5min` (`*/5 * * * *`).
19. **Hit + fixed the runtime-SA gap** 💡 — the function deployed but wrote **no rows**: it ran as
    the **default compute SA**, which on a new project has **no permissions** (and failed silently).
    Fix: created a dedicated **`crypto-ingest-fn`** runtime SA (BigQuery + bucket Storage roles),
    pointed the function at it, force-ran the scheduler, and **verified a new snapshot landed**.
    Updated `deploy.sh` so this is automatic next time. (Steps 18–19 shipped as **PR #3**, which
    also completed the "document every setup step" gap-fill across the README.)
20. **Added a cost projection** (PR #4) — ~$0–0.50/yr running 24/7; measured row size against the
    real table; documented the multi-region GCS free-ops caveat.
21. **Step 2: environment isolation** (PR #5) — added the `generate_schema_name` macro + env-driven
    `DBT_DATASET`, a `crypto_analytics_staging` dataset, and a **dev(ephemeral)→staging→prod** CI/CD.
    Verified: PR #5 built into `dbt_ci_pr_5` then **dropped** it; the merge built **staging** then
    promoted to **prod** (the `prod` job `needs: staging`). 💡 Lesson: per-PR schemas isolate
    concurrent work; a staging gate catches bad data before prod.
22. **Reproducibility scripts** (PR #7) — added `scripts/install-tools.sh`, `bootstrap.sh`
    (idempotent, all 8 phases with the gotcha-fixes baked in), and `teardown.sh`, so a future
    rebuild is auth + one command. Validated idempotency-detection against the live project.
23. **Step 3: Slim CI** (PR #8) — prod publishes its `manifest.json` to GCS; PRs build
    `state:modified.body+ --defer`. Demonstrated: changing only the mart built **just
    `fct_crypto_prices`** (1 model, 5 tasks) and deferred the unchanged staging view —
    vs. a full build (2 models, 8 tasks). 💡 First tried plain `state:modified+` and it
    rebuilt everything (the cross-env relation false-positive — see gotchas).
24. **Fixed incremental schema evolution** (PR #9) — `price_direction` didn't reach prod
    because the incremental mart defaulted to `on_schema_change='ignore'`. Set it to
    `append_new_columns`; hit two more parse bugs along the way (SQL `--` and a stray `#}`
    inside the config-block comment — both caught by CI/local compile), then verified the
    column landed in prod.
25. **Step 4: orchestration** — stood up **local Airflow** (docker-compose, LocalExecutor) and a
    DAG `extract_load → dbt_run → dbt_test`. Verified: the `@hourly` run succeeded on its own, and a
    manual run's `dbt_run` hit a BigQuery concurrency conflict (two runs, same dev table) and
    **auto-retried to success** — orchestration earning its keep. Added a free **GitHub Actions cron**
    (`scheduled-dbt.yml`, every 6h) for the real 24/7 transform. 💡 Lesson: local Airflow is for
    *learning/dev*; for $0 always-on scheduling use Cloud Scheduler (ingest) + Actions cron (transform).

### Gotchas we hit (so future-you doesn't lose time)

- **Budget currency must match the billing account.** The account is **IDR**, so `--budget-amount=5USD`
  failed with `INVALID_ARGUMENT`. Fix: omit the currency (`--budget-amount=80000`) so it uses the
  account's native currency (80,000 IDR ≈ $5).
- **Terraform v1.6.0 had a GPG "key expired" error** installing the google provider. Fix: use a
  newer Terraform — we put **v1.9.8 in `~/bin/terraform`** (the stock `/usr/local/bin/terraform` is old).
- **`bq` needs `gcloud` on PATH** — run `export PATH="$HOME/google-cloud-sdk/bin:$PATH"` first.
- **Seed the raw table before CI runs** — dbt fails if `source('crypto_raw','prices')` doesn't exist yet.
- **gen2 Cloud Functions need extra APIs** — `cloudbuild`, `artifactregistry`, `eventarc` (beyond
  the obvious `cloudfunctions`/`run`); the deploy fails without them.
- **Don't trust "deployed" — trust rows landing.** The default compute SA made the function deploy
  successfully but fail at runtime with no error. Always verify with a forced run + row count.
- **Slim CI: use `state:modified.body+`, not plain `state:modified+`.** Plain `modified` compares the
  target relation (schema) too; with ephemeral PR schemas vs prod, *every* model looks modified and
  Slim CI rebuilds everything. `.body` compares the compiled SQL only.
- **Incremental models default to `on_schema_change='ignore'`** — new columns silently never reach an
  already-built table. Set `on_schema_change='append_new_columns'` (or `--full-refresh`).
- **Inside/around a `{{ config() }}` block, comments must be Jinja `{# ... #}`, not SQL `--`** — and
  don't put the characters that close a Jinja comment *inside* one, or it ends early and leaks SQL.
- **Local Airflow with a custom UID**: (1) Docker creates `./logs` as root → "Unable to configure
  handler 'processor'"; pre-create `logs/` owned by your uid. (2) Don't override the image
  `entrypoint` — it sets up a valid user for arbitrary UIDs (else `getuser()` fails); use the
  `_AIRFLOW_DB_MIGRATE`/`_AIRFLOW_WWW_USER_*` env vars instead. (3) Port 8080 is often taken — we use 8088.
- **GitHub Actions cron on a private repo isn't unlimited** — 2,000 free min/mo; keep the schedule
  modest (we use every 6h, not hourly). Scheduled runs also need the workflow on the default branch.

### Live project facts (this run)

| Thing | Value |
|-------|-------|
| GCP project | `crypto-pipeline-260527-18241` |
| GitHub repo | `edwinrdrr/crypto-pipeline` (private) |
| Bucket | `crypto-pipeline-260527-18241-crypto-raw` |
| Datasets | `crypto_raw_dev`, `crypto_raw`, `crypto_analytics_dev`, `crypto_analytics_staging`, `crypto_analytics` (+ ephemeral `dbt_ci_pr_<n>`) |
| Slim CI state | `gs://crypto-pipeline-260527-18241-crypto-raw/dbt-state/manifest.json` |
| CI service account | `dbt-ci@crypto-pipeline-260527-18241.iam.gserviceaccount.com` |
| Function runtime SA | `crypto-ingest-fn@crypto-pipeline-260527-18241.iam.gserviceaccount.com` |
| Scheduler SA | `crypto-scheduler@crypto-pipeline-260527-18241.iam.gserviceaccount.com` |
| Cloud Function | `crypto-ingest` (gen2, us-central1) |
| Scheduler job | `crypto-ingest-5min` (`*/5 * * * *`, ENABLED) |
| Budget | "crypto-pipeline-learn (~$5)" = 80,000 IDR, alerts 50/90/100% |

> **Key ordering insight:** we built *all the code and the entire git/CI loop before touching
> GCP at all.* That's deliberate — you can develop and let CI catch bugs long before any cloud
> resources (or costs) exist. Cloud provisioning is the *last* step, not the first.

> **To redo cleanly later:** delete the GCP project (`gcloud projects delete <id>`) and the
> GitHub repo, then start again from step 7 (the code already exists in this folder). If
> starting on a new machine, do setup §0 (install tooling) first.
