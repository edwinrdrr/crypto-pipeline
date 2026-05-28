# Environments — concept overview (read this first)

The conceptual reference for the **Level-3 (4 GCP projects)** architecture. Read this to
understand *what* gets created and *why*; follow the **numbered docs (01–10)** for the
actual reproducible steps.

---

## The 4 projects

| Project | Holds | Why it's separate |
|---------|-------|-------------------|
| `crypto-pipeline-infra-260528` | tfstate bucket, ci-state bucket (Slim CI manifest), WIF pool + provider, tf-runner SA | Cross-cutting infra used by all envs; centralizing here avoids duplication |
| `crypto-pipeline-dev-260528` | bucket + 2 datasets + `dbt-ci` SA | Engineers' sandbox; per-PR ephemeral schemas; **no deployed Cloud Function** (local-only ingestion) |
| `crypto-pipeline-stg-260528` | same + `crypto-ingest-fn` + `crypto-scheduler` SAs + Cloud Function + Scheduler (PAUSED) | Pre-prod dress rehearsal; deployment path validated; operator-triggered ingestion |
| `crypto-pipeline-prod-260528` | same + Cloud Function + Scheduler (every 5 min) | The real thing — continuous ingestion + dbt analytics |

**Project = environment.** Inside each env project, resource names **don't carry env
suffixes** (just `crypto_raw`, `crypto_analytics`, `<project>-crypto-raw`). The project ID
tells you which env you're in.

This is the **real-world enterprise pattern**: project-per-env, separate IAM, separate
buckets, shared infra for cross-cutting concerns. Maps 1:1 to AWS (account-per-env) and
Azure (subscription-per-env).

---

## Layer-by-layer isolation (the truth table)

| Layer | dev | staging | prod | shared (infra) |
|---|---|---|---|---|
| **GCP project** | `…-dev-260528` | `…-stg-260528` | `…-prod-260528` | `…-infra-260528` |
| **GCS bucket** | `<dev>-crypto-raw` | `<stg>-crypto-raw` | `<prod>-crypto-raw` | `<infra>-ci-state` (dbt manifest), `<infra>-tfstate` |
| **BigQuery datasets** | `crypto_raw`, `crypto_analytics` | same names | same names | — |
| **Cloud Function** | *(not deployed)* | deployed | deployed | — |
| **Scheduler** | — | PAUSED (`0 */6 * * *`) | ENABLED (`*/5 * * * *`) | — |
| **`dbt-ci` SA** | per-project | per-project | per-project | — |
| **Function runtime SA** | — | per-project | per-project | — |
| **Scheduler SA** | — | per-project | per-project | — |
| **WIF pool / provider** | — | — | — | infra (impersonates the per-env SAs) |
| **`tf-runner` SA** (read-only) | — | — | — | infra (terraform plan-on-PR) |
| **CI/CD GitHub Environment** | `dev` | `staging` | `production` (required reviewer) | — |

---

## How config flows through the layers

Different "where it runs" gets config from different sources — but they all populate the
**same set of variables**:

```
Laptop  ───────► .env                ───►  dbt/ingestion target the DEV project
                                          (DBT_TARGET=dev, GCP_PROJECT_DEV)

GitHub  ───────► workflow `env:` +    ───►  WIF auth: impersonate dbt-ci@<env-project>
Actions          per-Env secrets             (GCP_PROJECT_DEV/_STAGING/_PROD per Environment)

Cloud   ───────► --set-env-vars      ───►  Function runs as crypto-ingest-fn@<env-project>
Function         baked at deploy            (GCP_PROJECT, RAW_BUCKET, BQ_DATASET)

Terraform ─────► terraform.tfvars    ───►  per-env state in infra's tfstate bucket
                 (per env folder)           (project_id, dev_project_id, etc.)
```

`.env` (laptop, gitignored) is the **only** place local secrets-adjacent config lives. CI
and the deployed function inject their config differently. **No long-lived SA-key JSONs
exist anywhere** — Workload Identity Federation replaced them.

---

## Why the project-per-env pattern (vs Level-1 single-project)

| Concern | Level 1 (single project, env via dataset suffix) | Level 3 (project per env) |
|---|---|---|
| IAM blast radius | one project's IAM grants reach all envs' resources | each env has independent IAM |
| Cost tracking per env | needs labels + billing-export queries | natural — billing reports by project |
| Quotas per env | shared across all envs | independent per env |
| Audit ("who wrote to prod analytics?") | "the dbt-ci SA" — but it touches all envs | "the dbt-ci SA *in the prod project*" |
| Org/folder grouping (multi-team) | impossible | natural — projects fit into folders |
| Deletion / cleanup | wipe one project = wipe everything | wipe per env |
| **Real-world adoption** | small teams or shortcuts | enterprise + mature DE teams |

---

## What runs *where* by default

| Activity | Where it runs | Which project it touches |
|---|---|---|
| `dbt build` on your laptop | laptop | dev (via `.env`) |
| PR `pr-ephemeral` job | GitHub CI | dev (ephemeral schema `dbt_ci_pr_<n>`) |
| merge `staging` job | GitHub CI | staging |
| merge `prod` job (after approval) | GitHub CI | prod |
| `terraform-ci.yml` plan-on-PR | GitHub CI | all 4 (read-only via `tf-runner`) |
| Cloud Scheduler ingestion (every 5 min) | cloud | prod |
| Cloud Scheduler ingestion (PAUSED) | cloud | staging (operator-triggered) |
| `scheduled-dbt.yml` cron (every 6h) | GitHub CI | prod (after approval) |
| Local Airflow DAG (`extract_load → dbt_run → dbt_test`) | laptop (docker) | dev |

---

## Where to go next

- [`README.md`](README.md) — index of all setup docs in order.
- [`01-prerequisites.md`](01-prerequisites.md) → [`08-verify.md`](08-verify.md) — reproduce
  from nothing.
- [`09-scheduled-dbt.md`](09-scheduled-dbt.md) — the prod-refresh cron.
- [`10-troubleshooting.md`](10-troubleshooting.md) — common errors + fixes.
- [`fork-and-customize.md`](fork-and-customize.md) — find-and-replace if you fork.
- [`../environments-and-cicd.md`](../environments-and-cicd.md) — the deeper conceptual guide.
