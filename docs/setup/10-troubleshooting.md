# 10 — Troubleshooting (common setup errors and exact fixes)

Errors we actually hit while building/running this project, each with the exact fix.
If you're mid-setup and something failed, scan here first — odds are it's listed.

---

## Billing / quotas

### `FAILED_PRECONDITION: Cloud billing quota exceeded`
**When:** `gcloud billing projects link` (doc 02) or `bootstrap.sh` Phase 1.
**Why:** Your billing account's default quota is **5 linked projects** for newer/free-trial accounts.
**Fix:** Delete unused billing-linked projects to free slots:
```bash
gcloud billing projects list --billing-account=YOUR-BILLING-ID
gcloud projects delete <abandoned-project-id> --quiet
```
Or unlink billing (keeps the project alive but stops it accruing charges):
```bash
gcloud billing projects unlink <project-id>
```
Deleted projects enter `DELETE_REQUESTED` and are recoverable for 30 days
(`gcloud projects undelete`).

### Re-linking a project already linked = quota error
**When:** Re-running `bootstrap.sh` after a partial-failure run.
**Fix:** Already in the script — it skips `gcloud billing projects link` when the project's
`billingEnabled` is already `True`. If you're doing it manually, **check before linking**:
```bash
if ! gcloud billing projects describe $P --format='value(billingEnabled)' | grep -q True; then
  gcloud billing projects link $P --billing-account=$BILLING_ID
fi
```

### `INVALID_ARGUMENT` on `gcloud billing budgets create`
**Why:** Currency mismatch. If your billing account is IDR and you pass `--budget-amount=5USD`,
the API rejects it.
**Fix:** Omit the currency suffix and use the native amount:
```bash
--budget-amount=80000     # ≈ $5 in IDR
--budget-amount=5         # USD account: just the number (no suffix needed)
```

---

## ADC / authentication

### `does not have permission to access … Project … has been deleted`
**When:** After deleting a project, subsequent `gcloud` calls fail with this error and an
old project ID in the message.
**Why:** Application Default Credentials cache a *quota project* — if you deleted that, all
API calls using ADC fail.
**Fix:**
```bash
gcloud config set project crypto-pipeline-infra-260528
gcloud auth application-default set-quota-project crypto-pipeline-infra-260528
```
This is also auto-handled by `bootstrap.sh` (it resets these after Phase 1).

### `gcloud auth application-default login` opens but doesn't save
**Cause:** Browser popup blocked, or you closed before the redirect.
**Fix:** Run `gcloud auth application-default login --no-launch-browser` to get a URL+code
flow you can copy to a different browser.

---

## WIF / GitHub Actions auth

### Workflow auth fails with "unauthorized_client" / "invalid_grant"
**Common causes & fixes:**
1. **`workload_identity_provider` is wrong.** It must be the *full* resource path:
   `projects/<NUMBER>/locations/global/workloadIdentityPools/github-actions/providers/github`.
   Get it from `terraform output wif_provider_name` in `envs/infra/`.
2. **`service_account` SA doesn't have `roles/iam.workloadIdentityUser` for this repo.**
   Terraform creates these bindings; if you applied infra before the env SAs existed, the
   binding wasn't created. Re-apply `envs/infra/`.
3. **`attribute_condition` rejects your repo.** The provider has
   `assertion.repository_id == "1251445803"` — if your fork's `repository_id` is different,
   update `envs/infra/terraform.tfvars` with your `gh api repos/<o>/<n> --jq .id` and
   re-apply.
4. **Missing `id-token: write` permission** in the workflow file. Top-level
   `permissions:` block must include it.

### `gh repo view --json id` returns a weird string like `R_kgDOSpeMKw`
**Why:** That's GitHub's **GraphQL node id**, not the numeric `repository_id` WIF needs.
**Fix:** Use the REST API instead:
```bash
gh api repos/edwinrdrr/crypto-pipeline --jq .id     # numeric: 1251445803
```

---

## Terraform

### `Error acquiring the state lock` (403) in `terraform-ci.yml`
**Why:** The `tf-runner` SA is read-only (correct for plan-only CI), but `terraform plan`
tries to acquire a state lock by *writing* a lock file.
**Fix:** Pass `-lock=false` to plan. The workflow already does this; if you copy it elsewhere
or run `tf-runner`-impersonating plans locally, add the flag.

### `terraform init` says "Backend configuration changed"
**Why:** You ran `init` once with a local backend (or a different bucket), then changed
`backend.tf`.
**Fix:** `terraform init -reconfigure`. Already in `bootstrap.sh`'s apply loop.

### `tfstate bucket … already exists` on first apply of `envs/infra`
**Why:** `bootstrap.sh` Phase 4 creates the bucket out-of-band (chicken-and-egg), then
Phase 8 `terraform import`s it.
**Fix:** Already handled by the conditional import in `bootstrap.sh`. If applying manually:
```bash
cd terraform/envs/infra
terraform import google_storage_bucket.tfstate crypto-pipeline-infra-260528-tfstate
terraform apply
```

---

## dbt

### `Not found: Table … crypto_raw.prices was not found in location US`
**Why:** dbt's `source('crypto_raw', 'prices')` resolves to a table that doesn't exist yet.
**Fix:** Seed the env's raw table:
```bash
GCP_PROJECT=$GCP_PROJECT_<ENV> RAW_BUCKET=$GCP_PROJECT_<ENV>-crypto-raw \
   .venv/bin/python ingestion/main.py
```
Doc 07 seeds all three; this happens when CI runs before doc 07.

### `dbt deps` says "Unable to resolve … dbt-utils"
**Why:** `dbt-utils` is a **dbt package** (installed by `dbt deps` from `packages.yml`),
NOT a pip package. If a workflow does `pip install dbt-utils`, it fails.
**Fix:** Remove `dbt-utils` from pip lines. Only `dbt-bigquery` is pip-installed.

### dbt build "succeeds" but the new column isn't in the prod table
**Why:** `fct_crypto_prices` is incremental, and dbt's default `on_schema_change` is
`ignore` — new columns are silently dropped on incremental MERGE runs.
**Fix:** The model already has `on_schema_change='append_new_columns'`. If you copy the
pattern elsewhere, include this config.

### `Compilation Error … invalid syntax` on a config block comment
**Why:** SQL `--` comments inside `{{ config(...) }}` aren't recognized (it's Jinja, not
SQL). Or you put `#}` characters inside a `{# … #}` Jinja comment.
**Fix:** Use Jinja-style `{# … #}` for comments around config blocks; **don't put the
characters `#}` inside** (closes the comment early; SQL leaks).

---

## ingestion / deploy.sh

### `unexpected EOF while looking for matching ''` running `deploy.sh`
**Why:** An apostrophe inside a `${VAR:?error message}` is parsed by bash as opening a
single quote — bash then looks for the closing `'` to EOF.
**Fix:** Avoid apostrophes in those error messages. Already fixed in `deploy.sh`; mention
this if you write new bash scripts that use parameter expansion.

### `FAILED_PRECONDITION: Job.state must be ENABLED for RunJob`
**Why:** `gcloud scheduler jobs run` requires the job be ENABLED. Staging's scheduler is
PAUSED by design.
**Fix:** Resume → run → pause:
```bash
gcloud scheduler jobs resume crypto-ingest-staging --location=us-central1 --project=$GCP_PROJECT_STAGING
gcloud scheduler jobs run    crypto-ingest-staging --location=us-central1 --project=$GCP_PROJECT_STAGING
gcloud scheduler jobs pause  crypto-ingest-staging --location=us-central1 --project=$GCP_PROJECT_STAGING
```

### Function deploys but writes no rows; no error in logs
**Why:** The function ran as the default compute SA which has no permissions on a new
project (a real silent failure we hit at Level 1).
**Fix:** `deploy.sh` now uses `--run-service-account=crypto-ingest-fn@<project>` (created
by Terraform with the right roles). Make sure you're using the current `deploy.sh`.

---

## GitHub repo + Environments

### `gh repo create` says "already exists"
**Fix:** Skip and just link the remote: `git remote add origin git@github.com:OWNER/REPO.git`,
then `git push -u origin main`.

### Going public errors with "branch protection violations"
**Why:** Some private-only enforcement is now violated under public rules.
**Fix:** Review the error; usually removes a setting you can re-enable after.

### Required reviewer rule rejected on private repo (`422` / "feature not available")
**Why:** GitHub Free doesn't support required-reviewer protection on **private** repos
(Pro/Team/Enterprise only).
**Fix:** Make the repo **public** (doc 04). After the visibility flip, retry doc 05's
production-environment PUT call.

### My-own-approval blocked / "you cannot approve your own deployment"
**Why:** `prevent_self_review: true` is set on the environment.
**Fix:** As the sole collaborator, set `prevent_self_review: false`:
```bash
USER_ID=$(gh api user --jq .id)
printf '{"wait_timer":0,"prevent_self_review":false,"reviewers":[{"type":"User","id":%s}]}' "$USER_ID" \
  | gh api -X PUT repos/edwinrdrr/crypto-pipeline/environments/production --input -
```

---

## Other gotchas worth knowing

- **Don't put `${PWD}` literals in `.env`** — they expand at *source* time, not at use
  time. If you `source .env` from one dir then `cd` elsewhere, values frozen at source
  time still point at the original directory. (We use `DBT_PROFILES_DIR=$PWD/dbt`, sourced
  from the repo root — works because we source from repo root.)
- **Scheduled workflows are auto-disabled after 60 days** of repo inactivity. Run
  `gh workflow enable "scheduled dbt (prod refresh)"` to re-enable.
- **`scripts/install-tools.sh` doesn't install `gh`.** It's OS-specific; install via your
  package manager. The script will tell you.

---

## Where to dig deeper
- `LEARNING.md` — the dated log; gotchas in context of the PR that hit them.
- `CLAUDE.md` — quick command reference.
- `docs/faq.md` — "everything we cleared up", consolidated Q&A.
