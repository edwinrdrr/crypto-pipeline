# Setting up & using environments

The practical guide: **how to create** dev / staging / prod (set them up), and **how to use
them** day to day (pick which one your code runs against, never by editing code). Grounded in
this project (`crypto-pipeline`) — every step points at the artifact that exists today.

## What you'll have when done
- **5 BigQuery datasets** in your GCP project — one per environment (raw + analytics × dev/staging/prod).
- A `.env` that defaults your local runs to **dev**, so you can't accidentally touch prod.
- dbt knows 3 targets (dev/staging/prod) **plus per-PR ephemeral schemas**, all selected via env vars.
- You can switch environments by changing **one variable**, never by editing pipeline code.

## Prerequisite
A working GCP project with billing + the right APIs enabled. See `setup-cloud-gcp.md` *(coming
next)*. For this project we already have `crypto-pipeline-260527-18241`.

---

## Setup

### 1. Create one dataset per environment

Two ways — Terraform is recommended (reproducible, code-reviewed); `bq` is fine for a quick
experiment.

**Option A — Terraform (recommended)**
```hcl
# terraform/main.tf  (📁 already in this repo)
locals {
  datasets = {
    crypto_raw_dev           = "Raw - dev"
    crypto_raw               = "Raw - prod"
    crypto_analytics_dev     = "dbt models - dev"
    crypto_analytics_staging = "dbt models - staging"
    crypto_analytics         = "dbt models - prod"
  }
}
resource "google_bigquery_dataset" "datasets" {
  for_each   = local.datasets
  dataset_id = each.key
  location   = "US"
}
```
```bash
cd terraform && terraform init && terraform apply
```

**Option B — `bq mk` (one-off)**
```bash
for ds in crypto_raw_dev crypto_raw crypto_analytics_dev crypto_analytics_staging crypto_analytics; do
  bq --location=US mk --dataset "$GCP_PROJECT:$ds"
done
```

### 2. Teach dbt about each environment (`profiles.yml`)

Each env = one **target**. Make them **env-driven** so the same code can target any env without
edits:
```yaml
# dbt/profiles.yml  (📁 already in this repo)
crypto:
  target: "{{ env_var('DBT_TARGET', 'dev') }}"     # default: dev
  outputs:
    dev:
      type: bigquery
      method:  "{{ env_var('DBT_METHOD',  'oauth') }}"
      dataset: "{{ env_var('DBT_DATASET', 'crypto_analytics_dev') }}"  # overridable for personal/PR schemas
      project: "{{ env_var('GCP_PROJECT') }}"
      location: US
    staging:
      type: bigquery
      method: "{{ env_var('DBT_METHOD', 'service-account') }}"
      dataset: crypto_analytics_staging
      project: "{{ env_var('GCP_PROJECT') }}"
      location: US
    prod:
      type: bigquery
      method: "{{ env_var('DBT_METHOD', 'service-account') }}"
      dataset: crypto_analytics
      project: "{{ env_var('GCP_PROJECT') }}"
      location: US
```

### 3. Clean schema names with one macro (do this once)

Without this, dbt builds tables into `<target_schema>_<custom>` — ugly and breaks Slim CI (see
`../faq.md` → "why `.body`"). Override:
```sql
-- dbt/macros/generate_schema_name.sql  (📁 already in this repo)
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- if custom_schema_name is none -%}{{ target.schema }}
    {%- else -%}{{ custom_schema_name | trim }}{%- endif -%}
{%- endmacro %}
```

### 4. Make local default to dev (`.env`)

So every local run targets dev unless you *deliberately* override:
```bash
# .env.example  (📁 already in this repo) — copy to .env and load each shell:
#   set -a && source .env && set +a
GCP_PROJECT=crypto-pipeline-260527-18241
RAW_BUCKET=crypto-pipeline-260527-18241-crypto-raw
BQ_DATASET=crypto_raw_dev                  # ingestion writes to dev raw
DBT_METHOD=oauth                           # local auth
DBT_TARGET=dev
RAW_DATASET=crypto_raw_dev                 # dbt reads dev raw
DBT_DATASET=crypto_analytics_dev           # dbt writes dev analytics
DBT_PROFILES_DIR=$PWD/dbt
```

---

## Use

### Day-to-day: pick an env by changing ONE variable, never by editing code

| Goal | Set | Command |
|------|------|---------|
| Build to **dev** (default) | nothing — `.env` already has it | `dbt build` |
| Build to **staging** locally (rare) | override target | `DBT_TARGET=staging dbt build` |
| Build to **prod** locally | ⚠️ **don't** — let CI do it on merge | (CI runs `dbt build --target prod`) |
| Your **own dev schema** (avoid colliding) | personal namespace | `DBT_DATASET=dbt_$USER dbt build` |
| **Per-PR ephemeral schema** | CI sets it automatically | `DBT_DATASET=dbt_ci_pr_<n>` (in workflow) |

### Switching environments locally
For one command vs the rest of the shell:
```bash
DBT_TARGET=staging dbt build         # just this one command
# or
export DBT_TARGET=staging            # for the rest of this shell
```

### The full promotion path (CI does this for you)
You write to **dev** from your laptop. **CI** handles staging and prod when you merge:
```
branch → PR → CI builds dbt_ci_pr_<n>     (dev, ephemeral, dropped after)
merge to main → CI builds crypto_analytics_staging
              → if staging passes, builds crypto_analytics  (prod)
```
See `../walkthrough-one-change.md` for a real recorded trace of this exact flow.

---

## Verify

```bash
# 1. each env has its dataset
for ds in crypto_analytics_dev crypto_analytics_staging crypto_analytics; do
  bq ls --project_id=$GCP_PROJECT $ds
done

# 2. local dbt targets dev by default (no edits needed)
cd dbt && dbt debug | grep -E "target|method|dataset"

# 3. a quick build into dev (no risk to staging/prod)
dbt build --select +fct_crypto_prices --target dev
```
You should see `target=dev`, `method=oauth`, `dataset=crypto_analytics_dev`, and tables appear
**only** in `crypto_analytics_dev` — staging/prod untouched.

---

## Common adjustments

- **Add a new environment** (e.g. `qa`):
  1. Terraform: add `crypto_analytics_qa` to the `datasets` map → `terraform apply`.
  2. `profiles.yml`: add a `qa` target (copy `staging`, change `dataset`).
  3. CI: add a job step that builds `--target qa` wherever you want it in the promotion chain.

  That's "**promotion via config, not code**" — the pipeline code never changes; only the
  wiring (datasets + targets + env vars).

- **Per-developer dev schemas** (real-team practice):
  Add `DBT_DATASET=dbt_$USER` to each engineer's local `.env`. Two engineers' work never
  overwrites each other. CI does the same idea with `dbt_ci_pr_<n>`.

- **Reading prod from local** (rare, read-only): query prod via `bq query` to verify a change
  landed. **Never** *write* to prod from local — let CI do it.

---

## Related
- `setup-cloud-gcp.md` *(coming)* — provisioning GCP (prerequisite for this).
- `setup-cicd.md` *(coming)* — how CI promotes through these envs (PR → staging → prod).
- `setup-dbt.md` *(coming)* — the dbt project itself (models/tests/packages).
- `../environments-and-cicd.md` — *why* this all works (concepts).
- `../start-here-mental-model.md` — environments = cloud DBs (the foundation).
- `../walkthrough-one-change.md` — a real change going dev → staging → prod.
