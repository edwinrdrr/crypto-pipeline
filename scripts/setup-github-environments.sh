#!/usr/bin/env bash
# Idempotent setup of GitHub Environments + per-env secrets + required-reviewer on prod.
# Run AFTER bootstrap.sh (needs the GCP project ids it created) and AFTER `gh auth login`.
#
# Usage:
#   ./scripts/setup-github-environments.sh
#
# Optional env:
#   GITHUB_REPO=edwinrdrr/crypto-pipeline
#   PROJECT_SUFFIX=260528
set -euo pipefail

GITHUB_REPO="${GITHUB_REPO:-edwinrdrr/crypto-pipeline}"
PROJECT_SUFFIX="${PROJECT_SUFFIX:-260528}"
DEV_PROJECT="crypto-pipeline-dev-${PROJECT_SUFFIX}"
STG_PROJECT="crypto-pipeline-stg-${PROJECT_SUFFIX}"
PROD_PROJECT="crypto-pipeline-prod-${PROJECT_SUFFIX}"

echo "########## GitHub Environments setup: $GITHUB_REPO ##########"

USER_ID=$(gh api user --jq .id)
[ -n "$USER_ID" ] || { echo "could not get GitHub user id (gh auth login?)"; exit 1; }
echo "  required-reviewer (on production) will be: $(gh api user --jq .login) ($USER_ID)"

# ── dev: plain environment (no protection rule) ────────────────────────────
echo "==> dev environment"
echo '{"wait_timer":0}' | gh api -X PUT "repos/$GITHUB_REPO/environments/dev" --input - >/dev/null
gh secret set GCP_PROJECT_DEV --env dev --body "$DEV_PROJECT"

# ── staging: plain environment ─────────────────────────────────────────────
echo "==> staging environment"
echo '{"wait_timer":0}' | gh api -X PUT "repos/$GITHUB_REPO/environments/staging" --input - >/dev/null
gh secret set GCP_PROJECT_STAGING --env staging --body "$STG_PROJECT"

# ── production: required-reviewer = me ─────────────────────────────────────
echo "==> production environment (required-reviewer = $(gh api user --jq .login))"
printf '{"wait_timer":0,"prevent_self_review":false,"reviewers":[{"type":"User","id":%s}]}' "$USER_ID" \
  | gh api -X PUT "repos/$GITHUB_REPO/environments/production" --input - >/dev/null
gh secret set GCP_PROJECT_PROD --env production --body "$PROD_PROJECT"

# ── clean up legacy repo-level secrets (WIF replaces them) ─────────────────
echo "==> remove legacy repo-level secrets (idempotent)"
gh secret delete GCP_SA_KEY 2>/dev/null || true
gh secret delete GCP_PROJECT 2>/dev/null || true

echo
echo "########## DONE ##########"
echo "Per-Environment secrets:"
for env in dev staging production; do
  echo "  --- $env ---"
  gh secret list --env "$env"
done
