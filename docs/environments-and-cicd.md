# Environments, CI/CD & Cloud for Data Engineering — a concept guide (Level 3)

A from-scratch explainer of the three ideas this project teaches, grounded in the
**Level-3 (4 GCP projects)** architecture. Read `LEARNING.md` for *what we did*; read this
for *why it works*.

> The whole thing in one sentence: **you isolate work into environments (each its own GCP
> project), move code between them through CI/CD (keyless via WIF), and use the cloud to
> make those environments cheap and reproducible — and in data engineering you promote the
> *transformation logic*, not the data.**

---

## 1. Environments (a.k.a. "stages")

An environment is an **isolated place to run your pipeline** — isolated in two ways:

- **Code isolation** — a version of the pipeline (a git branch / a deploy).
- **Data + IAM isolation** — its own project (and inside it, datasets, buckets, service
  accounts, IAM), so one environment can't reach into another.

The classic tiers, from least to most protected:

| Tier | Purpose | Who/what uses it | Data |
|------|---------|------------------|------|
| **dev** | build & experiment, break freely | each engineer (locally) + per-PR CI | small / sampled / on-demand |
| **staging** | realistic dress-rehearsal before prod | CI, reviewers; operator-triggered ingestion | prod-like (manual or scheduled less often) |
| **prod** | the real thing powering dashboards/ML | end users, scheduled jobs | the real, continuously ingested data |

Plus, at Level 3 we add:

- **infra** — a shared project for cross-cutting concerns (Terraform state, CI artifact
  state, the WIF pool). Not an "environment" you target; supporting infra.

### The data-engineering twist

In app development you promote **code**. In DE you also have **data**, and the rule is:

> **Promote the transformation logic, not the data.** Each environment points at its own
> project; you ship the dbt models (code) from dev → staging → prod, and each env *rebuilds*
> its own tables from its own sources.

You rarely copy full prod data down — privacy (PII) and cost mean dev/staging often use
sampled, synthetic, or on-demand data. That's also the #1 source of "worked in dev, broke
in prod" bugs.

### How this project does it (Level 3)

Environments = **separate GCP projects**, with identical-shape resources inside:

```
crypto-pipeline-dev-260528         → crypto_raw, crypto_analytics; bucket; dbt-ci SA
crypto-pipeline-stg-260528         → same names; + paused function + scheduler
crypto-pipeline-prod-260528        → same names; + active function + scheduler (every 5 min)
crypto-pipeline-infra-260528       → tfstate, ci-state, WIF pool/provider, tf-runner SA
```

- **Project = environment.** Inside a project, dataset names don't carry env suffixes.
- The dbt `target` (in `profiles.yml`) picks the *project* via `env_var('GCP_PROJECT_<ENV>')`.
  Same code, different env var resolved to the right project — that's
  **promotion via config, not code**.
- **Per-PR ephemeral schemas** (`dbt_ci_pr_<n>` in the *dev* project): every pull request
  builds into its own throwaway schema, so two open PRs never collide and shared dev stays
  clean.

---

## 2. CI/CD — the engine that moves code between environments

**CI (Continuous Integration)**: every change is automatically built and tested.
**CD (Continuous Delivery/Deployment)**: validated changes are automatically promoted
through environments.

The **git pull-request flow** is the engine. Nothing reaches prod except through it:

```
feature branch ──► Pull Request ──► CI (tests in dev) ──► review ──► merge
                                            │
                       ───────────────────► staging job
                                            │
                                            ▼
                                   prod job (paused for required-reviewer)
                                            │
                                            ▼
                                       prod job (after approval)
                                            │
                                            ▼
                              publish manifest to ci-state (next PR's baseline)
```

- **Branch = sandbox.** You break things safely, away from `main`.
- **CI = an automatic gate.** Tests/builds run on every PR. A **red PR doesn't get merged**.
- **Merge = automatic promotion to staging.**
- **Required reviewer = manual gate to prod.** Staging running green isn't enough; *I* have
  to approve.

### What CI runs on a *data* PR (and why it differs from app CI)

```
on Pull Request:
  1. authenticate to GCP via WIF (no SA key file)
  2. download prod manifest from ci-state bucket  (Slim CI baseline)
  3. build only state:modified.body+ (changed models + downstream)
  4. into the dev project's ephemeral schema (dbt_ci_pr_<n>)
  5. run data-quality tests (not_null, uniqueness, freshness)
  6. drop the schema, even on failure
```

**Tests are the gate.** In DE, `dbt test` failures fail the pipeline just like unit tests
fail an app build — bad data is a build break.

### What CD does on merge to `main`

```
on merge to main:
  staging : authenticate via WIF → impersonate dbt-ci@stg → build crypto_analytics
     │
     └─► prod : (only if staging passed AND I approve) authenticate via WIF →
                  impersonate dbt-ci@prod → build crypto_analytics → publish manifest
```

The `prod` job depends on `staging` (`needs: staging`) *and* on a manual approval
(`environment: production` with required-reviewer rule). Both gates.

### Slim CI — only rebuild what changed

Rebuilding *every* model on every PR is slow and expensive. **Slim CI** rebuilds only the
models whose SQL changed, plus their downstream, and **defers** the rest to the prod tables:

```
dbt build --select state:modified.body+ --defer --state <prod-manifest>
```

It works by comparing your PR's manifest against the **prod manifest in the ci-state
bucket**. On a project with hundreds of models, this turns a 30-minute check into seconds.

> Why `.body` and not plain `state:modified`? Plain `modified` also compares each model's
> *target relation* (database/schema/identifier). Across projects this would flag every
> model. `.body` compares the compiled SQL body only — the right comparison across project
> boundaries.

### Keyless auth — Workload Identity Federation

The CI jobs do **not** carry a JSON service-account key. Instead:

```
GitHub Action ─► OIDC token (subject = "repo:edwinrdrr/crypto-pipeline:...")
              ─► google-github-actions/auth@v2
              ─► exchanges OIDC for short-lived ADC (≤1 hour)
              ─► impersonates dbt-ci@<env-project>
              ─► runs gcloud / bq / dbt
```

The trust relationship is configured in IAM via a **WIF pool + OIDC provider** in the infra
project, with an **attribute condition** restricting to `repository_id == 1251445803`
(immutable GitHub repo id — better than name; survives renames).

This is the modern best-practice: **no keys to rotate, no keys to leak**.

---

## 3. Cloud — why all this is cheap and reproducible

The cloud is *why* multi-environment + CI/CD is practical:

- **Cheap, disposable environments** — spinning up a project is free. We have 4 of them.
- **Managed data services** — BigQuery (warehouse), Cloud Storage (data lake). Another
  environment = another project with its own datasets and buckets.
- **Infrastructure as Code (IaC)** — Terraform defines per-env folders calling shared
  modules; per-env state stored in versioned GCS. "Same module, different `project_id` ->
  identical resources in different projects."
- **Native CI/CD + serverless + keyless** — GitHub Actions, Cloud Functions, Cloud
  Scheduler, WIF — all free-tier here, so the whole project runs at ~$0/month.

### Config vs. secrets (the 12-Factor rule, plus modern keyless)

> **Config lives in the environment; secrets live in a secret manager — or, increasingly,
> don't exist at all (use WIF).**

- **Config** (project id, dataset name, region): env vars / per-Env GitHub Secrets /
  `--set-env-vars`. A `.env` file is fine *for local dev only*.
- **Secrets** historically: GCP Secret Manager, Vault, GitHub Secrets. **In this repo:
  zero long-lived SA-key JSONs exist anywhere** thanks to WIF.

---

## 4. The three "schedulers" — timer vs runner vs orchestrator

Easy to conflate; they're different rungs:

| Tool | What it is | Runs where | Orchestrates a multi-step pipeline? |
|------|------------|-----------|-------------------------------------|
| **Cloud Scheduler** | managed cron **timer** | cloud, 24/7, free | ❌ fires one trigger |
| **GitHub Actions cron** | scheduled CI **runner** | cloud, 24/7, free | ⚠️ yes, a script of steps |
| **Airflow / Dagster** | a real **orchestrator** | local (dev) or managed ($$$) | ✅ a graph: deps, retries, backfills, UI |

A **timer** rings a bell; a **runner** runs a list of steps; an **orchestrator** runs a
*graph* of tasks, retries the flaky ones, backfills history, and shows you what happened.
In real DE you also CI/CD three separate things: **transform code** (dbt), **orchestration
code** (DAGs), and **infrastructure** (Terraform).

> Reality check: production Airflow (Cloud Composer/MWAA) costs ~$300+/mo. For a $0 project,
> Cloud Scheduler (prod ingest) + Actions cron (transform refresh) covers real 24/7 work.
> Local Airflow is just for learning the tool.

---

## 5. The mental model, all together

```
            cloud provides the rooms ───────────────────────────────────┐
                                                                          │
   dev project ──► staging project ──► (approval) ──► prod project        │
        ▲                ▲                                ▲                │
        │   (you/PR CI)  │ (merge CI)            (merge CI after approval) │
        │                                                                  │
  shared infra project: tfstate · ci-state · WIF pool/provider · tf-runner │
                                                                          │
  orchestration runs the pipeline on a schedule ◄─────────────────────────┘
```

- **Environments** = the labeled rooms (each a GCP project).
- **CI/CD** = the conveyor belt moving work between rooms, with quality gates *and* a
  manual gate to prod.
- **WIF** = the lockless badge system letting CI step into rooms without carrying keys.
- **Cloud** = the building that makes the rooms cheap and disposable.
- **Orchestration** = the clock + conductor that runs the pipeline on schedule.

---

## 6. Vocabulary to keep

- **Project per env** — each env is its own GCP project (real-world best practice).
- **Slim CI** — rebuild only changed models (`state:modified.body+`) + deferral.
- **Write-Audit-Publish (WAP) / blue-green** — build into a clone, test, then swap into
  prod (zero-downtime).
- **Per-PR ephemeral schemas** — each PR builds into a throwaway schema, dropped on merge.
- **Promotion via config, not code** — same code, different env var resolved per env.
- **Tests as the gate** — `dbt test` / freshness / anomaly checks fail the pipeline.
- **Promote logic, not data** — ship transformations; each env rebuilds its own tables.
- **IaC** — environments defined in Terraform, built identically.
- **Remote state** — Terraform state in versioned GCS, per-env prefix.
- **Workload Identity Federation (WIF)** — keyless GitHub Actions → GCP.
- **GitHub Environments** — per-env secret scoping + protection rules (required reviewer).

See `README.md` / `LEARNING.md` for the concrete traps we hit (incremental
`on_schema_change`, the `state:modified.body` relation false-positive, billing-account
quota, ADC quota project after deletes, `gh repo view` returning the GraphQL node id).
