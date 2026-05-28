# CLAUDE.md — quickstart cheat-sheet (Level 3)

Project at `~/Documents/learning/crypto-pipeline`. Architecture: 4 GCP projects
(infra / dev / staging / prod), Workload Identity Federation, GitHub Environments.

## Architecture in one breath
- **Project = environment.** Inside each env project: `crypto_raw` + `crypto_analytics`
  datasets, `<project>-crypto-raw` bucket. Same names everywhere; project tells you which env.
- **infra** project holds: `tfstate` bucket, `ci-state` bucket (Slim CI manifest), WIF pool/provider, `tf-runner` SA.
- **prod** runs the every-5-min Cloud Function. **staging** has the function deployed but scheduler **paused**. **dev** has no function — local-only ingestion.
- **CI** uses WIF (no SA keys). **GitHub Environments** scope secrets per env; `production` has required-reviewer.

## Live facts
```
GCP projects:
  crypto-pipeline-infra-260528         shared infra
  crypto-pipeline-dev-260528           dev
  crypto-pipeline-stg-260528           staging
  crypto-pipeline-prod-260528          prod (5-min ingestion live)

WIF provider:
  projects/101866768306/locations/global/workloadIdentityPools/github-actions/providers/github

Service accounts (per env):
  dbt-ci@<project>                     CI builds dbt
  crypto-ingest-fn@<project>           function runtime (staging/prod)
  crypto-scheduler@<project>           scheduler→function OIDC (staging/prod)
  tf-runner@<infra>                    plan-on-PR terraform CI
```

## Env vars (load via .env)
```bash
cd ~/Documents/learning/crypto-pipeline
cp .env.example .env       # first time only
set -a && source .env && set +a
```
Sets: `GCP_PROJECT_DEV`/`_STAGING`/`_PROD`, `DBT_TARGET=dev`, `DBT_METHOD=oauth`,
`DBT_PROFILES_DIR=$PWD/dbt`, `GCP_PROJECT=$GCP_PROJECT_DEV`,
`RAW_BUCKET=$GCP_PROJECT_DEV-crypto-raw`, `BQ_DATASET=crypto_raw`.

## Common commands

### Local dev
```bash
# ingest fresh dev data
.venv/bin/python ingestion/main.py

# build dbt models against dev
cd dbt && dbt build                          # writes <dev>.crypto_analytics.*
dbt build --select fct_crypto_prices         # one model

# inspect dev data
bq query --use_legacy_sql=false \
  "SELECT * FROM \`$GCP_PROJECT_DEV.crypto_analytics.fct_crypto_prices\` ORDER BY ingested_at DESC LIMIT 5"
```

### Switch env target (rare locally; CI does it normally)
```bash
DBT_TARGET=staging dbt build --target staging   # writes <stg>.crypto_analytics.*
# Don't write to prod from local — let CI do it via the PR flow.
```

### Operate the schedulers
```bash
# prod (cron is live; just inspect)
gcloud functions logs read crypto-ingest --gen2 --region=us-central1 \
   --project=$GCP_PROJECT_PROD --limit=20

# staging (resume → run → pause = the operator workflow)
gcloud scheduler jobs resume crypto-ingest-staging --location=us-central1 --project=$GCP_PROJECT_STAGING
gcloud scheduler jobs run    crypto-ingest-staging --location=us-central1 --project=$GCP_PROJECT_STAGING
gcloud scheduler jobs pause  crypto-ingest-staging --location=us-central1 --project=$GCP_PROJECT_STAGING

# pause prod (e.g., for a planned outage)
gcloud scheduler jobs pause  crypto-ingest-prod --location=us-central1 --project=$GCP_PROJECT_PROD
```

### Approve a prod deploy (required-reviewer gate)
- Web UI: Actions → run → **Review deployments** → approve.
- Or CLI:
  ```bash
  RUN=$(gh run list --branch main --limit 1 --json databaseId --jq '.[0].databaseId')
  PROD_ENV_ID=$(gh api repos/edwinrdrr/crypto-pipeline/environments/production --jq .id)
  gh api -X POST "repos/edwinrdrr/crypto-pipeline/actions/runs/$RUN/pending_deployments" \
    -F "environment_ids[]=$PROD_ENV_ID" -f state=approved -f comment="ship it"
  ```

## Cost rules (stay $0)
- Batch loads only (free, no streaming inserts).
- Incremental + partitioned dbt mart.
- ❌ Never enable Cloud Composer / Dataflow / large clusters.
- ✅ 4 budget alerts (~$5 in account currency) — one per project.

## The PR flow (the loop)
```bash
git checkout main && git pull
git checkout -b feature/my-change
# … edit dbt models …
( cd dbt && dbt build )                # try locally against dev first
git push -u origin feature/my-change && gh pr create --fill
# CI: pr-ephemeral builds Slim CI into dbt_ci_pr_<n> in dev project, drops after
# merge → staging job → prod job (waits for your approval) → manifest republished
```

## Gotchas (already baked into scripts, but knowing helps debug)
- Billing-account quota = 5 linked projects. We use 4 + 1 (`ithub-activity-pipeline`).
- ADC quota project must point at a *live* project (after deleting one, reset it).
- `gh api repos/<o>/<n> --jq .id` for numeric `repository_id` (`gh repo view --json id` is the GraphQL node id, not what WIF wants).
- For Terraform CI plan-only: pass `-lock=false` — `tf-runner` only has read access on tfstate.
- In `${VAR:?...}` error messages, **don't put an apostrophe** (bash treats it as opening a single quote).
- Schedulers cannot be force-run while paused — resume first, run, then pause.

## Where to read more
- `README.md` — current architecture + status.
- `docs/setup/environments.md` — Level-3 setup + use, layer-by-layer.
- `docs/start-here-mental-model.md` — what environments/push/CI-CD actually do.
- `docs/walkthrough-one-change.md` — a real traced change dev→staging→prod.
- `docs/faq.md` — consolidated Q&A.
- `LEARNING.md` — dated journey log (every PR, every gotcha).
