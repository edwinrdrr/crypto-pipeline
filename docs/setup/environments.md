# Setting up & using environments

The practical guide: **how to create** dev / staging / prod (set them up), and **how to use
them** day to day (pick which one your code runs against, never by editing code). Grounded in
this project (`crypto-pipeline`) — every step points at the artifact that exists today.

## What you'll have when done
- **5 BigQuery datasets** in your GCP project — *per environment* (raw + analytics × dev/staging/prod).
- **1 shared GCS bucket** — *not* per-env; isolation is at the dataset level. (See
  "[What's per-env vs shared](#whats-per-env-vs-shared-in-this-project-the-honest-reality)"
  for the trade-off and stricter alternatives.)
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

**Option B — `bq mk` (no Terraform)**
```bash
for ds in crypto_raw_dev crypto_raw crypto_analytics_dev crypto_analytics_staging crypto_analytics; do
  bq --location=US mk --dataset "$GCP_PROJECT:$ds"
done
gcloud storage buckets create gs://$GCP_PROJECT-crypto-raw --location=US
```
> **Trade-off without Terraform:** there's no single file that *defines* what exists; the
> "source of truth" is the cloud itself (or a setup script / wiki). You lose reproducibility
> (no `terraform apply` to rebuild in a new project) and you'll have to set lifecycle rules
> (e.g. 30-day auto-delete) by hand. Fine for learning or a one-off; teams beyond a couple of
> people use IaC.

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

### 3. (Optional) Override `generate_schema_name` — the **dbt-recommended** pattern

By default, dbt builds models that declare a custom schema (`+schema: marketing`) into
`<target.schema>_marketing`. Often you want just `marketing` *in prod*, but you do **NOT** want
to use the bare custom schema in dev/CI — every developer and PR would write to the same
`marketing` schema and clobber each other (see the official dbt warning below).

dbt's recommended pattern uses `target.name` to apply the custom schema **only in prod**:
```sql
-- dbt/macros/generate_schema_name.sql  (📁 already in this repo)
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- set default_schema = target.schema -%}
    {%- if target.name == 'prod' and custom_schema_name is not none -%}
        {{ custom_schema_name | trim }}
    {%- else -%}
        {{ default_schema }}
    {%- endif -%}
{%- endmacro %}
```
> 📚 **Quoted from dbt docs** — "Don't replace `default_schema` in the macro" with just
> `{{ custom_schema_name | trim }}`; doing so means developers overwrite each other's models
> in dev/CI. The pattern above is the recommended one.

Our project doesn't currently set `+schema:` on any model, so this macro effectively returns
`target.schema` everywhere — same as the default. It's here to **keep us safe if we ever do**
add a custom schema later.

> 💡 *Separate concern:* the "Slim CI rebuilds everything across environments" issue we hit is
> fixed by using `state:modified.body+` (compares SQL only), **not** by this macro. See
> `../faq.md` → "why `.body` and not plain `state:modified`?"

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

## What's per-env vs shared in this project (the honest reality)

You noticed correctly — **not everything in this project is per-env**. The doc's "5 datasets"
is per-env, but several other resources are **shared** across environments. Here's the truth:

| Resource | This project | Stricter real-world setups |
|---|---|---|
| **GCP project** | **ONE project** for all envs | one project **per env** (`org-data-dev`, `org-data-prod`) — the stricter pattern Google recommends for serious isolation |
| **BigQuery datasets** | ✅ **5 per-env** (`*_dev` / `_staging` / prod) | same — per-env is universal |
| **GCS bucket** | **ONE shared** bucket (`<project>-crypto-raw`) — dev runs & the prod function write to it | **per-env buckets** (`crypto-raw-dev`, `crypto-raw`) for full isolation |
| **Service accounts** (dbt-ci, function runtime, scheduler) | **per project**, used by all envs within it | same (per project) OR per-env if projects are per-env |
| **dbt code / repo** | **one repo, one codebase** — promoted via config | same — one code, one repo per data project |

### "We don't use dev on GCS, etc.?" — yes, exactly

Right catch. **GCS is the asymmetry.** In this project, dev's ingestion (local runs) and prod's
ingestion (the deployed function) both write to the **same bucket** — they just land files
under different date-partitioned paths and load into *different datasets*. Isolation is at the
**dataset level**, not the bucket level.

This is a pragmatic choice for small/learning scale. The cost is small (the bucket auto-deletes
files after 30 days; everything reads from BigQuery anyway). For stricter teams you'd add a
second bucket `crypto-raw-dev` and route dev ingestion there.

### Three levels of env isolation in GCP (where this project sits)

1. **One project, datasets per env** ← *this project* — simplest, fine for ≤ team-size workloads.
2. **One project, datasets + buckets per env** — better data-plane isolation.
3. **One project per env** (`...-dev`, `...-prod`) — Google's recommended pattern for serious
   isolation: separate IAM, separate quotas, "completely isolated" code/data ([GCP docs][gcp-iso]).

Migrating between these is mostly a Terraform rewrite — promote via config, not code.

[gcp-iso]: https://cloud.google.com/appengine/docs/legacy/standard/java/creating-separate-dev-environments "Google: 'it is vital that environments be completely isolated from one another, with very different operator-access permissions'"

---

## Where each environment's config actually lives (not just `.env`!)

`.env` is **only your laptop, only dev-by-default.** Staging and prod config lives in
*version-controlled files* (Terraform + `profiles.yml`) and the platforms that run them
(CI workflow, deploy script). Here's the full map:

| What | Where it lives | Per-env? | Used by |
|---|---|---|---|
| Dataset **names** (raw_dev, raw, analytics_dev, analytics_staging, analytics) | `terraform/main.tf` (creates them) | all listed | Terraform |
| Bucket name | `terraform/main.tf` (`${project}-crypto-raw`) | shared | TF, code, deploy |
| dbt **target blocks** (dev/staging/prod: each with its own `dataset:`, `method:`) | `dbt/profiles.yml` | yes — one block per env | dbt |
| **Local laptop defaults** (which env to target, local auth, paths) | `.env` (gitignored; copy from `.env.example`) | **dev only** | local dbt/ingestion |
| **CI per-job env** (e.g. staging job sets `DBT_TARGET=staging RAW_DATASET=crypto_raw`) | `.github/workflows/dbt-ci.yml` (`env:` per job) | yes — per CI job | GitHub Actions |
| **Repo secrets** (`GCP_PROJECT`, `GCP_SA_KEY`) | GitHub → Settings → Secrets | shared across CI jobs | CI |
| **Deployed function's runtime config** (`GCP_PROJECT`, `RAW_BUCKET`, `BQ_DATASET=crypto_raw`) | `ingestion/deploy.sh` (`--set-env-vars`) → stored on the function | prod (it's the deployed function) | Cloud Function at runtime |
| Service accounts (`dbt-ci@`, `crypto-ingest-fn@`, `crypto-scheduler@`) | Created by `scripts/bootstrap.sh` / `deploy.sh` | per **project**, not per env | CI / function / scheduler |

### Worked example: where is the **prod dataset name** actually written?

`crypto_analytics` (the prod analytics dataset) appears in **3 places**, on purpose:

1. **`terraform/main.tf`** — `datasets["crypto_analytics"]` *creates* it.
2. **`dbt/profiles.yml`** — `outputs.prod.dataset: crypto_analytics` *tells dbt* to write to it.
3. **`.github/workflows/dbt-ci.yml`** — the `prod` job runs `dbt build --target prod`, which *reads* (2).

It is **NOT in `.env`** and you never set it from your laptop. Only CI touches it.

### `.env` is for, and isn't for

| `.env` is for | `.env` is **NOT** for |
|---|---|
| Your laptop's defaults so commands "just work" (`DBT_TARGET=dev`, datasets, project) | Staging/prod dataset names (those live in `profiles.yml` + Terraform) |
| The project id + bucket name (so the same code works in your fork) | Secrets (SA keys, tokens) — those go in Secret Manager / GitHub Secrets |
| Things that vary per developer/machine | Anything CI or the deployed function reads — they have their own sources |

### Where does the "prod machine" actually live?

There isn't one — you don't own a server. **Prod runs in two places, both managed:**
- The **Cloud Function** (`crypto-ingest`) runs serverlessly on GCP every 5 min — config baked
  in by `deploy.sh` via `--set-env-vars`.
- The **dbt prod build** runs on a **GitHub Actions runner** every 6 h (or on merge to main)
  using the workflow's `env:` block + GitHub Secrets.

---

## Use

### Day-to-day: pick an env by changing ONE thing, never by editing code

| Goal | Universal way | Shortcut that works here |
|------|---------------|--------------------------|
| Build to **dev** (default) | `dbt build --target dev` | `dbt build` (`.env` sets `DBT_TARGET=dev`) |
| Build to **staging** locally (rare) | `dbt build --target staging` | `DBT_TARGET=staging dbt build` |
| Build to **prod** locally | ⚠️ **don't** — let CI do it on merge | (CI runs `dbt build --target prod`) |
| Your **own dev schema** (avoid colliding) | personal namespace | `DBT_DATASET=dbt_$USER dbt build` |
| **Per-PR ephemeral schema** | CI sets it automatically | `DBT_DATASET=dbt_ci_pr_<n>` (in workflow) |

> 📚 `--target` is the dbt-documented **universal** way to switch target ([dbt docs](https://docs.getdbt.com/reference/global-configs/about-global-configs)).
> `DBT_TARGET` is **not** a dbt built-in env var — it works here because **our `profiles.yml`**
> reads it: `target: "{{ env_var('DBT_TARGET', 'dev') }}"`. Both achieve the same thing; CI uses
> env vars (set in workflow `env:`), interactive use can prefer `--target`.

### Switching environments locally
For one command vs the rest of the shell:
```bash
dbt build --target staging           # universal — works anywhere
# or, because of our profiles.yml's env_var() pattern:
DBT_TARGET=staging dbt build         # just this one command
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
