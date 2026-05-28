# 09 — Scheduled dbt (every-6h prod refresh)

The other orchestration piece besides ingestion: a **GitHub Actions cron** that runs
`dbt build --target prod` on a schedule, gated by the same required-reviewer rule that
gates merges to prod.

## What you'll have when done
- `.github/workflows/scheduled-dbt.yml` is **enabled** (already committed; nothing to
  install — but worth verifying it's recognized and not auto-disabled).
- Cron schedule: `0 */6 * * *` — every 6 hours.
- Auth via **WIF** (same provider as the dbt CI workflow), impersonating
  `dbt-ci@<prod-project>`.
- The job uses `environment: production`, so every scheduled run **pauses for your
  approval** in the Actions UI before touching prod.

## Why this exists
- **Ingestion** is continuous (every 5 min) via Cloud Scheduler in the prod project.
- **Transform** (dbt) needs to run periodically to materialize fresh analytics — but only
  on prod data. CI runs it on merge; the cron runs it between merges so analytics don't
  go stale.

## Fast path (nothing to install)
The workflow is in the repo. Verify it's listed:
```bash
gh workflow list
# expected: "scheduled dbt (prod refresh)   active   …"
```

If it shows as **disabled** (GitHub auto-disables scheduled workflows after 60 days of
repo inactivity):
```bash
gh workflow enable "scheduled dbt (prod refresh)"
```

## Dispatch on demand (no need to wait for the next cron)
```bash
gh workflow run "scheduled dbt (prod refresh)"
# job pauses for your required-reviewer approval, like a normal prod deploy
```

## Approve
Same as the dbt-ci prod job — UI: Actions → run → Review deployments → Approve.
Or CLI:
```bash
RUN=$(gh run list --workflow="scheduled dbt (prod refresh)" --limit=1 --json databaseId --jq '.[0].databaseId')
PROD_ENV_ID=$(gh api repos/edwinrdrr/crypto-pipeline/environments/production --jq .id)
gh api -X POST "repos/edwinrdrr/crypto-pipeline/actions/runs/$RUN/pending_deployments" \
  -F "environment_ids[]=$PROD_ENV_ID" -f state=approved -f comment="scheduled refresh"
```

## Pause / unpause
There's no "scheduler off" toggle for a workflow file. Options:
- **Disable the workflow** (recommended for planned outages):
  ```bash
  gh workflow disable "scheduled dbt (prod refresh)"
  gh workflow enable  "scheduled dbt (prod refresh)"      # to resume
  ```
- **Comment out the `schedule:` block** in `.github/workflows/scheduled-dbt.yml` and push
  (permanent change; goes through PR review).

## Adjust the cadence
Edit the cron in `scheduled-dbt.yml`:
```yaml
on:
  schedule:
    - cron: "0 */6 * * *"      # every 6h  (default)
    # "0 0 * * *"              # daily at midnight UTC
    # "0 */2 * * *"            # every 2h
```
> Public repo → unlimited Action minutes. Each run is ~1–2 min; hourly would be cheap and
> fine here. The 6h cadence is just "fresh enough" for crypto analytics.

## Verify
```bash
# Most recent scheduled run
gh run list --workflow="scheduled dbt (prod refresh)" --limit=1
```
The latest run should show `success` (after you approved) or `waiting` (queued for approval).

After a successful run:
```bash
# Confirm the prod manifest was republished (Slim CI baseline for next PR)
gcloud storage ls -l gs://crypto-pipeline-infra-260528-ci-state/dbt-state/manifest.json
```

→ continue to [`10-troubleshooting.md`](10-troubleshooting.md) for setup-time errors.
