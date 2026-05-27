# Start here — the mental model (read this first)

If "dev / staging / prod" and "git push / CI/CD" feel tangled, this page untangles them
from zero, using your real pipeline. Read this *before* the concept guide.

---

## The one idea everything hangs on: two separate questions

When something runs in this project, ask **two different questions** — they're independent:

1. **WHERE does the code run?** (which *computer*) → your **laptop**, a **CI runner**, or a **scheduler**.
2. **WHICH environment does it touch?** (which *database*) → **dev**, **staging**, or **prod**.

Most confusion comes from squashing these into one. They are not the same. Example: you can
run dbt **on your laptop** that writes to the **dev** database in the cloud. The *computer* is
your laptop; the *environment* is dev. Different axes.

---

## Environments are cloud databases — NOT "your laptop"

`dev`, `staging`, and `prod` are **three separate databases in the cloud** (BigQuery datasets):

```
dev      = crypto_analytics_dev        (in the cloud)
staging  = crypto_analytics_staging    (in the cloud)
prod     = crypto_analytics            (in the cloud)
```

They all live in Google Cloud. None of them is "on your laptop." When you run dbt locally,
your laptop is just the *computer doing the work* — it reaches over the internet and writes
into the **dev** database. So:

> **"dev" is a database in the cloud. Your laptop *targets* dev — it doesn't *contain* it.**

"Local" is not a fourth environment. **Local = your laptop**, a place where you write code and
(usually) run it against the dev database.

---

## What `git push` actually does (and doesn't)

`git push` **uploads your code to GitHub. That's it.** By itself it deploys to *nothing* and
touches *no* database. What happens *next* depends entirely on **where** you pushed:

| What you do | What runs automatically (CI/CD) | Which environment it touches |
|---|---|---|
| push a **branch** + open a Pull Request | tests your change | **dev** (a temporary per-PR database) |
| **merge** the PR into `main` | builds + tests | **staging**, then **prod** |

So — answering the exact question: **pushing is not "for prod."**
- Pushing a *feature branch* → exercises **dev**.
- *Merging to main* → promotes to **staging → prod**.

Same push button; the destination depends on the branch and whether it's merged.

---

## The conveyor belt: how code moves through environments

```
  YOU (laptop)              GitHub (CI/CD does this automatically)
  ───────────              ──────────────────────────────────────────
  write code                                  
  run vs dev   ──push branch──►  Pull Request ──►  test on DEV (temp db)
                                       │
                                  (review, merge)
                                       ▼
                                 merge to main ──►  build STAGING ──►  build PROD
                                                    (if staging passed) ┘
```

- **Branch = your sandbox.** Break things freely; nothing real is affected.
- **`main` = the source of truth.** What's on `main` is what goes to prod.
- **CI/CD = the conveyor belt + quality gates** that carry code branch → dev → staging → prod.
- A **red (failing) check blocks the merge** — that's how bad code is stopped before prod.

So `dev/staging/prod` are **not** "only local and unrelated to CI/CD." They are exactly the
stations the CI/CD conveyor belt moves your code through.

---

## A real trace from this repo (PR #8)

You added a `price_direction` column. Here's where each step *ran* and what it *touched*:

| Step | WHERE it ran | WHICH environment (database) |
|------|-------------|------------------------------|
| `dbt build --target dev` while developing | your **laptop** | `crypto_analytics_dev` (cloud) |
| opened the PR → CI checked it | **GitHub CI** | `dbt_ci_pr_8` (cloud, temporary dev db, dropped after) |
| merged to `main` → staging job | **GitHub CI** | `crypto_analytics_staging` (cloud) |
| then the prod job (staging passed) | **GitHub CI** | `crypto_analytics` (cloud) |

Look at row 1: it ran on your **laptop** but wrote to a **cloud** database. Rows 2–4 ran on
**GitHub's** computers. **Every environment is in the cloud** — your laptop was just one of the
machines that ran dbt against them.

---

## The differences between dev / staging / prod

They're three databases that differ in **who touches them, what data they hold, and what
breaks if you mess up:**

| | **dev** | **staging** | **prod** |
|---|---|---|---|
| Who/what runs against it | you (laptop) + PR checks | CI, on merge | CI, after staging passes |
| Data inside | small / throwaway | prod-like | the real data |
| You touch it directly? | yes (while developing) | no — only via CI | no — only via CI |
| If it breaks | nobody cares | caught *before* prod | dashboards/users break |
| Purpose | experiment freely | final rehearsal | the real thing |

The key promotion rule: **the same code flows dev → staging → prod; each environment rebuilds
its own tables.** You change *config* (which target/dataset), never the pipeline code, to move
between them. That's "promotion via config, not code."

---

## Common misconceptions (the exact ones you asked)

**"Is pushing only for prod?"**
No. Push uploads code to GitHub. A pushed *branch* (via a PR) is tested on **dev**. Only when
you **merge to `main`** does it go to **staging → prod**.

**"Are dev/staging/prod only on local, unrelated to CI/CD?"**
The opposite. They're all **cloud databases**, and **CI/CD is the thing that moves your code
through them**. "Local" (your laptop) is separate — it's just where you write code and run it
against dev while developing.

**"So what's the difference between them?"**
Which data they hold, who's allowed to touch them, and the cost of breaking them — see the
table above. dev = safe scratchpad; staging = dress rehearsal; prod = the real, protected one.

**"Then what's local for?"**
Writing code and testing fast against dev *before* you push — so CI catches fewer problems and
you don't waste round-trips. (See `docs/howto-playbook.md` recipe 2.)

**"Don't you just put `environment=dev` in a `.env` file to do dev?"**
Almost — good instinct, with three refinements:
1. An env var **does** select the environment — in this project it's literally `DBT_TARGET=dev`
   (+ `DBT_DATASET`, `RAW_DATASET`). So the "a variable picks the env" idea is correct.
2. But the var doesn't *create* dev — it **points your run at** the dev database, which already
   exists in the cloud. ("Which door to open," not "build a room.")
3. A `.env` is a **local-laptop convenience** for setting those vars. **CI/cloud don't read a
   `.env`** — they inject the *same* vars via the workflow `env:` (per branch: PR→dev, merge→
   staging→prod) and `--set-env-vars`. And **secrets never go in a committed `.env`** — those
   live in GitHub Secrets / a secret manager.

So the best practice is: **config from the environment, secrets from a secret manager** — with a
gitignored **`.env` locally** (see `.env.example`) and **platform injection in CI/cloud**. Use both,
each in its place. Copy `.env.example` → `.env`, then `set -a && source .env && set +a`.

---

## Say it back in one breath

> There are **three cloud databases** (dev, staging, prod). **Your laptop** is where you write
> code and run it against **dev**. **`git push` + CI/CD** is the conveyor belt: a **branch/PR**
> gets tested on **dev**, and **merging to `main`** promotes the code to **staging**, then
> **prod**. Local isn't an environment; pushing isn't "for prod"; and the environments are the
> stations CI/CD moves your code through.

Next: `docs/environments-and-cicd.md` (deeper concepts) → `docs/howto-playbook.md` (how to do tasks).
