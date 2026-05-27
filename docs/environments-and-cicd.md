# Environments, CI/CD & Cloud for Data Engineering — a concept guide

A from-scratch explainer of the three ideas this project teaches, grounded in the
real `crypto-pipeline` you built. Read `LEARNING.md` for *what we did*; read this for
*why it works*.

> The whole thing in one sentence: **you isolate work into environments, move code
> between them through CI/CD, and use the cloud to make those environments cheap and
> reproducible — and in data engineering you promote the *transformation logic*, not
> the data.**

---

## 1. Environments (a.k.a. "stages")

An environment is an **isolated place to run your pipeline** — isolated in two ways:

- **Code isolation** — a version of the pipeline (a git branch / a deploy).
- **Data isolation** — its own datasets/tables, so one environment can't corrupt another.

The classic tiers, from least to most protected:

| Tier | Purpose | Who/what uses it | Data |
|------|---------|------------------|------|
| **dev** | build & experiment, break freely | each engineer (often a personal schema) | small / sampled |
| **staging** | realistic dress-rehearsal before prod | CI, reviewers | prod-like (copy/subset) |
| **prod** | the real thing powering dashboards/ML | end users, scheduled jobs | the real data |

Not every team uses all of them; small teams run **dev → prod**. The *concept* (isolate
work from production) is universal; the *number of tiers* varies.

### The data-engineering twist

In app development you promote **code**. In DE you also have **data**, and the rule is:

> **Promote the transformation logic, not the data.** Each environment points at its own
> datasets; you ship the dbt models (code) from dev → staging → prod, and each env *rebuilds*
> its own tables from its own (or prod-like) sources.

You rarely copy full prod data down — privacy (PII) and cost mean dev/test often use
sampled, synthetic, or masked data. That's also the #1 source of "worked in dev, broke in
prod" bugs.

### How this project does it

Environments = **BigQuery datasets**, selected by env var (not by changing code):

```
per-PR  ─► dbt_ci_pr_<n>          (ephemeral, created + dropped by CI)
dev     ─► crypto_analytics_dev
staging ─► crypto_analytics_staging
prod    ─► crypto_analytics
```

- The dbt `target` (in `profiles.yml`) picks the dataset; `generate_schema_name` keeps the
  name clean. Same code, different `DBT_TARGET` / `DBT_DATASET` — that's **promotion via
  config, not code**.
- **Per-PR ephemeral schemas**: every pull request builds into its *own* throwaway dataset,
  so two open PRs never collide and shared dev stays clean. Dropped when the PR run finishes.

---

## 2. CI/CD — the engine that moves code between environments

**CI (Continuous Integration)**: every change is automatically built and tested.
**CD (Continuous Delivery/Deployment)**: validated changes are automatically promoted to
the next environment.

The **git pull-request flow** is the engine. Nothing reaches prod except through it:

```
feature branch ──► Pull Request ──► CI (tests) ──► review ──► merge ──► CD (promote)
   (sandbox)         (the gate)      (auto)        (human)    │          │
                                                      main = source of truth
```

- **Branch = sandbox.** You break things safely, away from `main`.
- **CI = an automatic gate.** Tests/builds run on every PR. A **red PR doesn't get merged** —
  that's the whole point (you saw CI catch a real `dbt-utils` bug before it reached `main`).
- **Merge = promotion.** Merging to `main` triggers CD to staging, then prod.

### What CI runs on a *data* PR (and why it differs from app CI)

```
on Pull Request:
  1. install deps            (dbt deps)
  2. build only what changed (Slim CI — see below)
  3. run data-quality tests  (not_null, uniqueness, freshness, row-count anomalies)
  4. lint / compile checks
  → all into an ephemeral schema, dropped afterwards
```

**Tests are the gate.** In DE, `dbt test` failures fail the pipeline just like unit tests
fail an app build — bad data is a build break.

### What CD does on merge to `main`

```
on merge to main:
  staging : dbt build + test against crypto_analytics_staging
     │
     └─► prod : (only if staging passed) build crypto_analytics, then publish the manifest
```

The `prod` job depends on `staging` (`needs: staging`) — that dependency **is** the
promotion gate. (A bigger org adds a manual approval here via a GitHub Environment.)

### Slim CI — the highest-impact DE-CI technique

Rebuilding *every* model on every PR is slow and expensive. **Slim CI** rebuilds only the
models whose SQL changed, plus their downstream, and **defers** the rest to the prod tables:

```
dbt build --select state:modified.body+ --defer --state <prod-manifest>
```

It works by comparing your PR against the **prod `manifest.json`** (this project stores it in
GCS after each prod build). On a project with hundreds of models, this turns a 30-minute
check into seconds.

> Gotcha we hit: use `state:modified.body` (compares SQL only), **not** plain `state:modified`
> — the latter also compares the target schema, so ephemeral PR schemas make *every* model
> look "modified" and you lose the benefit.

---

## 3. Cloud — why all this is cheap and reproducible

The cloud is *why* multi-environment + CI/CD is practical:

- **Cheap, disposable environments** — spin up a dataset per PR, drop it after. No fixed
  hardware to buy.
- **Managed data services** — BigQuery (warehouse), Cloud Storage (data lake). Another
  "environment" is just another dataset/bucket prefix.
- **Infrastructure as Code (IaC)** — Terraform defines the bucket + datasets, so every
  environment is built reproducibly from code ("dev and prod are identical because the same
  Terraform built both").
- **Native CI/CD + serverless** — GitHub Actions, Cloud Functions, Cloud Scheduler — all
  free-tier here, so the whole project runs at ~$0/month.

### Config vs. secrets (the 12-Factor rule)

> **Config lives in the environment; secrets live in a secret manager — never in the repo.**

- **Config** (project id, dataset name, region): env vars / `--set-env-vars`. A `.env` file is
  fine *for local dev only*.
- **Secrets** (service-account keys, passwords): GitHub Secrets in CI; Secret Manager (or
  Workload Identity Federation, which removes long-lived keys entirely) in production.

---

## 4. The three "schedulers" — timer vs runner vs orchestrator

Easy to conflate; they're different rungs:

| Tool | What it is | Runs where | Orchestrates a multi-step pipeline? |
|------|------------|-----------|-------------------------------------|
| **Cloud Scheduler** | managed cron **timer** | cloud, 24/7, free | ❌ fires one trigger |
| **GitHub Actions cron** | scheduled CI **runner** | cloud, 24/7, free* | ⚠️ yes, a script of steps |
| **Airflow / Dagster** | a real **orchestrator** | local (dev) or managed ($$$) | ✅ a graph: deps, retries, backfills, UI |

A **timer** rings a bell; a **runner** runs a list of steps; an **orchestrator** runs a
*graph* of tasks, retries the flaky ones, backfills history, and shows you what happened.
In real DE you also CI/CD three separate things: **transform code** (dbt), **orchestration
code** (DAGs), and **infrastructure** (Terraform).

> Reality check: production Airflow (Cloud Composer/MWAA) costs ~$300+/mo. For a $0 project,
> a managed **timer + CI runner** covers real 24/7 work; you run Airflow locally just to learn
> the tool.

---

## 5. The mental model, all together

```
            cloud provides the rooms ───────────────────────────────────┐
                                                                          │
  ┌─────────┐   PR + CI    ┌─────────┐   merge + CD   ┌────────┐         │
  │   DEV   │ ───────────► │ STAGING │ ─────────────► │  PROD  │         │
  └─────────┘  (the gate)  └─────────┘  (promotion)   └────────┘         │
   build &                  realistic                 real data,         │
   break freely             rehearsal                 real consumers     │
        │                        │                         │             │
        └──── code promoted, data rebuilt per env ─────────┘             │
                                                                          │
  orchestration runs the pipeline on a schedule ◄─────────────────────────┘
```

- **Environments** = the labeled rooms (isolated code + data).
- **CI/CD** = the conveyor belt moving work between rooms, with quality gates.
- **Cloud** = the building that makes the rooms cheap and disposable.
- **Orchestration** = the clock + conductor that runs the pipeline on schedule.

---

## 6. Vocabulary to keep

- **Slim CI** — rebuild only changed models (`state:modified+`) + deferral.
- **Write-Audit-Publish (WAP) / blue-green** — build into a clone, test, then swap into prod
  (zero-downtime, never ship bad data to dashboards).
- **Per-PR ephemeral schemas** — each PR builds into a throwaway schema, dropped on merge.
- **Promotion via config, not code** — same code, different target/env var.
- **Tests as the gate** — `dbt test` / freshness / anomaly checks fail the pipeline.
- **Promote logic, not data** — ship transformations; each env rebuilds its own tables.
- **IaC** — environments defined in Terraform, built identically every time.
- **12-Factor config** — config from the environment, secrets from a secret manager.

See `README.md` → "Gotchas we hit" for the concrete traps (incremental `on_schema_change`,
the `state:modified.body` relation false-positive, runtime service accounts, budget currency).
