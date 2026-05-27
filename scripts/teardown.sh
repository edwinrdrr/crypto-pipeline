#!/usr/bin/env bash
# Tear everything down so you can rebuild cleanly from scratch.
# Deletes the GCP project (which removes ALL its resources). Optionally the GitHub repo.
#
#   PROJECT_ID=... ./scripts/teardown.sh
#   PROJECT_ID=... DELETE_REPO=1 GITHUB_REPO=crypto-pipeline ./scripts/teardown.sh

set -euo pipefail
export PATH="$HOME/google-cloud-sdk/bin:$HOME/bin:$PATH"
: "${PROJECT_ID:?set PROJECT_ID}"

echo "This will DELETE the GCP project '$PROJECT_ID' and all its resources."
read -r -p "Type the project id to confirm: " confirm
[ "$confirm" = "$PROJECT_ID" ] || { echo "mismatch — aborting"; exit 1; }

gcloud projects delete "$PROJECT_ID" --quiet
echo "Project deletion requested (takes effect shortly; recoverable for ~30 days)."

if [ "${DELETE_REPO:-0}" = "1" ]; then
  : "${GITHUB_REPO:?set GITHUB_REPO to delete it}"
  echo "Deleting GitHub repo $GITHUB_REPO (needs the delete_repo gh scope)..."
  gh repo delete "$GITHUB_REPO" --yes || echo "skip/failed — delete it manually if needed"
fi

echo "Done. To rebuild: re-auth if needed, then run scripts/bootstrap.sh with a NEW PROJECT_ID."
