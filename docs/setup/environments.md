# Setting up & using environments (Level 3)

Practical guide: **how to create** dev / staging / prod (each is its own GCP project), and
**how to use them** day to day. Grounded in this repo — every step points at the actual file
or resource.

## What you'll have when done

- **4 GCP projects** all billing-linked under one billing account:
  - `crypto-pipeline-infra-260528` — shared infra: tfstate + ci-state buckets, WIF pool/provider
  - `crypto-pipeline-dev-260528` — dev (no Cloud Function)
  - `crypto-pipeline-stg-260528` — staging (Cloud Function, scheduler PAUSED)
  - `crypto-pipeline-prod-260528` — prod (Cloud Function, scheduler every 5 min)
- **One bucket per env** (`<project>-crypto-raw`) — *full* per-env data-plane isolation.
- **Two datasets per env** (`crypto_raw` + `crypto_analytics`) — names are the same in every
  project (the **project IS the env**).
- A `.env` that defaults local runs to **dev**; CI/cloud get their config from elsewhere.
- **WIF** keyless auth from GitHub Actions → GCP (no SA keys anywhere).
- **GitHub Environments** scoping secrets per env; `production` has a required reviewer.

---

## How environments are isolated at each layer (the truth table)

| Layer | dev | staging | prod | shared |
|---|---|---|---|---|
| **GCP project** | `…-dev-260528` | `…-stg-260528` | `…-prod-260528` | `…-infra-260528` (tfstate + WIF) |
| **GCS bucket** | `<dev>-crypto-raw` | `<stg>-crypto-raw` | `<prod>-crypto-raw` | `<infra>-ci-state` (dbt manifest), `<infra>-tfstate` |
| **BigQuery datasets** | `crypto_raw`, `crypto_analytics` | same names | same names | — |
| **Cloud Function** | *(not deployed)* | deployed | deployed | — |
| **Scheduler** | — | PAUSED (`0 */6 * * *`) | ENABLED (`*/5 * * * *`) | — |
| **dbt-ci SA** | per-project | per-project | per-project | — |
| **Function runtime SA** | — | per-project | per-project | — |
| **WIF pool/provider** | — | — | — | infra (impersonates the per-env SAs) |
| **CI/CD GitHub Environment** | `dev` | `staging` | `production` (required reviewer) | — |

This is the real-world enterprise pattern: project-per-env, separate IAM, separate buckets,
shared infra for cross-cutting concerns. Maps 1:1 to AWS (account-per-env) and Azure
(subscription-per-env).

---

## Setup (with `bootstrap.sh` and Terraform)

### 1. Install tools (one-time)
```bash
./scripts/install-tools.sh
export PATH="$HOME/google-cloud-sdk/bin:$HOME/bin:$PATH"
gcloud auth login && gcloud auth application-default login && gh auth login
```

### 2. Provision the 4 projects + everything
```bash
BILLING_ACCOUNT_ID=YOUR-ID ./scripts/bootstrap.sh
```
What it does (idempotent — safe to re-run):
1. Create 4 GCP projects, link billing, set per-project budget alert at ~$5.
2. Enable APIs per env (data APIs + function APIs in staging/prod; iam/sts in infra).
3. Create the **tfstate bucket** (versioned + lifecycle on old versions) in infra.
4. `terraform apply` per env using `modules/data-project/` → bucket + 2 datasets +
   `dbt-ci` SA (+ `crypto-ingest-fn` + `crypto-scheduler` SAs in staging/prod).
5. `terraform apply` infra → tfstate bucket (imports it), ci-state bucket, WIF pool +
   provider, cross-project SA impersonation bindings, tf-runner SA.

### 3. Configure GitHub Environments + per-env secrets
The bootstrap doesn't yet automate this (manual `gh api` calls):
```bash
USER_ID=$(gh api user --jq .id)
# Create environments
echo '{"wait_timer":0}' | gh api -X PUT repos/edwinrdrr/crypto-pipeline/environments/dev --input -
echo '{"wait_timer":0}' | gh api -X PUT repos/edwinrdrr/crypto-pipeline/environments/staging --input -
printf '{"wait_timer":0,"prevent_self_review":false,"reviewers":[{"type":"User","id":%s}]}' "$USER_ID" \
  | gh api -X PUT repos/edwinrdrr/crypto-pipeline/environments/production --input -

# Per-Environment secrets
gh secret set GCP_PROJECT_DEV     --env dev        --body "crypto-pipeline-dev-260528"
gh secret set GCP_PROJECT_STAGING --env staging    --body "crypto-pipeline-stg-260528"
gh secret set GCP_PROJECT_PROD    --env production --body "crypto-pipeline-prod-260528"
```

### 4. Seed each env's `crypto_raw.prices`
dbt's `source()` fails if the table doesn't exist. One quick ingestion per env:
```bash
cp .env.example .env && set -a && source .env && set +a
.venv/bin/python ingestion/main.py                                   # dev
GCP_PROJECT=$GCP_PROJECT_STAGING RAW_BUCKET=$GCP_PROJECT_STAGING-crypto-raw \
   .venv/bin/python ingestion/main.py                                 # staging
GCP_PROJECT=$GCP_PROJECT_PROD    RAW_BUCKET=$GCP_PROJECT_PROD-crypto-raw \
   .venv/bin/python ingestion/main.py                                 # prod
```

### 5. Deploy the function
```bash
ENV=staging PROJECT_ID=$GCP_PROJECT_STAGING ./ingestion/deploy.sh   # paused on create
ENV=prod    PROJECT_ID=$GCP_PROJECT_PROD    ./ingestion/deploy.sh   # */5 * * * *
```

---

## Where each environment's config lives (after the refactor)

| What | Where | Per-env? |
|---|---|---|
| Dataset / bucket / SA names within a project | Terraform module `modules/data-project/` | shared (same module everywhere) |
| Per-env project IDs + flags (e.g. `deploy_function`) | `terraform/envs/<env>/main.tf` + `terraform.tfvars` (gitignored) | yes — one folder per env |
| Local laptop defaults | `.env` (gitignored, copied from `.env.example`) | dev only |
| CI per-job project + SA | GitHub workflow `env:` block under each job's `environment:` | yes (job-scoped) |
| Repo secrets / Environment secrets | GitHub Secrets, scoped to each Environment | yes — `GCP_PROJECT_<ENV>` |
| Deployed function's runtime env | `ingestion/deploy.sh` → `--set-env-vars` baked onto the function | prod (and staging when triggered) |
| Shared CI artifacts (Slim CI manifest) | `gs://<infra>-ci-state/dbt-state/manifest.json` | shared (one source of truth) |

> Notable: there are no long-lived service-account keys anywhere. CI auth uses WIF
> (`google-github-actions/auth@v2` → short-lived OIDC token → impersonate per-env SA).

---

## Use

### Local: target dev (default)
```bash
set -a && source .env && set +a       # GCP_PROJECT_DEV, DBT_TARGET=dev, etc.
( cd dbt && dbt build )                # → crypto-pipeline-dev-260528.crypto_analytics.*
.venv/bin/python ingestion/main.py     # → crypto-pipeline-dev-260528.crypto_raw.prices
```

### Switch local target (rare; for debugging staging)
```bash
DBT_TARGET=staging GCP_PROJECT_STAGING=crypto-pipeline-stg-260528 \
  ( cd dbt && dbt build --target staging )
# You should not write to prod from local. Let CI do it.
```

### Per-PR ephemeral schema (CI does this for you)
On a PR, `pr-ephemeral` builds Slim CI into `dbt_ci_pr_<PR#>` **in the dev project**, then
drops it. You don't need to do anything special — see the CI logs to watch it.

### Operate the schedulers
```bash
# prod: every-5-min ingestion is automatic
gcloud functions logs read crypto-ingest --gen2 --region=us-central1 \
   --project=crypto-pipeline-prod-260528

# staging: run on demand (resume → run → pause)
gcloud scheduler jobs resume crypto-ingest-staging --location=us-central1 \
   --project=crypto-pipeline-stg-260528
gcloud scheduler jobs run    crypto-ingest-staging --location=us-central1 \
   --project=crypto-pipeline-stg-260528
gcloud scheduler jobs pause  crypto-ingest-staging --location=us-central1 \
   --project=crypto-pipeline-stg-260528
```

### Approve a prod deploy (GitHub Environments)
When you merge to main, the `prod` job in `dbt-ci.yml` (and the `scheduled-dbt` cron) pauses
for your approval. Go to:
- https://github.com/edwinrdrr/crypto-pipeline/actions → the run → **Review deployments** → approve.

Or via CLI:
```bash
RUN=$(gh run list --branch main --limit 1 --json databaseId --jq '.[0].databaseId')
PROD_ENV_ID=$(gh api repos/edwinrdrr/crypto-pipeline/environments/production --jq .id)
gh api -X POST "repos/edwinrdrr/crypto-pipeline/actions/runs/$RUN/pending_deployments" \
  -F "environment_ids[]=$PROD_ENV_ID" -f state=approved -f comment="ship it"
```

---

## Verify

```bash
# 1. All 4 projects exist and are billing-linked
gcloud billing projects list --billing-account=YOUR-BILLING-ACCOUNT-ID

# 2. Each env project has its 2 datasets
for p in dev stg prod; do bq ls --project_id=crypto-pipeline-$p-260528; done

# 3. WIF provider exists in infra
gcloud iam workload-identity-pools providers list \
   --project=crypto-pipeline-infra-260528 --location=global \
   --workload-identity-pool=github-actions

# 4. GitHub: zero repo-level secrets, per-env secrets set
gh secret list                   # empty
gh secret list --env dev         # GCP_PROJECT_DEV
gh secret list --env staging     # GCP_PROJECT_STAGING
gh secret list --env production  # GCP_PROJECT_PROD

# 5. Open a small test PR; the pr-ephemeral job authenticates via WIF and
#    builds dbt_ci_pr_<n> in crypto-pipeline-dev-260528.

# 6. Merge it; staging job runs; prod job waits for your approval; approve;
#    prod manifest republished to <infra>-ci-state.
```

---

## Related
- `../environments-and-cicd.md` — concepts (some examples reference older single-project layout; patterns still apply).
- `../start-here-mental-model.md` — what environments / push / CI/CD actually do.
- `../faq.md` — every question we worked through, consolidated.
- `../howto-playbook.md` — day-to-day task recipes.
- `../../README.md` — the live architecture.
