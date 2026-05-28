# Worked example: tracing one change through dev → staging → prod (Level 3)

This is a **real, recorded run** (PR #28 — wiring CI to WIF) showing every step of the path
a change takes through the **4-project Level-3 architecture**. At every step, note **WHERE
it ran** (which computer) vs **WHICH project it touched** (dev / staging / prod / infra).
These are the two independent things people confuse — see `start-here-mental-model.md`.

The change in PR #28 was the workflow rewrite: `dbt-ci.yml` switched from SA-key auth to
WIF + GitHub Environments. We use it here because it's the first PR that exercised the new
machinery end-to-end.

---

## Step 1 — develop on your LAPTOP, run against the DEV project

```bash
git checkout -b refactor/pr-d-wif-and-env-aware-deploy   # branch — your sandbox
# … edit dbt/profiles.yml, dbt-ci.yml, deploy.sh …
set -a && source .env && set +a                          # GCP_PROJECT_DEV, DBT_TARGET=dev
( cd dbt && dbt build --target dev )                     # writes to dev project
```
Real output (local seed run):
```
Landed 4 rows -> gs://crypto-pipeline-dev-260528-crypto-raw/raw/coingecko/dt=2026-05-28/...
Loaded into crypto-pipeline-dev-260528.crypto_raw.prices
ingested 4 rows
```
- **WHERE it ran:** your **laptop** (the `dbt`/`python` process on your machine).
- **WHICH project:** `crypto-pipeline-dev-260528` — its bucket + its `crypto_raw` dataset.
- 👉 The laptop did the work but wrote to a *cloud* project. Local ≠ an environment.

---

## Step 2 — push the branch + open a PR → CI tests in the DEV project via WIF

```bash
git push -u origin refactor/pr-d-wif-and-env-aware-deploy
gh pr create --fill                                       # → opened PR #28
```
Pushing uploaded the code to GitHub; opening the PR triggered the `pr-ephemeral` job.

The job's authentication is **keyless** (no SA key file anywhere) — `google-github-actions/auth@v2`
exchanges GitHub's OIDC token for short-lived ADC, impersonating the dev project's `dbt-ci` SA:

```yaml
- uses: google-github-actions/auth@v2
  with:
    workload_identity_provider: projects/101866768306/.../providers/github
    service_account: dbt-ci@${{ secrets.GCP_PROJECT_DEV }}.iam.gserviceaccount.com
```

Real output (the build):
```
pr-ephemeral   pass   ~60s
DBT_TARGET: dev
DBT_DATASET: dbt_ci_pr_28
Slim CI — state:modified.body+ (defer unchanged to prod)
1 of N OK created sql view model dbt_ci_pr_28.stg_crypto__prices
…
dropped crypto-pipeline-dev-260528.dbt_ci_pr_28
```

- **WHERE it ran:** **GitHub's** machines (a CI runner), not your laptop.
- **WHICH project:** `crypto-pipeline-dev-260528` — into a *temporary* schema `dbt_ci_pr_28`
  scoped just to this PR, **dropped** when the run finished.
- 👉 A pushed branch is tested in **dev**, in isolation. Nothing real was touched.
  **Push is not "for prod."**

---

## Step 3a — merge to `main` → STAGING job (WIF → staging project)

```bash
gh pr merge 28 --squash --delete-branch
```
Merging to `main` triggered the deploy. The `staging` job authenticates via WIF impersonating
`dbt-ci@crypto-pipeline-stg-260528`:

```
staging   success
dbt build --target staging
OK created sql incremental model crypto_analytics.fct_crypto_prices
…
```
- **WHERE it ran:** **GitHub's** machines.
- **WHICH project:** `crypto-pipeline-stg-260528` — staging's `crypto_analytics`.

---

## Step 3b — PROD job pauses for required-reviewer approval

The `prod` job (`needs: staging`) **doesn't run automatically**. It uses `environment: production`,
which has a required-reviewer rule (only available because the repo is public, free GitHub plan):

```
prod   waiting (paused — environment 'production' requires approval)
```

- **WHERE it ran:** nowhere yet — paused on GitHub.
- **WHICH project:** none touched yet — gate hasn't opened.

This is the **prod gate**. Production data never changes until I (the required reviewer) say so.

---

## Step 3c — Approve → PROD job (WIF → prod project) → publish manifest

I approve via either the Actions UI or the gh CLI:
```bash
gh api -X POST repos/edwinrdrr/crypto-pipeline/actions/runs/$RUN/pending_deployments \
  -F "environment_ids[]=$PROD_ENV_ID" -f state=approved -f comment="ship it"
```

```
prod   success (after approval, via WIF → dbt-ci@crypto-pipeline-prod-260528)
dbt build --target prod
OK created sql incremental model crypto_analytics.fct_crypto_prices
…
published prod manifest to gs://crypto-pipeline-infra-260528-ci-state/dbt-state/manifest.json
```

- **WHERE it ran:** **GitHub's** machines.
- **WHICH project:** `crypto-pipeline-prod-260528` — prod's `crypto_analytics`. Plus the
  manifest write to `crypto-pipeline-infra-260528`'s `ci-state` bucket (shared infra).
- 👉 Prod was reached *only* via the merge + my approval. The manifest published becomes
  the **Slim CI baseline** the next PR's `pr-ephemeral` job downloads.

---

## The whole trace in one table

| Step | You did | WHERE it ran | WHICH project (cloud) |
|------|---------|-------------|----------------------|
| 1 | `dbt build --target dev` | **laptop** | `crypto-pipeline-dev-260528` |
| 2 | push branch + open PR | **GitHub CI** | `crypto-pipeline-dev-260528` (temp schema, dropped) |
| 3a | merge → staging job | **GitHub CI** | `crypto-pipeline-stg-260528` |
| 3b | required-reviewer wait | (paused on GitHub) | — |
| 3c | approve + prod job + manifest | **GitHub CI** | `crypto-pipeline-prod-260528` + manifest in infra |

Read the middle column top-to-bottom: laptop, then GitHub, GitHub, GitHub.
Read the right column: **every environment is a GCP project** — none is "on your laptop".

---

## What this proves (the corrections)

1. **`git push` is not "for prod."** A pushed *branch* → tested in **dev** (Step 2). Only a
   *merge to main* + *my approval* → **prod** (Step 3c).
2. **dev / staging / prod are GCP PROJECTS, and CI/CD is what moves code through them.**
   They are not "local," and they are the opposite of "unrelated to CI/CD" — they're the destinations.
3. **"Local" is just your laptop** — the computer where you write code and run it against the
   **dev project** (Step 1). It is not a fourth environment.
4. **CI authenticates without keys** — Workload Identity Federation gives a short-lived OIDC
   token per run; no `GCP_SA_KEY` JSON exists in the repo or anywhere.
5. **Prod has a manual gate** — the `production` environment's required-reviewer rule pauses
   the prod job until I approve. That's the prod safety net.

---

## The flow is the same for *any* change

The change above was a workflow rewrite. The path doesn't depend on *what* you changed:

- **PR #28** (this trace) — workflow rewrite touching `.github/workflows/dbt-ci.yml`.
- **PR #21** — a whole **new model** (`mart_latest_prices`) added from scratch (back when
  the project was Level-1; the path was the same conceptually).

Both took the **identical** route: laptop→dev project → PR (Slim CI, ephemeral schema) →
merge → staging project → required-reviewer wait → prod project. Only the *content* differs;
the *pipeline* is the same.

> **To author a new model** (the *what*, not the *flow*), see `howto-playbook.md` recipe 3.

Next: `howto-playbook.md` to *do* these tasks yourself.
