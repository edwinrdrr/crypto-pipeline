# 05 — GitHub Environments + per-env secrets + WIF impersonation

Configure the CI/CD identity story: per-Environment secrets + required-reviewer on
production. WIF (impersonation bindings) was already set up by Terraform in doc 03.

## What you'll have when done
- 3 GitHub Environments (`dev`, `staging`, `production`)
- 3 per-Environment secrets:
  - `dev`: `GCP_PROJECT_DEV = crypto-pipeline-dev-260528`
  - `staging`: `GCP_PROJECT_STAGING = crypto-pipeline-stg-260528`
  - `production`: `GCP_PROJECT_PROD = crypto-pipeline-prod-260528`
- `production` Environment has a **required-reviewer** rule (you approve prod deploys)
- No repo-level secrets (`GCP_SA_KEY` and `GCP_PROJECT` deleted if they existed — WIF
  replaces them)

## Fast path
```bash
./scripts/setup-github-environments.sh
```
Idempotent. Optional env:
```bash
GITHUB_REPO=edwinrdrr/crypto-pipeline PROJECT_SUFFIX=260528 \
  ./scripts/setup-github-environments.sh
```

## Manual path

### Create environments + required-reviewer on `production`
```bash
USER_ID=$(gh api user --jq .id)            # numeric id; required-reviewer = you

echo '{"wait_timer":0}' \
  | gh api -X PUT repos/edwinrdrr/crypto-pipeline/environments/dev --input -

echo '{"wait_timer":0}' \
  | gh api -X PUT repos/edwinrdrr/crypto-pipeline/environments/staging --input -

printf '{"wait_timer":0,"prevent_self_review":false,"reviewers":[{"type":"User","id":%s}]}' "$USER_ID" \
  | gh api -X PUT repos/edwinrdrr/crypto-pipeline/environments/production --input -
```
> `prevent_self_review=false` matters because **you** will both deploy and approve
> (as the sole collaborator). Set to `true` only if you have multiple reviewers.

### Per-Environment secrets
```bash
gh secret set GCP_PROJECT_DEV     --env dev        --body "crypto-pipeline-dev-260528"
gh secret set GCP_PROJECT_STAGING --env staging    --body "crypto-pipeline-stg-260528"
gh secret set GCP_PROJECT_PROD    --env production --body "crypto-pipeline-prod-260528"
```

### Remove legacy repo-level secrets
```bash
gh secret delete GCP_SA_KEY  2>/dev/null || true
gh secret delete GCP_PROJECT 2>/dev/null || true
```

### WIF impersonation chain — already done in doc 03

```
GitHub Action job  ──►  OIDC token (subject: "repo:edwinrdrr/crypto-pipeline:...")
                        ▲
                        │ workflow declares  permissions: { id-token: write }
                        │
                        ▼
google-github-actions/auth@v2
                        │  workload_identity_provider = projects/.../providers/github
                        │  service_account            = dbt-ci@<env-project>
                        ▼
WIF provider (in infra)
                        │  attribute_condition: repository_id == "1251445803"  ← only THIS repo
                        │  attribute_mapping:   subject, repository, ref, environment, ...
                        ▼
Workload Identity Pool
                        │  principalSet://.../attribute.repository/edwinrdrr/crypto-pipeline
                        ▼
dbt-ci@<env-project> SA's IAM binding
                        │  roles/iam.workloadIdentityUser → that principalSet
                        ▼
GCP short-lived ADC (≤1 hour) → workflow can act as dbt-ci@<env-project>
```

Terraform's `envs/infra/main.tf` (via `modules/wif/`) creates the pool, the provider, AND
the `google_service_account_iam_member` binding for each env SA. The attribute condition
on `repository_id` (immutable, survives repo rename) is the security boundary —
**no other repo can impersonate these SAs**.

This is what lets the workflow `service_account:` field assume each env's SA without keys.

## Verify
```bash
# repo-level secrets: NONE
gh secret list

# Per-env secrets
for env in dev staging production; do
  echo "--- $env ---"; gh secret list --env "$env"
done

# Required-reviewer on production
gh api repos/edwinrdrr/crypto-pipeline/environments/production \
  --jq '.protection_rules[] | select(.type=="required_reviewers") | .reviewers[].reviewer.login'
# → edwinrdrr
```

→ continue to [`06-dbt-local.md`](06-dbt-local.md).
