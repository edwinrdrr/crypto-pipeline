# Data-warehouse setup — new-project runbook

A phased template for spinning up a new data-warehouse / dbt project — what a tech lead
hands a new DE so they know **what to do, in what order, and who owns each step**. Real
teams keep something like this as an internal wiki page; **mature shops also automate
Phases 1–5 with internal tooling** (Terraform modules, repo templates with workflows
pre-wired). For this project, `scripts/bootstrap.sh` is the scripted version of those phases.

## Scope legend (key idea: distinguish what's shared from what isn't)
- 🌐 **ORG-ONCE** — done once for the whole organization (the platform/infra team).
- 📦 **PROJECT-ONCE** — done once per data project (your scope as the project DE).
- 🌿 **PER-ENV** — done once per environment within the project.
- 👤 **PER-DEV** — each engineer on their own laptop.

> Grounded in this repo (`crypto-pipeline`) — every phase points at the artifact you can read.

---

## Phase 0 — Org-level prerequisites 🌐
Owned by the platform/infra team. If you're solo, you do these once and forget.

- **GCP organization & billing account** (one billing acct → many projects).
- **GitHub organization** (or user) — where repos live; SSO if applicable.
- **Identity baseline** — Google Workspace users/groups; baseline IAM roles.
- **Networking** (VPC, private connectivity) — skip on free-tier learning.
- **Secret Manager backbone** + key-rotation policy.
- **Cost-guardrail template** — standard budget/alert pattern reused per project.

> Solo / learning: you = the platform team. For this project we only had billing + GitHub.

---

## Phase 1 — GCP project & access 📦
A **fresh project per pipeline** keeps blast radius small and cleanup easy.

- Create a dedicated project under the billing account. Naming: `<purpose>-<env|alias>`.
- Link billing + a **$5–10 budget alert** scoped to **this** project.
- Enable APIs the project actually uses (BigQuery, Storage, Cloud Functions, Run,
  Cloud Build, Artifact Registry, Eventarc, Billing Budgets).
- Set ADC quota project so client libraries bill the right project.

📁 This project: `crypto-pipeline-260527-18241`. Done by `scripts/bootstrap.sh` Phase 1–2.

---

## Phase 2 — Infrastructure as Code (IaC) 📦
Define cloud resources in code so every environment is reproducible.

- **Terraform** for: GCS bucket(s), BigQuery datasets, lifecycle rules.
- **State backend** in GCS (often one bucket per org or per project).
- `terraform.tfvars` per environment (gitignored); `.example` committed.

📁 `terraform/` — bucket + 5 datasets, applied.

---

## Phase 3 — Environments 🌿
Promote **logic, not data**: every environment is its own dataset/namespace.

- Per-environment datasets with a clear naming convention:
  `<domain>_raw[_env]`, `<domain>_analytics[_env]`.
- **Per-PR ephemeral schemas** (`dbt_ci_pr_<n>`) for CI isolation.
- (Mature teams) **per-developer dev schemas** (`dbt_<user>`) for local work.

📁 `crypto_raw_dev`, `crypto_raw`, `crypto_analytics_dev`, `crypto_analytics_staging`,
`crypto_analytics` + ephemeral `dbt_ci_pr_<n>`.

---

## Phase 4 — Repository & branch protection 📦
One repo per data project is standard. Branch protection makes the PR gate real.

- Create the repo (private unless explicitly a public portfolio).
- **Protect `main`**: require PR review, require CI green, no force-pushes.
- Decide merge style (**squash** is conventional for clean history).

📁 `edwinrdrr/crypto-pipeline` (private). Branch protection isn't enforced for solo dev,
but the discipline is.

---

## Phase 5 — Service accounts & secrets 📦 (mostly) / 🌐 (some)
**This is the "what's shared vs per-project" question** — get this wrong and you have an
audit / least-privilege nightmare.

| What | Scope | Why |
|---|---|---|
| **CI service account** (e.g. `dbt-ci@<project>`) | **📦 per project** | least privilege; per-project audit; key rotation isolated |
| **Function runtime SA** (e.g. `crypto-ingest-fn@`) | **📦 per project** | the function's runtime identity; never use the default compute SA |
| **Scheduler SA** | **📦 per project** | OIDC audience-scoped to *this* project's function |
| **Custom IAM role definitions** | **🌐 org** | one definition reused across projects |
| **Workload Identity Federation (WIF) pool** | **🌐 org** | one pool maps GitHub identities → per-project SAs (no long-lived keys) |
| **Secret Manager** the service | **🌐 enabled org-wide** | shared service... |
| **Secrets inside Secret Manager** | **📦 per project** | ...with per-project secrets |
| **GitHub Secrets on a repo** | **📦 per repo** | `GCP_PROJECT`, `GCP_SA_KEY` (or WIF) per repo |

### ⭐ Your direct question — answered

> **Do you create a CI service account once per company, or once per project?**

**Per project.** Every project gets its own `dbt-ci@<project>` (and its own function/scheduler SAs).
The reasoning isn't fashion — it's three concrete things:

1. **Least privilege.** A per-project SA can only touch *that* project's BigQuery/GCS. A shared
   SA needs broad access → a leak compromises everything.
2. **Auditability.** "Who wrote to `analytics`?" is answerable per project. With a shared SA, every
   project's CI shows up as the same identity.
3. **Key rotation blast radius.** Rotating a per-project key affects one repo. Rotating a shared
   key requires coordinating every repo at once.

What **is** shared at the org level:
- The **role templates** (a standard "dbt-ci roles" definition reused everywhere).
- A **WIF pool** (modern best practice — removes long-lived keys entirely; GitHub auths to GCP
  with a short-lived token).
- **Provisioning scripts/Terraform modules** that *create* the per-project SAs identically.

So: the *recipe* is shared, the *SAs* are not. In our setup, even multiple developers on the
same project all use the same project-level CI SA (it's the CI's identity, not a person's) —
but they each have their *own* personal access for local work.

📁 `dbt-ci@…`, `crypto-ingest-fn@…`, `crypto-scheduler@…` — all scoped to this project.

---

## Phase 6 — dbt project skeleton 📦 / 👤
The transformation layer.

- **Repo structure:** `models/staging/`, `models/marts/`, `macros/`, `tests/`, `seeds/`.
- **`profiles.yml`** with **dev / staging / prod** targets, env-driven via `DBT_TARGET`,
  `DBT_DATASET`, `RAW_DATASET`, `DBT_METHOD`.
- **`generate_schema_name` macro** to keep per-env schema names clean.
- **`packages.yml`** for shared deps (`dbt-utils`); **commit `package-lock.yml`** for reproducible builds.
- **Tests + source freshness** declared in `_*.yml` (the data-quality gate).
- 👤 Each engineer installs dbt in a venv locally, uses their own dev schema.

📁 `dbt/` — has all of the above.

---

## Phase 7 — CI/CD 📦
The conveyor belt that promotes code through environments.

- **PR job (Slim CI):** build only `state:modified.body+` into the ephemeral PR schema → tests → drop schema.
- **Merge job (staging):** `dbt build --target staging`; **prod job needs staging**.
- **Prod job publishes** `target/manifest.json` to a state bucket — next PR's Slim CI baseline.

📁 `.github/workflows/dbt-ci.yml`.

---

## Phase 8 — Orchestration 📦
Pick the rung that matches the need (cost-aware!):

| Tool | When to use | Cost |
|---|---|---|
| **Cloud Scheduler** | trigger one endpoint on a cron | free |
| **GitHub Actions cron** | scheduled multi-step script | free* (2k min/mo private repo) |
| **Airflow / Dagster (managed)** | real DAGs: deps, retries, backfills, UI | **paid** (Composer ~$300+/mo) |
| **Local Airflow** | learning + DAG development | free, dev-only |

📁 `gcloud scheduler crypto-ingest-5min` + `scheduled-dbt.yml` (every 6h) + local
`airflow/dags/crypto_pipeline_dag.py`.

---

## Phase 9 — Observability 📦
See the data, and know when it breaks.

- **Dashboard:** Looker Studio (free, BigQuery-native) on the analytics tables.
- **Alerts:** GitHub Actions failure email (free), `dbt source freshness`, GCP Cloud Monitoring,
  optional Slack/Discord webhooks.
- **dbt tests + freshness** as the data-quality gate.

📁 `docs/dashboard.md`, `docs/alerts.md`; freshness in `dbt/models/staging/_crypto__sources.yml`.

---

## Phase 10 — Documentation & handoff 📦
A project lead's "you can be on-call for this" baseline.

- **README** with run/reproduce + gotchas.
- **Operator playbook** for daily tasks (add a model, debug red CI, backfill, roll back).
- **Concepts/architecture** docs so a new joiner can ramp.
- **On-call runbook** + alert routing (who gets paged for what — N/A for solo).

📁 `README.md`, `docs/howto-playbook.md`, `docs/environments-and-cicd.md`,
`docs/start-here-mental-model.md`, `docs/walkthrough-one-change.md`, `docs/faq.md`,
`LEARNING.md`, `CLAUDE.md`.

---

## Per-developer local setup 👤
Each engineer, once per machine:

1. `scripts/install-tools.sh` — gcloud, terraform, dbt-bigquery, gh.
2. `gcloud auth login && gcloud auth application-default login && gh auth login`.
3. `cp .env.example .env` (edit if needed) → `set -a && source .env && set +a`.
4. (Recommended) Set `DBT_DATASET=dbt_$USER` for a personal dev schema (Phase 3).

---

## Common "shared vs per-project" questions

| Resource | Scope | Notes |
|---|---|---|
| GCP project | 📦 per pipeline | fresh project = small blast radius |
| Billing account | 🌐 org-shared | one account, many projects |
| Service accounts | 📦 per project | least privilege, per-project audit |
| IAM role definitions | 🌐 shared | one template reused via Terraform modules |
| Workload Identity Federation pool | 🌐 shared | best practice; removes long-lived keys |
| Terraform modules | 🌐 shared | the *module* is shared; the *call* is per project |
| dbt packages / macros | 🌐 sharable | publish as an internal dbt package |
| GitHub workflows | 🌐 sharable | reusable workflows (`workflow_call`) |
| GitHub repo secrets | 📦 per repo | `GCP_PROJECT`, `GCP_SA_KEY` (or WIF) |
| Datasets / data | 🌿 per env per project | never cross-env writes |
| Cloud Scheduler jobs | 📦 per project | scoped to the project's functions |

---

## How this maps to what's already in your project

- Phase 0 → mostly N/A (solo). | Phase 1 → `scripts/bootstrap.sh` §1–2.
- Phase 2 → `terraform/`. | Phase 3 → 5 datasets + per-PR ephemeral schemas.
- Phase 4 → `edwinrdrr/crypto-pipeline`. | Phase 5 → three per-project SAs.
- Phase 6 → `dbt/`. | Phase 7 → `.github/workflows/dbt-ci.yml`.
- Phase 8 → Cloud Scheduler + Actions cron + local Airflow.
- Phase 9 → `docs/dashboard.md` + `docs/alerts.md`. | Phase 10 → this entire `docs/` set.
