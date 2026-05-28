# Start here — the mental model (read this first)

If "dev / staging / prod" and "git push / CI/CD" feel tangled, this page untangles them
from zero, using your real Level-3 pipeline. Read this *before* the concept guide.

---

## The one idea everything hangs on: two separate questions

When something runs in this project, ask **two different questions** — they're independent:

1. **WHERE does the code run?** (which *computer*) → your **laptop**, a **CI runner**, or a **scheduler**.
2. **WHICH environment does it touch?** (which *project/database*) → **dev**, **staging**, or **prod**.

Most confusion comes from squashing these into one. They are not the same. Example: you can
run dbt **on your laptop** that writes to the dev **GCP project**'s BigQuery. The *computer*
is your laptop; the *environment* is dev. Different axes.

---

## Environments are entire cloud PROJECTS — NOT "your laptop"

In this Level-3 setup, `dev`, `staging`, and `prod` are **three separate GCP projects** —
each with its own bucket, datasets, service accounts, and (where applicable) Cloud Function:

```
dev      = crypto-pipeline-dev-260528         (whole GCP project — bucket + 2 datasets + SAs)
staging  = crypto-pipeline-stg-260528         (whole GCP project — same shape + paused function)
prod     = crypto-pipeline-prod-260528        (whole GCP project — same shape + 5-min function)

infra    = crypto-pipeline-infra-260528       (shared infra: tfstate, ci-state, WIF pool, tf-runner)
```

All projects live in Google Cloud. None of them is "on your laptop." When you run dbt
locally, your laptop is just the *computer doing the work* — it reaches over the internet
into the **dev project** and writes there. So:

> **A project IS an environment.** Your laptop *targets* dev (writes into the dev project);
> it doesn't *contain* dev.

"Local" is not a fourth environment. **Local = your laptop**, a place where you write code
and (usually) run it against the dev project.

---

## What `git push` actually does (and doesn't)

`git push` **uploads your code to GitHub. That's it.** By itself it deploys to *nothing* and
touches *no* GCP project. What happens *next* depends entirely on **where** you pushed:

| What you do | What runs automatically (CI/CD) | Which environment it touches |
|---|---|---|
| push a **branch** + open a Pull Request | tests your change | **dev project** (ephemeral schema `dbt_ci_pr_<n>`) |
| **merge** the PR into `main` | builds + tests | **staging project**, then **prod project** *(after my manual approval)* |

So pushing is **not "for prod."**
- Pushing a *feature branch* → exercises the **dev project**.
- *Merging to main* → **staging project**, then waits for required-reviewer approval, then **prod project**.

---

## The conveyor belt: how code moves through environments

```
  YOU (laptop)            GitHub (CI/CD does this automatically, via WIF)
  ───────────             ──────────────────────────────────────────
  write code                                  
  run vs dev   ──push branch──►  Pull Request ──►  test in DEV project (temp schema, dropped after)
                                       │
                                  (review, merge)
                                       ▼
                                 merge to main ──►  build STAGING project
                                                              │
                                              (you click 'Approve' — required-reviewer)
                                                              ▼
                                                  build PROD project
                                                              │
                                                              ▼
                                              publish manifest.json to ci-state bucket
                                              (becomes next PR's Slim CI baseline)
```

- **Branch = your sandbox.** Break things freely; nothing real is affected.
- **`main` = the source of truth.** What's on `main` is what goes to prod.
- **CI/CD = the conveyor belt + quality gates** that carry code branch → dev → staging → prod.
- A **red (failing) check blocks the merge** — that's how bad code is stopped before prod.
- A **paused job on `production`** blocks the deploy — that's how *you* gate prod.

So `dev/staging/prod` are **not** "only local and unrelated to CI/CD." They are exactly the
projects the CI/CD conveyor belt moves your code through.

---

## A real trace from this repo (PR #28's merge)

PR #28 wired CI to WIF. Here's where each step *ran* and what it *touched*:

| Step | WHERE it ran | WHICH project |
|------|-------------|--------------|
| `dbt build --target dev` while developing | your **laptop** | `crypto-pipeline-dev-260528` |
| opened the PR → `pr-ephemeral` (WIF auth) | **GitHub CI** | `crypto-pipeline-dev-260528` (temp schema `dbt_ci_pr_28`, dropped) |
| merged to `main` → `staging` job (WIF) | **GitHub CI** | `crypto-pipeline-stg-260528` |
| `prod` job paused for required-reviewer | **paused** | — (waiting on me) |
| approved → `prod` job (WIF) | **GitHub CI** | `crypto-pipeline-prod-260528` |
| `prod` job uploads manifest | **GitHub CI** | infra's `ci-state` bucket |

Look at row 1: it ran on your **laptop** but wrote to a **cloud project**. Rows 2–6 ran on
**GitHub's** computers. **Every environment is a GCP project** — your laptop is just one of
the machines that runs code against them.

---

## The differences between dev / staging / prod

| | **dev** | **staging** | **prod** |
|---|---|---|---|
| GCP project | `crypto-pipeline-dev-260528` | `crypto-pipeline-stg-260528` | `crypto-pipeline-prod-260528` |
| Who/what runs against it | you (laptop) + PR `pr-ephemeral` job | CI `staging` job on merge | CI `prod` job *after* your approval |
| Ingestion cadence | manual local (`python ingestion/main.py`) | paused scheduler (resume → run → pause) | scheduler every 5 min (live) |
| Data inside | small / throwaway | small (operator triggers) | continuously growing |
| You touch it directly? | yes (while developing) | rarely — usually via CI | only to inspect / debug |
| If it breaks | nobody cares | caught *before* prod | dashboards/users break |
| Cost contribution | ~$0 | ~$0 | most of the project's cost (still ~$0) |

The key promotion rule: **the same code flows dev → staging → prod; each environment
rebuilds its own tables in its own project.** You change *config* (`DBT_TARGET` / which
env's secrets the CI job uses), never the pipeline code, to move between them.

---

## Common misconceptions (the exact ones we worked through)

**"Is pushing only for prod?"**
No. Push uploads code to GitHub. A pushed *branch* (via a PR) is tested in the **dev project**.
Only when you **merge to `main`** does it touch **staging**, then **prod** (after your approval).

**"Are dev/staging/prod only on local, unrelated to CI/CD?"**
The opposite. They're all **GCP projects**, and **CI/CD is the thing that moves your code
through them**. "Local" (your laptop) is separate — it's just where you write code and run it
against the dev project while developing.

**"So what's the difference between them?"**
Different GCP projects, different IAM, different schedulers, different cost of breaking — see
the table above. dev = safe scratchpad; staging = dress rehearsal; prod = the real, gated one.

**"Then what's local for?"**
Writing code and testing fast against dev *before* you push — so CI catches fewer problems and
you don't waste round-trips. (See `howto-playbook.md` recipe 2.)

**"Don't you just put `environment=dev` in a `.env` file to do dev?"**
Almost — good instinct, with refinements:
1. An env var **does** select the environment — here it's `DBT_TARGET=dev` (+ `GCP_PROJECT_DEV`).
2. But the var doesn't *create* dev — it **points your run at** the dev project, which already
   exists in the cloud.
3. `.env` is a **local-laptop convenience**. **CI/cloud don't read a `.env`** — CI uses
   `google-github-actions/auth@v2` with a Workload Identity Federation token to assume each
   env's per-Environment secrets and per-env `dbt-ci@<project>` SA.
4. **Secrets never go in a `.env`** — there are no long-lived SA keys at all anymore (WIF
   replaced them).

**"From my laptop, which environment should I touch?"**
**dev only** — your `.env` defaults `DBT_TARGET=dev` so this is the safe default. Writing to
staging/prod is **CI/CD's job**; doing it by hand from a laptop skips the PR/review/test gate
(that's how prod accidents happen). *Reading* prod (a query to verify, or Slim CI deferral)
is fine — *writing* prod from local is not.

---

> 💬 **More answers:** every question from building this project is collected in
> **`faq.md`** (environments, push/CI-CD, config/`.env`, cost, architecture, orchestration).
