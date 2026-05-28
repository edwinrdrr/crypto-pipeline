# 08 — End-to-end verification

Prove the whole pipeline works: WIF auth, Slim CI in the dev project, required-reviewer
gate on prod, manifest publish, and the prod scheduler producing new snapshots.

## 1. Prod scheduler is producing data (~5–10 min)
```bash
# distinct snapshots should grow over time as the */5 cron fires
bq query --use_legacy_sql=false --project_id=$GCP_PROJECT_PROD --format=csv --quiet \
  "SELECT COUNT(DISTINCT ingested_at) FROM \`$GCP_PROJECT_PROD.crypto_raw.prices\`" \
  | tail -1
# wait 5 min; query again — the number should increase by 1
```

## 2. Open a test PR — Slim CI authenticates via WIF, builds in dev project
```bash
git checkout main && git pull
git checkout -b test/verify-e2e
# trivial change so CI selects something
echo "-- verify e2e $(date +%s)" >> dbt/models/marts/fct_crypto_prices.sql
git add -A && git commit -m "Verify end-to-end"
git push -u origin test/verify-e2e
gh pr create --fill
```

Watch CI:
```bash
PR=$(gh pr list --head test/verify-e2e --json number --jq '.[0].number')
gh pr checks $PR
# wait for pass — should be ~60 seconds
```

Confirm the ephemeral schema was created in **the dev project** and dropped:
```bash
RUN=$(gh pr checks $PR 2>&1 | head -1 | grep -oE 'runs/[0-9]+' | head -1 | cut -d/ -f2)
gh run view $RUN --log 2>&1 | grep -E "DBT_DATASET: dbt_ci_pr|dropped" | head -2
```

## 3. Merge — staging job runs, prod job pauses for approval
```bash
gh pr merge $PR --squash --delete-branch
# wait, then check the merge run
RUN=$(gh run list --branch main --limit 1 --json databaseId --jq '.[0].databaseId')
sleep 60
gh run view $RUN --json status,jobs \
  --jq '.status + " | " + (.jobs | map(.name + ":" + (.conclusion // .status)) | join(", "))'
# Expected eventually: "waiting | staging:success, pr-ephemeral:skipped, prod:"
```

## 4. Approve the prod deploy
```bash
PROD_ENV_ID=$(gh api repos/edwinrdrr/crypto-pipeline/environments/production --jq .id)
gh api -X POST "repos/edwinrdrr/crypto-pipeline/actions/runs/$RUN/pending_deployments" \
  -F "environment_ids[]=$PROD_ENV_ID" -f state=approved -f comment="verify e2e"
```
Or via the Actions UI → run → Review deployments → Approve.

## 5. Confirm prod ran + manifest republished
```bash
gh run view $RUN --json status,jobs \
  --jq '.status + " | " + (.jobs | map(.name + ":" + (.conclusion // .status)) | join(", "))'
# → "completed | staging:success, pr-ephemeral:skipped, prod:success"

gcloud storage ls -l gs://crypto-pipeline-infra-260528-ci-state/dbt-state/manifest.json
# Timestamp should be from this run (recent)
```

## 6. Confirm the change reached prod
```bash
bq query --use_legacy_sql=false --project_id=$GCP_PROJECT_PROD --format=pretty \
  "SELECT * FROM \`$GCP_PROJECT_PROD.crypto_analytics.fct_crypto_prices\` ORDER BY ingested_at DESC LIMIT 5"
```

## 7. Cleanup the test artifacts
- The test PR's ephemeral schema was already auto-dropped.
- The test change is in prod. Either:
  - Revert it: open another PR with `git revert <merge_sha>`, or
  - Leave it — it's a SQL comment, harmless.

## All green?
Your repo and cloud state now match the live architecture. See:
- `../../README.md` — the live architecture & status
- `../start-here-mental-model.md` — concepts
- `../walkthrough-one-change.md` — a real recorded trace
- `../howto-playbook.md` — day-to-day recipes
- `../../LEARNING.md` — every gotcha we hit

When anything breaks, the scripts in `scripts/` are idempotent — safe to re-run from the
failed step.
