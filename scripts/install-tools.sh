#!/usr/bin/env bash
# Install the exact tool versions this project needs, into your home dir (no sudo).
# Idempotent: skips anything already present. Run once per machine.
#
#   ./scripts/install-tools.sh
#
# Pinned versions for reproducibility:
TERRAFORM_VERSION="1.9.8"
PYTHON_BIN="${PYTHON_BIN:-python3}"

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> [1/4] gcloud CLI"
if [ ! -x "$HOME/google-cloud-sdk/bin/gcloud" ]; then
  ( cd "$HOME"
    curl -sSL -o gcloud-cli.tar.gz \
      https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-linux-x86_64.tar.gz
    tar -xzf gcloud-cli.tar.gz && rm gcloud-cli.tar.gz
    ./google-cloud-sdk/install.sh --quiet --path-update=true )
  echo "    installed gcloud (open a new shell to get it on PATH)"
else
  echo "    already present: $($HOME/google-cloud-sdk/bin/gcloud --version | head -1)"
fi

echo "==> [2/4] Terraform $TERRAFORM_VERSION (older builds hit a GPG 'key expired' bug)"
if [ ! -x "$HOME/bin/terraform" ] || ! "$HOME/bin/terraform" version | grep -q "$TERRAFORM_VERSION"; then
  mkdir -p "$HOME/bin"
  ( cd "$HOME"
    curl -sSL -o tf.zip \
      "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip"
    unzip -oq tf.zip terraform -d "$HOME/bin" && rm tf.zip )
  echo "    installed terraform to ~/bin"
else
  echo "    already present: $($HOME/bin/terraform version | head -1)"
fi

echo "==> [3/4] Python venv + dbt + ingestion deps"
if [ ! -x "$REPO_ROOT/.venv/bin/dbt" ]; then
  "$PYTHON_BIN" -m venv "$REPO_ROOT/.venv"
  "$REPO_ROOT/.venv/bin/pip" install -q --upgrade pip
  "$REPO_ROOT/.venv/bin/pip" install -q dbt-bigquery
  "$REPO_ROOT/.venv/bin/pip" install -q -r "$REPO_ROOT/ingestion/requirements.txt"
  echo "    installed: $($REPO_ROOT/.venv/bin/dbt --version | head -1)"
else
  echo "    already present: $($REPO_ROOT/.venv/bin/dbt --version | head -1)"
fi

echo "==> [4/4] GitHub CLI (gh)"
if command -v gh >/dev/null 2>&1; then
  echo "    already present: $(gh --version | head -1)"
else
  echo "    MISSING — install from https://cli.github.com (needs your package manager / sudo),"
  echo "    then run: gh auth login"
fi

echo
echo "Done. Next:"
echo "  export PATH=\"\$HOME/google-cloud-sdk/bin:\$HOME/bin:\$PATH\"   # add to ~/.bashrc"
echo "  gcloud auth login && gcloud auth application-default login"
echo "  gh auth login"
echo "  then: PROJECT_ID=... BILLING_ACCOUNT_ID=... ./scripts/bootstrap.sh"
