# How to use it — a data engineer's playbook (Level 3)

Task-oriented recipes for *operating* this pipeline day-to-day in the
**4-GCP-project Level-3** setup. The concept guide (`environments-and-cicd.md`) tells you
**why**; this tells you **what to type** for the things you actually do.

**Assumed setup once per shell** (so commands below "just work"):
```bash
export PATH="$HOME/google-cloud-sdk/bin:$HOME/bin:$PATH"
cd ~/Documents/learning/crypto-pipeline
source .venv/bin/activate
cp .env.example .env          # first time only (.env is gitignored)
set -a && source .env && set +a
```
`.env` sets `GCP_PROJECT_DEV/_STAGING/_PROD`, `DBT_TARGET=dev`, `DBT_METHOD=oauth`,
`DBT_PROFILES_DIR=$PWD/dbt`, and local ingestion vars pointing at dev.

---

## 0. The core loop (memorize this one)

Every change — a new column, a new model, a fix — follows the same path. This *is* the job.

```bash
# 1. branch off main
git checkout main && git pull
git checkout -b feature/short-description

# 2. edit dbt/ models. TEST LOCALLY first (recipe 2).

# 3. commit + push + open a PR
git add -A && git commit -m "Explain the change"
git push -u origin feature/short-description
gh pr create --fill

# 4. watch CI
#    pr-ephemeral runs Slim CI in the DEV project's dbt_ci_pr_<n> schema; drops after.
gh pr checks <PR#>

# 5. green + reviewed -> merge
gh pr merge <PR#> --squash --delete-branch

# 6. staging job runs (auto); prod job pauses for your approval
#    See the run in the Actions tab → Review deployments → Approve

# 7. verify the change reached PROD (recipe 7)
```
**Never edit `main` directly. Never merge a red PR. Don't approve prod blindly.**

---

## 1. Work in your own dev sandbox (without touching shared dev)

Each PR already gets its own ephemeral schema in the dev project (`dbt_ci_pr_<n>`). For
*local* work, point dbt at a personal schema so experiments don't collide:
```bash
cd dbt
DBT_TARGET=dev DBT_DATASET=dbt_$USER dbt build
# writes into crypto-pipeline-dev-260528.dbt_$USER instead of crypto_analytics
```

---

## 2. Run the whole pipeline locally before pushing

Catch errors on your machine instead of burning a CI round-trip.
```bash
# (a) ingest a fresh batch into the DEV project's crypto_raw
.venv/bin/python ingestion/main.py
# uses GCP_PROJECT, RAW_BUCKET, BQ_DATASET from .env (= dev)

# (b) build + test the models against dev
cd dbt
dbt deps
dbt build           # = run + test; against dev (DBT_TARGET from .env)
```

Fast inner-loop checks (no warehouse hit):
```bash
dbt parse                       # config/Jinja errors
dbt compile --select my_model   # render the SQL; inspect target/compiled/.../my_model.sql
```

---

## 3. Add a new dbt model

1. Choose `dbt/models/staging/` (cleans a source) or `dbt/models/marts/` (business logic).
2. Create `my_new_model.sql` using `{{ ref('other_model') }}` and
   `{{ source('crypto_raw', 'prices') }}` — never hard-code table names.
3. Document + test in a `_*.yml` (see recipe 4).
4. Build it: `dbt build --select my_new_model --target dev`.
5. Ship via the core loop (recipe 0). Slim CI will build *only* this model on the PR.

---

## 4. Add a data-quality test (the gate that protects prod)

Tests live next to models in YAML. Edit `dbt/models/marts/_marts.yml`:
```yaml
models:
  - name: fct_crypto_prices
    columns:
      - name: price_usd
        tests:
          - not_null
          - dbt_utils.accepted_range:
              min_value: 0
```
Run just the tests: `dbt test --select fct_crypto_prices --target dev`.
A failing test **fails CI** → the PR can't merge.

---

## 5. Change what gets ingested (e.g. add a coin)

The coin list is an env var (`COINS`) read by `ingestion/main.py`.

- **Local / one-off:** `COINS=bitcoin,ethereum,solana,cardano,dogecoin .venv/bin/python ingestion/main.py`
- **Permanently (the deployed function):** edit `--set-env-vars` in `ingestion/deploy.sh`,
  then re-run `ENV=prod PROJECT_ID=$GCP_PROJECT_PROD ./ingestion/deploy.sh`.

---

## 6. Debug a failed CI run

```bash
gh pr checks <PR#>                         # which job failed?
gh run view <RUN_ID> --log-failed          # the failing step's log
gh run view <RUN_ID> --log | grep -i error # hunt the message
```
Then **reproduce locally** (recipe 2) — almost every CI failure reproduces with `dbt build`
or `dbt parse` on your machine. Fix, push, CI re-runs on the same PR.

Common categories (more in `README.md` "Gotchas"):
- "Not found: Table" → source dataset/table doesn't exist in the env CI targeted (seed).
- WIF auth error → check the workflow's `service_account` matches an SA the WIF pool binds.
- "Error acquiring state lock" (terraform-ci) → `tf-runner` SA is read-only; pass `-lock=false`.

---

## 7. Verify a change reached prod

```bash
bq query --use_legacy_sql=false --project_id=$GCP_PROJECT_PROD \
  "SELECT * FROM \`$GCP_PROJECT_PROD.crypto_analytics.fct_crypto_prices\`
   ORDER BY ingested_at DESC LIMIT 10"
```
Or check the columns: `bq show $GCP_PROJECT_PROD:crypto_analytics.fct_crypto_prices`.

---

## 8. Backfill / full-refresh an incremental model

`fct_crypto_prices` is incremental — normal runs only process new rows. To rebuild it from
scratch (changing historical logic, adding columns to existing table):
```bash
dbt build --select fct_crypto_prices --full-refresh --target dev    # test in dev first!
```
Then ship through CI. The prod job will run `dbt build --target prod` (no `--full-refresh`),
which appends new columns thanks to `on_schema_change='append_new_columns'`. To do a true
prod full-refresh, you'd dispatch the workflow manually with that flag (not currently wired).

---

## 9. Roll back a bad change

Squash-merges produce single normal commits — revert them via the same PR flow:
```bash
git checkout main && git pull
git log --oneline -5                    # find the bad commit
git checkout -b revert/bad-change
git revert <commit_sha>
git push -u origin revert/bad-change
gh pr create --fill                     # let CI pass, merge, approve prod deploy
```
For data already written, `--full-refresh` (recipe 8) rebuilds the table from current logic.

---

## 10. Operate the scheduled jobs

```bash
# Prod (5-min ingestion) — usually just watch
gcloud functions logs read crypto-ingest --gen2 --region=us-central1 \
   --project=$GCP_PROJECT_PROD --limit=20
gcloud scheduler jobs pause  crypto-ingest-prod --location=us-central1 --project=$GCP_PROJECT_PROD
gcloud scheduler jobs resume crypto-ingest-prod --location=us-central1 --project=$GCP_PROJECT_PROD

# Staging — paused by default; resume → run → pause for one-off
gcloud scheduler jobs resume crypto-ingest-staging --location=us-central1 --project=$GCP_PROJECT_STAGING
gcloud scheduler jobs run    crypto-ingest-staging --location=us-central1 --project=$GCP_PROJECT_STAGING
gcloud scheduler jobs pause  crypto-ingest-staging --location=us-central1 --project=$GCP_PROJECT_STAGING

# Dev — no deployed function. Run locally:
.venv/bin/python ingestion/main.py

# Scheduled dbt cron (every 6h, prod refresh) — dispatch manually:
gh workflow run "scheduled dbt (prod refresh)"

# Local Airflow (learning the orchestrator)
cd airflow && docker compose up -d        # UI: localhost:8088, airflow/airflow
docker compose down                       # stop when done
```

---

## 11. Approve a prod deploy (required-reviewer gate)

The `prod` job in `dbt-ci.yml` and the `scheduled-dbt.yml` cron both use
`environment: production`, which requires my approval.

**Via UI**: Actions → run → **Review deployments** → approve.

**Via CLI:**
```bash
RUN=$(gh run list --branch main --limit 1 --json databaseId --jq '.[0].databaseId')
PROD_ENV_ID=$(gh api repos/edwinrdrr/crypto-pipeline/environments/production --jq .id)
gh api -X POST "repos/edwinrdrr/crypto-pipeline/actions/runs/$RUN/pending_deployments" \
  -F "environment_ids[]=$PROD_ENV_ID" -f state=approved -f comment="ship it"
```

---

## 12. Add a whole new environment (e.g. `qa`)

1. **Terraform**: add `terraform/envs/qa/` (copy from `dev/`); create
   `crypto-pipeline-qa-<suffix>` project; `terraform apply`.
2. **dbt**: add a `qa` target in `profiles.yml`.
3. **GitHub Environment**: `gh api -X PUT repos/.../environments/qa`; set
   `GCP_PROJECT_QA` secret on it.
4. **WIF**: add `qa` to `env_dbt_ci_sa_emails` in `envs/infra/main.tf`; `terraform apply`.
5. **Workflow**: add a `qa` job in `dbt-ci.yml` referencing the `qa` Environment.

That's "promotion via config, not code" — the pipeline code never changes, only the wiring.

---

### Where to look when stuck
- **Why does it work this way?** → `environments-and-cicd.md`
- **Exact current architecture** → `../README.md`
- **Quick commands / env vars** → `../CLAUDE.md`
- **What was done & when** → `../LEARNING.md`
- **A real recorded trace** → `walkthrough-one-change.md`
