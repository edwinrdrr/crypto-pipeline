# How to use it — a data engineer's playbook

Task-oriented recipes for *operating* this pipeline day-to-day. The concept guide
(`environments-and-cicd.md`) tells you **why**; this tells you **what to type** for the
things you actually do. Each recipe is end-to-end and grounded in this project.

**Assumed setup once per shell** (so commands below "just work"):
```bash
export PATH="$HOME/google-cloud-sdk/bin:$HOME/bin:$PATH"
export GCP_PROJECT=crypto-pipeline-260527-18241        # your project id
cd ~/Documents/learning/crypto-pipeline
source .venv/bin/activate                              # dbt + python deps
```

---

## 0. The core loop (memorize this one)

Every change — a new column, a new model, a fix — follows the same path. This *is* the job.

```bash
# 1. branch off main
git checkout main && git pull
git checkout -b feature/short-description

# 2. make the change (edit dbt/ models), then TEST LOCALLY before pushing (recipe 2)

# 3. commit + push + open a PR
git add -A && git commit -m "Explain the change"
git push -u origin feature/short-description
gh pr create --fill

# 4. watch CI (Slim CI builds only what you changed, in a throwaway schema)
gh pr checks <PR#>
gh run view <RUN_ID> --log-failed     # if red — read it, fix, push again (recipe 6)

# 5. green + reviewed -> merge -> CD builds staging then prod
gh pr merge <PR#> --squash --delete-branch

# 6. verify it reached prod (recipe 7)
```
**Never edit `main` directly. Never merge a red PR.** Those two rules are the whole discipline.

---

## 1. Work in your own dev sandbox (without touching shared dev)

Point dbt at a personal schema so your experiments are isolated:
```bash
cd dbt
export DBT_PROFILES_DIR=$PWD DBT_METHOD=oauth RAW_DATASET=crypto_raw_dev
export DBT_DATASET=dbt_$USER          # your own dataset, e.g. dbt_edwin
dbt build --target dev                # builds into dbt_edwin.*
```
This is the same mechanism CI uses for per-PR schemas (`DBT_DATASET=dbt_ci_pr_<n>`).

---

## 2. Run the whole pipeline locally before pushing

Catch errors on your machine instead of burning a CI round-trip.
```bash
# (a) ingest once into dev raw
GCP_PROJECT=$GCP_PROJECT RAW_BUCKET=$GCP_PROJECT-crypto-raw BQ_DATASET=crypto_raw_dev \
  python ingestion/main.py

# (b) build + test the models against dev
cd dbt
export DBT_PROFILES_DIR=$PWD DBT_METHOD=oauth RAW_DATASET=crypto_raw_dev DBT_DATASET=crypto_analytics_dev
dbt deps
dbt build --target dev          # = run + test; fails loudly if anything's wrong
```
Fast inner-loop checks without hitting the warehouse hard:
```bash
dbt parse                       # config/Jinja errors (catches the {{ config() }} comment traps)
dbt compile --select my_model   # render the SQL; inspect target/compiled/.../my_model.sql
```

---

## 3. Add a new dbt model

```bash
# stage view (cleans a source) or mart (business logic)?  Put it in the right folder:
#   dbt/models/staging/   or   dbt/models/marts/
```
1. Create `dbt/models/marts/my_new_model.sql` — e.g. `select coin, avg(price_usd) ... from {{ ref('fct_crypto_prices') }} group by 1`.
2. Document + test it in a `_*.yml` (see recipe 4).
3. Run it: `dbt build --select my_new_model --target dev`.
4. Ship via the core loop (recipe 0). Slim CI will build *only* this model on the PR.

> Use `{{ ref('other_model') }}` and `{{ source('crypto_raw','prices') }}` — never hard-code
> table names. That's how dbt knows the dependency graph (and how deferral/Slim CI work).

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
          - dbt_utils.accepted_range:     # e.g. price can't be negative
              min_value: 0
```
Run just the tests: `dbt test --select fct_crypto_prices --target dev`.
A failing test **fails CI** → the PR can't merge. That's the point — bad data is a build break.

---

## 5. Change what gets ingested (e.g. add a coin)

The coin list is an env var (`COINS`) read by `ingestion/main.py`.
- **Local / one-off:** `COINS=bitcoin,ethereum,solana,cardano,dogecoin python ingestion/main.py`
- **Permanently (the deployed function):** add `COINS` to the `--set-env-vars` in
  `ingestion/deploy.sh`, then re-run `PROJECT_ID=$GCP_PROJECT ./ingestion/deploy.sh`.

---

## 6. Debug a failed CI run

```bash
gh pr checks <PR#>                         # which job failed?
gh run view <RUN_ID> --log-failed          # the failing step's log
gh run view <RUN_ID> --log | grep -i error # hunt the message
```
Then **reproduce locally** (recipe 2) — almost every CI failure reproduces with `dbt build`
or `dbt parse` on your machine. Fix on the branch, `git push` → CI re-runs on the same PR.
We hit (all in the README "Gotchas"): `dbt-utils` in pip, missing secrets, the
`state:modified.body` selector, `on_schema_change`, and Jinja-vs-SQL comments.

---

## 7. Verify a change reached prod

```bash
bq query --use_legacy_sql=false \
  "SELECT * FROM \`$GCP_PROJECT.crypto_analytics.fct_crypto_prices\`
   ORDER BY ingested_at DESC LIMIT 10"
```
Or check the columns: `bq show $GCP_PROJECT:crypto_analytics.fct_crypto_prices`.

---

## 8. Backfill / full-refresh an incremental model

`fct_crypto_prices` is incremental — normal runs only process new rows. To rebuild it from
scratch (e.g. after changing historical logic, or to add a column to an existing table):
```bash
dbt build --select fct_crypto_prices --full-refresh --target dev    # test in dev first!
```
> Remember: incremental models use `on_schema_change='append_new_columns'` here, so *new*
> columns get added automatically on the next run — but *changing* existing logic for past
> rows needs `--full-refresh`.

---

## 9. Roll back a bad change

The clean way — revert through the same PR flow (don't force-push `main`). Our merges are
**squash** commits, so each PR is one normal commit you can revert directly:
```bash
git checkout main && git pull
git log --oneline -5                    # find the squash commit to undo
git checkout -b revert/bad-change
git revert <commit_sha>                 # squash commit = single parent, no -m needed
git push -u origin revert/bad-change
gh pr create --fill                     # open it as a PR, let CI pass, then merge
```
(Or use the **"Revert" button** on the merged PR in the GitHub UI — it opens this revert PR
for you.) On merge, CD rebuilds staging→prod from the reverted state. For data already
written, `--full-refresh` (recipe 8) rebuilds the table from current logic.

---

## 10. Operate the scheduled jobs

```bash
# the every-5-min ingestion (Cloud Scheduler)
gcloud scheduler jobs pause  crypto-ingest-5min --location=us-central1
gcloud scheduler jobs resume crypto-ingest-5min --location=us-central1
gcloud scheduler jobs run    crypto-ingest-5min --location=us-central1   # run now
gcloud functions logs read crypto-ingest --gen2 --region=us-central1     # watch logs

# the scheduled dbt transform (GitHub Actions cron) — run on demand:
gh workflow run "scheduled dbt (prod refresh)"

# local Airflow (learning the orchestrator)
cd airflow && docker compose up -d        # start (UI: localhost:8088, airflow/airflow)
docker compose down                       # stop when done
```

---

## 11. Add a whole new environment (e.g. `qa`)

1. **Terraform**: add `crypto_analytics_qa` to the `datasets` map in `terraform/main.tf`, `terraform apply`.
2. **dbt**: add a `qa` target in `dbt/profiles.yml` (copy `staging`, change `dataset`).
3. **CI**: add a job/step that builds `--target qa` where you want it in the promotion chain.

That's "promotion via config, not code" — the pipeline code never changes, only the wiring.

---

### Where to look when stuck
- **Why does it work this way?** → `docs/environments-and-cicd.md`
- **Exact setup / reproduce / gotchas** → `README.md`
- **Quick commands / env vars** → `CLAUDE.md`
- **What was done & when** → `LEARNING.md`
