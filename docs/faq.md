# FAQ — everything we cleared up (Level 3)

Every question worked through while building this project, answered crisply and grounded
in the **Level-3 (4 GCP projects)** architecture. For the full mental model read
`start-here-mental-model.md` first; this is the quick-reference.

---

## Environments & "local"

**Does real-world data engineering actually use dev / test / staging / prod?**
Yes — isolating work from production is universal. The *number* of tiers varies (small teams
run dev → prod; bigger/regulated orgs add staging, qa, uat). The concept is always the same.

**What's the difference between dev / staging / prod here?**
Each is its own **GCP project** (Level 3 isolation). Inside, the same resource names
(`crypto_raw`, `crypto_analytics`, `<project>-crypto-raw` bucket) — the *project* tells you
which env.

| | dev | staging | prod |
|---|---|---|---|
| GCP project | `…-dev-260528` | `…-stg-260528` | `…-prod-260528` |
| Cloud Function | not deployed | deployed (scheduler PAUSED) | deployed (every 5 min) |
| Run against by | you (laptop) + PR `pr-ephemeral` | CI `staging` job on merge | CI `prod` job *after* approval |
| Data | small / throwaway | small (operator triggers) | continuously growing |
| If it breaks | nobody cares | caught before prod | dashboards/users break |

**Is "local" a fourth environment?**
No. **Local = your laptop**. dev/staging/prod are GCP projects. Your laptop *targets* dev;
it doesn't *contain* dev.

**From my laptop, which environment do I touch?**
**dev only** (your `.env` defaults to `DBT_TARGET=dev`). Writing to staging/prod is **CI/CD's
job** — doing it from a laptop bypasses the PR/review/test gate AND the required-reviewer
gate. *Reading* prod (querying to verify, or Slim CI deferral) is fine; *writing* prod from
local is not.

**Is there an even stricter isolation than project-per-env?**
At a personal-account scale: not really. With a GCP Organization, you'd add folder-level IAM,
shared VPC, and org policies. We don't have an Organization, so this is the strictest
practical level for a solo project.

---

## git push & CI/CD

**Is pushing only for prod?**
No. `git push` just uploads code to GitHub. A pushed **branch + PR** is tested in the **dev
project** via `pr-ephemeral`. Only **merging to `main`** promotes to **staging**, then waits
for required-reviewer approval, then **prod**.

**Are dev/staging/prod "only local" and unrelated to CI/CD?**
The opposite. They're cloud projects, and **CI/CD is exactly what moves your code through
them**. They're the destinations on the conveyor belt.

**How are environments, CI/CD, and cloud related?**
Cloud = the building. Environments = the labeled rooms (one per project). CI/CD = the
conveyor belt with quality gates moving work between rooms. Orchestration = the clock that
runs the pipeline on schedule.

**What stops bad code from reaching prod?**
Two gates: (1) CI runs tests on every PR; a red check blocks the merge. (2) The `production`
GitHub Environment has a required-reviewer rule, so even after merge the prod job pauses
until I click Approve.

---

## Config, secrets, and `.env`

**Do you set `environment=dev` in a `.env` to "do dev"?**
Almost — good instinct. An env var *does* select the environment (here it's `DBT_TARGET=dev`).
But: (1) it *points at* the dev **project**, doesn't create one; (2) `.env` is a **local**
convenience — CI/cloud inject the same vars themselves via per-Environment secrets and
`--set-env-vars`; (3) **secrets never go in `.env`** — and there are no long-lived SA keys
anywhere now (WIF replaced them).

**`export` vs `.env` — which is better?**
They're the **same thing** — `.env` is just your `export` lines saved to a file so you don't
retype them. We standardized on `.env` locally for convenience. Best practice =
**config from the environment, secrets from a secret manager**: `.env` locally,
per-Environment secrets in CI, `--set-env-vars` on the deployed Cloud Function.

**So the "real world" doesn't use `.env`?**
It uses `.env` **for local dev only**. Nobody ships a `.env` to production — prod config
comes from the platform, prod secrets from a secret manager (or, like ours,
**Workload Identity Federation** which removes long-lived keys entirely).

**Where does each environment's config come from?**

| Where it runs | How vars are set |
|---|---|
| laptop | `.env` (load: `set -a && source .env && set +a`) |
| GitHub CI | per-job `environment:` keyword → per-Environment secrets (`GCP_PROJECT_DEV`/`_STAGING`/`_PROD`) |
| Cloud Function | `--set-env-vars` baked at deploy time |
| Terraform | `terraform.tfvars` per env folder (gitignored) |

**Are there any SA key files anywhere?**
**No.** All GCP auth from GitHub Actions uses **Workload Identity Federation**:
`google-github-actions/auth@v2` exchanges the GitHub OIDC token for a short-lived ADC,
impersonating each env's `dbt-ci@<project>` SA. Zero long-lived keys. (The old `GCP_SA_KEY`
repo secret was deleted in PR #28.)

---

## Architecture

**Does the extraction go straight into BigQuery?**
No — it lands in **Cloud Storage first** (raw `.jsonl`), then loads to BigQuery. This is the
**ELT-via-data-lake** pattern: the raw file is a replayable safety copy if a load fails or
the schema changes. Both the landing and the load are free.

**Why batch loads, not streaming?**
Batch loads into BigQuery are **free** regardless of frequency; streaming inserts cost money.
At a 5-min cadence, batch is both cheaper and simpler.

**Why is the mart incremental?**
So each run only processes *new* rows (cheap, fast, stays in the free 1 TB). Note:
incremental models need `on_schema_change='append_new_columns'` or new columns silently
won't appear (we hit this in PR #9 back at Level 1).

**Where does the dbt Slim CI manifest live in Level 3?**
In the **infra project**'s `ci-state` bucket:
`gs://crypto-pipeline-infra-260528-ci-state/dbt-state/manifest.json`. The prod CI job
publishes it after each successful prod build; the next PR's `pr-ephemeral` downloads it.

---

## Ingestion cadence

**Does ingestion run in every env?**
Different cadences per env (real-world pattern):
- **prod**: continuous, every 5 min, via Cloud Scheduler.
- **staging**: scheduler exists but **paused**. Operators trigger ad-hoc:
  `resume → run → pause`.
- **dev**: no deployed function. Developers run `python ingestion/main.py` locally.

**Why not run prod cadence in staging too?**
For cost + signal. Staging is a *validation* environment, not a continuous mirror of prod.
Running it on demand lets us validate the deploy path without burning quota/API calls.

---

## Cost

**Can I really do this free on GCP?**
Yes. The 5-min prod ingestion + 6-hourly dbt cron + all 4 projects fit inside the
**Always Free tier** — never expires.

**Does having 4 projects cost more?**
No. **GCP projects themselves are free** (no per-project fee), and the Always Free tier is
**per billing account**, shared across all projects. Our total usage is tiny.

**Do I need the $300 free-trial credit?**
No. The credit is just a buffer for anything *beyond* free, which we deliberately avoid.

**What does running 24/7 for a year cost?**
~**$0–$0.50/year** (Level-1 measurement; Level 3 is the same). The only line item that can
register is GCS write operations; everything else stays Always Free.

**What would actually cost real money?**
Cloud Composer (managed Airflow, ~$300+/mo), Dataflow, or large clusters — all of which we
**never enable**. The 4 per-project budget alerts (~$5 each) catch anything unexpected.

---

## Orchestration

**What is Cloud Scheduler vs GitHub Actions vs Airflow?**

| Tool | What it is | Runs where | Multi-step pipeline? |
|---|---|---|---|
| Cloud Scheduler | a cron **timer** | cloud, 24/7, free | ❌ fires one trigger |
| GitHub Actions cron | a scheduled **runner** | cloud, 24/7, free | ⚠️ a script of steps |
| Airflow / Dagster | an **orchestrator** | local (dev) or managed ($$$) | ✅ a graph: deps, retries, UI |

A timer rings a bell; a runner runs a list; an orchestrator runs a *graph* with retries,
backfills, and observability.

**Is local Airflow useless if it only runs on my laptop?**
For *running* a real 24/7 pipeline — yes, local Airflow is dev/learning-only. For *learning
the orchestrator* (DAGs, retries, the UI) — useful. Production Airflow means Cloud Composer
(~$300+/mo), which we avoid; for free 24/7 we use Cloud Scheduler (ingest) + GitHub Actions
cron (transform).

**Is GitHub Actions free on this repo?**
Yes, and **unlimited** — we made the repo public (Level 3 PR B). Public repos get unlimited
Action minutes and free Environment protection rules (required reviewers, wait timers).

---

## CI authentication / WIF

**What is Workload Identity Federation?**
GitHub Actions presents an OIDC token to GCP; GCP exchanges it for a short-lived OAuth
credential and lets the workflow act as a chosen service account (no long-lived JSON key
involved). The trust relationship is configured via a "pool + provider" in GCP's IAM,
filtered to *this specific repo*.

**Why is WIF better than service-account JSON keys?**
- Short-lived (≤1 hour) tokens — limits blast radius if a workflow is compromised.
- No keys to rotate, leak, or store.
- Tied to the repo via attribute conditions (using GitHub's immutable `repository_id`).

**What configures WIF in this repo?**
- The **pool + provider** in `crypto-pipeline-infra-260528` (created by `terraform/modules/wif/`).
- Per-env `dbt-ci@<project>` SAs each have `roles/iam.workloadIdentityUser` bound to the
  WIF pool's principalSet for this repo.
- The workflow uses `google-github-actions/auth@v2` with the provider name and the SA email.

---

## GitHub Environments

**What's `environment: production` doing in the workflow?**
Two things: (1) scopes which secrets the job can read (only this Env's secrets); (2)
applies the Environment's protection rules — for `production`, that's the **required-reviewer**
rule. The job pauses until I approve.

**Why is the required-reviewer feature available on this repo?**
Because the repo is **public**. On GitHub Free, required reviewers + wait timers are *only*
available for public repos (Pro/Team/Enterprise are needed for private repos). We made the
repo public in PR B; one of the side-benefits is this.

---

## Where to go deeper

- **Mental model from zero** → `start-here-mental-model.md`
- **A real recorded trace** (one change dev→staging→prod) → `walkthrough-one-change.md`
- **Why it all works** → `environments-and-cicd.md`
- **How to do tasks** → `howto-playbook.md`
- **Practical Level-3 setup + use** → `setup/environments.md`
- **The whole live architecture** → `../README.md`
- **Dated journey log** → `../LEARNING.md`
