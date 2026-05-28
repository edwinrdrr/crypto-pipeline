# Data-warehouse setup — new-project runbook (Level-3 edition)

A phased template for spinning up a new data-warehouse / dbt project — what a tech lead
hands a new DE so they know **what to do, in what order, and who owns each step**. Real
teams keep something like this as an internal wiki page; **mature shops also automate
Phases 1–6 with internal tooling** (Terraform modules, repo templates with workflows
pre-wired). For this project, `scripts/bootstrap.sh` is the scripted version of those phases.

This is the **Level-3 edition** — the real-world best-practice baseline (one GCP project
per env, Workload Identity Federation, remote Terraform state, GitHub Environments). The
previous "data-warehouse-setup" doc covered the Level-1 simplified version; that's now
superseded by this guide.

## Scope legend
- 🌐 **ORG-ONCE** — done once for the whole organization (platform/infra team).
- 📦 **PROJECT-ONCE** — done once per data project (project DE's scope).
- 🌿 **PER-ENV** — done once per environment within the project.
- 👤 **PER-DEV** — each engineer on their own laptop.

> Grounded in this repo (`crypto-pipeline`) — every phase points at the artifact you can read.

---

## Phase 0 — Org-level prerequisites 🌐
Owned by the platform/infra team. If you're solo, you do these once and forget.

- **GCP organization & billing account** (one billing acct → many projects).
  - ⚠️ Default billing-account project-link **quota is 5** for newer accounts; ask for an
    increase early, OR plan to delete unused projects before adding new ones.
- **GitHub organization** (or user) — where repos live; SSO if applicable.
- **Identity baseline** — Google Workspace users/groups; baseline IAM roles.
- **Cost-guardrail template** — standard budget/alert pattern reused per project.

> Solo / learning: you = the platform team. For this project we used a personal billing
> account, which constrained project count.

---

## Phase 1 — Per-env GCP projects + a shared "infra" project 📦
**This is the real-world Level-3 pattern: one project per env, plus one for shared infra.**

- Create **4 projects** under the billing account:
  - `<service>-infra-<suffix>` — tfstate, ci-state, WIF pool, tf-runner SA.
  - `<service>-dev-<suffix>` / `-stg-<suffix>` / `-prod-<suffix>`.
- Naming: include the env in the project ID so it's obvious which env you're operating in.
- Link billing + a **per-project $5–10 budget alert**.
- Enable APIs **per role** (data APIs everywhere; function/run/scheduler APIs in
  staging+prod; iamcredentials/sts + billingbudgets in infra).

📁 This project: `crypto-pipeline-{infra,dev,stg,prod}-260528`. Done by `scripts/bootstrap.sh`
Phases 1–3.

---

## Phase 2 — Infrastructure as Code (IaC) 📦
Define cloud resources in code so every env is reproducible.

- **Terraform** structured as **shared modules + per-env folders**:
  ```
  terraform/
    modules/{data-project, wif}/
    envs/{dev, staging, prod, infra}/   # each calls modules; has its own backend.tf
  ```
- **Remote state in versioned GCS** in the infra project, with per-env prefix
  (`envs/<env>/`). Object versioning enabled + 30-version retention lifecycle.
- `terraform.tfvars` per environment (gitignored); `.example` committed.
- `.terraform.lock.hcl` per env **IS committed** for reproducible provider versions.

📁 `terraform/` — full layout.

---

## Phase 3 — Environments 🌿
Promote **logic, not data**: every environment is its own project + namespace.

- Per-env GCP project. Inside: same resource names everywhere (`crypto_raw`,
  `crypto_analytics`, `<project>-crypto-raw` bucket).
- **Per-PR ephemeral schemas** in the dev project (`dbt_ci_pr_<n>`) for CI isolation.
- **No env suffix on dataset names** — the project IS the env.

📁 The 3 env projects + the per-PR ephemerals; shape mirrored in `dbt/profiles.yml`.

---

## Phase 4 — Repository + branch protection 📦
One repo per data project is standard.

- Create the repo (**public** if portfolio + you want free required reviewers on
  Environments; private otherwise + Pro/Team plan for the same gate).
- **Protect `main`**: require PR review, require CI green, no force-pushes, **squash merges**.
- A **secret-history sweep** before going public (we used grep patterns; in larger orgs use
  `gitleaks` / `trufflehog`).

📁 `edwinrdrr/crypto-pipeline` (public).

---

## Phase 5 — Service accounts, IAM, and WIF 📦 (mostly) / 🌐 (some)
**Get this wrong and you have an audit / least-privilege nightmare.**

| What | Scope | Notes |
|------|-------|-------|
| `dbt-ci@<env-project>` SA | **📦 per env** | least-privilege; per-env audit; impersonated via WIF |
| `crypto-ingest-fn@<env-project>` SA | **📦 per env** | function runtime; staging+prod only |
| `crypto-scheduler@<env-project>` SA | **📦 per env** | scheduler→function OIDC; staging+prod only |
| `tf-runner@<infra>` SA | **📦 per project** | terraform plan-on-PR; cross-project viewer + securityReviewer |
| **Workload Identity Federation pool/provider** | **📦 single pool in infra** | one provider per pool; restricted by `repository_id` attribute condition |
| Custom IAM roles | **🌐 org** | shared templates |
| Secret Manager | **🌐 enabled org-wide** | with **per-project secrets** (none used in this repo — WIF replaces them) |
| GitHub Secrets — **per-Environment** | **📦 per repo** | `GCP_PROJECT_<ENV>` scoped to its Environment, NOT repo-level |
| GitHub Environments | **📦 per repo** | `dev`, `staging`, `production`; production gets required reviewer |

### ⭐ Common questions, answered

**Per-env SAs or one shared SA across envs?** → **Per env.** Least privilege, per-env audit,
key-rotation blast radius limited. (For us, the keys-themselves are gone — WIF — but the
SAs still partition by env.)

**WIF or SA key JSON files?** → **WIF.** Short-lived OIDC tokens, no key to rotate or leak.
GitHub Actions native integration via `google-github-actions/auth@v2`. The trust is
attribute-conditioned on the immutable `repository_id`.

**Repo-level secrets or per-Environment secrets?** → **Per Environment.** Scoping secrets
to the Environment that needs them limits accidental cross-env exposure and lets you apply
Environment protection rules.

📁 SAs created by `terraform/modules/data-project/` (data SAs) and `envs/infra/main.tf`
(tf-runner + WIF impersonation bindings).

---

## Phase 6 — dbt project skeleton 📦 / 👤

- Repo structure: `models/staging/`, `models/marts/`, `macros/`, `tests/`, `seeds/`.
- `profiles.yml` with **dev / staging / prod** targets, each with
  `project: env_var('GCP_PROJECT_<ENV>')` — same dataset name, different project.
- `generate_schema_name` macro using the **dbt-recommended** `target.name == 'prod'`
  conditional pattern (avoids the anti-pattern dbt explicitly warns about).
- `packages.yml` for shared deps; **commit `package-lock.yml`** for reproducibility.
- **Tests + source freshness** declared in `_*.yml` (the data-quality gate).
- 👤 Each engineer installs dbt in `.venv`; uses their own dev schema (`dbt_$USER`).

📁 `dbt/` — has all of the above.

---

## Phase 7 — CI/CD 📦
The conveyor belt that promotes code through environments.

- **Auth: Workload Identity Federation** — `google-github-actions/auth@v2` with
  `workload_identity_provider:` pointing at the infra WIF provider; per-job
  `service_account:` is the env's `dbt-ci@<project>` SA.
- **Per-job `environment:` keyword** (`dev`/`staging`/`production`) for per-Env secret
  scoping AND protection rules.
- **`production` Environment has a required-reviewer rule** — prod deploys wait for manual
  approval (free on public repos).
- **PR job (Slim CI)**: build `state:modified.body+` into an ephemeral schema in the
  **dev project**; drop after.
- **Merge job: staging → prod** (prod `needs: staging` AND waits for required-reviewer).
- **Prod publishes `manifest.json`** to the shared `<infra>-ci-state` bucket — next PR's
  Slim CI baseline.

📁 `.github/workflows/dbt-ci.yml`.

### Terraform CI (separate workflow)
- `terraform-ci.yml` — `plan-on-PR` per env (matrix), posted as PR comment.
- Auth via `tf-runner@<infra>` SA (cross-project read-only).
- Auto-apply on merge **intentionally not wired** (real teams gate apply behind a separate
  approval; the manual `terraform apply` from `bootstrap.sh` covers it here).

📁 `.github/workflows/terraform-ci.yml`.

---

## Phase 8 — Orchestration 📦
Pick the rung that matches the need (cost-aware!):

| Tool | When to use | Cost |
|---|---|---|
| **Cloud Scheduler** | trigger one endpoint on a cron | free |
| **GitHub Actions cron** | scheduled multi-step script | free* (unlimited for public repos) |
| **Airflow / Dagster (managed)** | real DAGs: deps, retries, backfills, UI | **paid** (Composer ~$300+/mo) |
| **Local Airflow** | learning + DAG development | free, dev-only |

📁 Cloud Scheduler `crypto-ingest-prod` (every 5 min in prod), `crypto-ingest-staging`
(every 6h, PAUSED) + Actions cron `scheduled-dbt.yml` + local `airflow/`.

---

## Phase 9 — Observability 📦
See the data + know when it breaks.

- **Dashboard**: Looker Studio (free, BigQuery-native) on prod's analytics tables.
- **Alerts**: GitHub Actions failure email (free), `dbt source freshness`, GCP Cloud
  Monitoring on the prod function, optional Slack/Discord webhooks.
- **dbt tests + freshness** as the data-quality gate.

📁 `docs/dashboard.md`, `docs/alerts.md`; freshness in
`dbt/models/staging/_crypto__sources.yml`.

---

## Phase 10 — Documentation & handoff 📦
A project lead's "you can be on-call for this" baseline.

- **README** with run/reproduce + gotchas (current architecture).
- **Operator playbook** for daily tasks (add a model, debug red CI, backfill, roll back).
- **Concepts/architecture** docs so a new joiner can ramp.
- **On-call runbook** + alert routing (who gets paged for what).

📁 `README.md`, `docs/howto-playbook.md`, `docs/environments-and-cicd.md`,
`docs/start-here-mental-model.md`, `docs/walkthrough-one-change.md`, `docs/faq.md`,
`LEARNING.md`, `CLAUDE.md`, `docs/setup/environments.md`.

---

## Per-developer local setup 👤
Each engineer, once per machine:

1. `scripts/install-tools.sh` — gcloud, terraform, dbt-bigquery, gh.
2. `gcloud auth login && gcloud auth application-default login && gh auth login`.
3. `cp .env.example .env` (set the three `GCP_PROJECT_*` ids) →
   `set -a && source .env && set +a`.
4. (Recommended) `DBT_DATASET=dbt_$USER` for a personal local schema (Phase 3).

---

## Common "shared vs per-project" questions

| Resource | Scope | Notes |
|---|---|---|
| GCP project | **📦 per env** (Level 3) | best-practice; complete isolation |
| Billing account | 🌐 org-shared | one account, many projects |
| Service accounts | 📦 per env | least privilege, per-env audit |
| Custom IAM roles | 🌐 shared | one template reused via Terraform modules |
| **Workload Identity Federation pool** | 📦 single pool in infra project | best practice; one pool, not duplicated; restricted by `repository_id` |
| Terraform modules | 🌐 shared | the *module* is shared; the *call* is per env |
| dbt packages / macros | 🌐 sharable | publish as an internal dbt package |
| GitHub workflows | 🌐 sharable | reusable workflows (`workflow_call`) |
| GitHub repo secrets | 📦 per repo | **and per Environment** within repo |
| Datasets / data | 📦 per env per project | never cross-env writes |
| Cloud Scheduler jobs | 📦 per env (only in envs that need them) | prod always-on; staging paused |

---

## How this maps to what's in your project

- Phase 0 → mostly N/A (solo). | Phase 1 → `scripts/bootstrap.sh` Phase 1–3.
- Phase 2 → `terraform/` (modules + per-env folders + remote state in infra).
- Phase 3 → 4 GCP projects + per-PR ephemerals in dev.
- Phase 4 → `edwinrdrr/crypto-pipeline` (public). | Phase 5 → per-env SAs + WIF.
- Phase 6 → `dbt/`. | Phase 7 → `.github/workflows/{dbt-ci,scheduled-dbt,terraform-ci}.yml`.
- Phase 8 → Cloud Scheduler (prod 5-min, staging paused) + Actions cron + local Airflow.
- Phase 9 → `docs/dashboard.md` + `docs/alerts.md`.
- Phase 10 → this entire `docs/` set.
