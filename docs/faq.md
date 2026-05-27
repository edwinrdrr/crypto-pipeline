# FAQ — everything we cleared up

Every question worked through while building this project, answered crisply and grounded in
the real pipeline. For the full mental model read `start-here-mental-model.md` first; this is
the quick-reference for "wait, how does X work again?"

---

## Environments & "local"

**Does real-world data engineering actually use dev / test / staging / prod?**
Yes — isolating work from production is universal. The *number* of tiers varies (small teams
run dev → prod; bigger/regulated orgs add staging, qa, uat). The concept is always the same.

**What's the difference between dev / staging / prod?**
They're separate **cloud databases** that differ in who touches them, what data they hold, and
the cost of breaking them:

| | dev | staging | prod |
|---|---|---|---|
| run against by | you (laptop) + PR checks | CI on merge | CI after staging passes |
| data | small / throwaway | prod-like | the real data |
| if it breaks | nobody cares | caught before prod | dashboards/users break |

**Is "local" a fourth environment?**
No. **Local = your laptop** — the computer where you write code and run it. `dev/staging/prod`
are cloud databases. Your laptop *targets* dev; it doesn't *contain* it.

**From my laptop, which environment do I touch?**
**dev only** (ideally your own dev schema, `DBT_DATASET=dbt_$USER`). Writing to staging/prod is
**CI/CD's job** — doing it from a laptop bypasses the PR/review/test gate. *Reading* prod
(querying to verify, or Slim CI deferral) is fine; *writing* prod from local is not.
Your `.env` defaults to `DBT_TARGET=dev`, so this is the safe default.

---

## git push & CI/CD

**Is pushing only for prod?**
No. `git push` just uploads code to GitHub. A pushed **branch + PR** is tested on **dev**; only
**merging to `main`** promotes to **staging → prod**. Same push, different destination.

**Are dev/staging/prod "only local" and unrelated to CI/CD?**
The opposite. They're cloud databases, and **CI/CD is exactly what moves your code through
them**. They're the stations on the conveyor belt.

**How are environments, CI/CD, and cloud related?**
Cloud = the building (cheap, disposable rooms). Environments = the labeled rooms. CI/CD = the
conveyor belt with quality gates moving work between rooms. Orchestration = the clock running
the pipeline on a schedule.

**What stops bad code reaching prod?**
The PR gate: CI runs tests on every PR, and a **red check blocks the merge**. You saw this catch
a real `dbt-utils` bug before it hit `main`.

---

## Config & secrets (.env)

**Do you set `environment=dev` in a `.env` to "do dev"?**
Almost — good instinct. An env var *does* select the environment (here it's `DBT_TARGET=dev`).
But: (1) it *points at* an existing cloud DB, doesn't create one; (2) `.env` is a **local**
convenience — CI/cloud inject the same vars themselves; (3) **secrets never go in `.env`**.

**`export` vs `.env` — which is better?**
They're the **same thing** — `.env` is just your `export` lines saved to a file so you don't
retype them. We standardized on `.env` locally for convenience. Best practice =
**config from the environment, secrets from a secret manager**: `.env` locally, platform
injection (workflow `env:`, `--set-env-vars`) in CI/cloud.

**So the "real world" doesn't use `.env`?**
It uses `.env` **for local dev only**. Nobody ships a `.env` to production — prod config comes
from the platform, prod secrets from a secret manager (or Workload Identity Federation, which
removes long-lived keys entirely).

**Where does each environment's config actually come from?**

| Where it runs | How vars are set |
|---|---|
| laptop | `.env` (load: `set -a && source .env && set +a`) |
| CI | workflow `env:` + GitHub **Secrets** |
| Cloud Function | `--set-env-vars` + **Secret Manager** |

---

## Architecture

**Does the extraction go straight into BigQuery?**
No — it lands in **Cloud Storage first** (raw `.jsonl`), then loads to BigQuery. This is the
**ELT-via-data-lake** pattern: the raw file is a replayable safety copy if a load fails or the
schema changes. Both the landing and the load are free.

**Why batch loads, not streaming?**
Batch loads into BigQuery are **free** regardless of frequency; streaming inserts cost money.
At 5-min cadence, batch is both cheaper and simpler.

**Why is the mart incremental?**
So each run only processes *new* rows (cheap, fast, stays in the free 1 TB). Note: incremental
models need `on_schema_change='append_new_columns'` or new columns silently won't appear.

---

## Cost

**Can I really do this free on GCP?**
Yes. It lives inside the **Always Free tier** (BigQuery 1 TB queries + 10 GB storage, GCS 5 GB,
Cloud Functions, Cloud Scheduler) — which never expires.

**Do I need the $300 free-trial credit?**
No. The credit is just a buffer for anything *beyond* free, which we deliberately avoid. Even
with $0 credit, this runs at ~$0/month.

**What does running 24/7 for a year cost?**
~**$0–$0.50/year** (see README "Cost projection"). The only line item that can register is GCS
write operations; everything else stays inside Always Free.

**What would actually cost real money?**
Cloud Composer (managed Airflow, ~$300+/mo), Dataflow, or large clusters — all of which we
**never enable**. The $5 budget alert catches anything unexpected.

---

## Orchestration

**What is Cloud Scheduler vs GitHub Actions vs Airflow?**

| Tool | What it is | Runs where | Multi-step pipeline? |
|---|---|---|---|
| Cloud Scheduler | a cron **timer** | cloud, 24/7, free | ❌ fires one trigger |
| GitHub Actions cron | a scheduled **runner** | cloud, 24/7, free* | ⚠️ a script of steps |
| Airflow / Dagster | an **orchestrator** | local (dev) or managed ($$$) | ✅ a graph: deps, retries, UI |

A timer rings a bell; a runner runs a list; an orchestrator runs a *graph* with retries,
backfills, and observability.

**Is local Airflow useless if it only runs on my laptop?**
For *running* a real 24/7 pipeline — yes, local Airflow is dev/learning-only (it runs only
while your machine is up). For *learning the orchestrator* (DAGs, retries, the UI) — very
useful. Production Airflow means Cloud Composer (~$300+/mo), which we avoid; for free 24/7 we
use Cloud Scheduler (ingest) + GitHub Actions cron (transform).

**Is GitHub Actions free on a private repo?**
2,000 minutes/month free (then billed). Keep schedules modest — we run the dbt transform every
6h (~240 min/mo), **not** hourly (~1,800 min/mo, which nearly blows the budget).

---

## Where to go deeper
- **Mental model from zero** → `start-here-mental-model.md`
- **A real recorded trace** (one change dev→staging→prod) → `walkthrough-one-change.md`
- **Why it all works** → `environments-and-cicd.md`
- **How to do tasks** → `howto-playbook.md`
- **Setup / reproduce / gotchas** → `../README.md`
