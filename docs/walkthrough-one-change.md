# Worked example: tracing one change through dev → staging → prod

This is a **real, recorded run** (PR #16) of a single trivial change — a one-line comment
added to `fct_crypto_prices`. It exists to make the mental model concrete: at every step,
note **WHERE it ran** (which computer) vs **WHICH environment it touched** (which cloud
database). These are the two independent things people confuse — see
`docs/start-here-mental-model.md`.

The change itself:
```diff
  -- so it stays well inside BigQuery's free 1 TB/month.
+ -- (walkthrough demo: this one-line comment is the "change" we trace dev -> staging -> prod)
```

---

## Step 1 — develop on your LAPTOP, run against DEV

```bash
git checkout -b feature/walkthrough-demo        # a sandbox branch, on your laptop
# ...edit the model...
dbt build --select fct_crypto_prices --target dev   # DBT_DATASET=crypto_analytics_dev
```
Real output:
```
1 of 5 OK created sql incremental model crypto_analytics_dev.fct_crypto_prices  MERGE ... 
Done. PASS=5 WARN=0 ERROR=0 SKIP=0 NO-OP=0 TOTAL=5
```
- **WHERE it ran:** your **laptop** (the `dbt` process on your machine).
- **WHICH environment:** `crypto_analytics_dev` — a database **in the cloud**.
- 👉 The laptop did the work but wrote to a *cloud* dataset. Local ≠ an environment.

---

## Step 2 — push the branch + open a PR → CI tests it in a THROWAWAY dev db

```bash
git push -u origin feature/walkthrough-demo
gh pr create            # -> opened PR #16
```
Pushing uploaded the code to GitHub; opening the PR triggered CI. Real output:
```
pr-ephemeral   pass   52s
DBT_DATASET: dbt_ci_pr_16
```
- **WHERE it ran:** **GitHub's** machines (a CI runner), not your laptop.
- **WHICH environment:** `dbt_ci_pr_16` — a *temporary* dev database created just for this PR
  (Slim CI built only the changed model), then **dropped** when the run finished.
- 👉 A pushed branch is tested on **dev**, in isolation. Nothing real was touched. **Push is not "for prod."**

---

## Step 3 — merge to `main` → CI promotes to STAGING, then PROD

```bash
gh pr merge 16 --squash --delete-branch
```
Merging to `main` triggered the deploy. Real output:
```
staging : success
prod    : success          (prod ran only AFTER staging passed — needs: staging)
pr-ephemeral : skipped      (it's a merge, not a PR)

OK created sql incremental model crypto_analytics_staging.fct_crypto_prices  MERGE ...
OK created sql incremental model crypto_analytics.fct_crypto_prices          MERGE ...
```
- **WHERE it ran:** **GitHub's** machines again (CI/CD).
- **WHICH environments:** first `crypto_analytics_staging`, then `crypto_analytics` (prod) —
  both **in the cloud**.
- 👉 Only **merging to `main`** sends code to **staging → prod**, and prod waits for staging
  to pass (the promotion gate).

---

## The whole trace in one table

| Step | You did | WHERE it ran | WHICH environment (cloud db) |
|------|---------|-------------|------------------------------|
| 1 | `dbt build --target dev` | **laptop** | `crypto_analytics_dev` |
| 2 | push branch + open PR | **GitHub CI** | `dbt_ci_pr_16` (temp, dropped) |
| 3a | merge → staging job | **GitHub CI** | `crypto_analytics_staging` |
| 3b | merge → prod job | **GitHub CI** | `crypto_analytics` |

Read the middle column top-to-bottom: laptop, then GitHub, GitHub, GitHub.
Read the right column: **every environment is a cloud database** — none is "on your laptop".

---

## What this proves (the three corrections)

1. **`git push` is not "for prod."** A pushed *branch* → tested on **dev** (Step 2). Only a
   *merge to main* → **staging → prod** (Step 3).
2. **dev / staging / prod are cloud databases, and CI/CD is what moves code through them.**
   They are not "local," and they are the opposite of "unrelated to CI/CD" — they're the stations.
3. **"Local" is just your laptop** — the computer where you write code and run it against **dev**
   (Step 1). It is not a fourth environment.

> The same code (one comment) flowed dev → staging → prod untouched; each environment rebuilt
> its own copy of the table. That's "promote the logic, not the data."

Next: `docs/howto-playbook.md` to *do* these tasks yourself.
