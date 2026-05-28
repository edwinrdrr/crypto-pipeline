# 01 — Prerequisites (install tools, authenticate)

Install the exact tool versions this project uses, then authenticate to GCP + GitHub.

## OS-level prerequisites (assumed already present)
- **Linux or macOS** with `bash`, `git`, `python3` (≥3.10), `curl`, `unzip` available on `PATH`.
- A shell where you can `export PATH=...` and `set -a && source .env && set +a`.

Quick check:
```bash
bash --version | head -1     # GNU bash 4+
git --version                # 2.x
python3 --version            # 3.10+
which curl unzip             # both found
```

## What you'll have when done
- `gcloud` (Google Cloud SDK) in `~/google-cloud-sdk/bin/`
- `terraform` v1.9.8 in `~/bin/`
- `dbt-bigquery` in a project-local `.venv/`
- `gh` (GitHub CLI) — install via your package manager
- ADC (Application Default Credentials) for local Terraform + dbt
- gcloud account logged in for CLI commands
- gh authenticated for PR / Secrets / Environments actions

## Fast path
```bash
./scripts/install-tools.sh         # idempotent; pinned versions

# add to ~/.bashrc to make permanent
export PATH="$HOME/google-cloud-sdk/bin:$HOME/bin:$PATH"

# interactive (browser opens)
gcloud auth login
gcloud auth application-default login
gh auth login                       # pick: GitHub.com, HTTPS, login w/ web browser
```
> `install-tools.sh` will tell you to install `gh` manually if missing — see
> https://cli.github.com.

## Manual path (what the script does)

### gcloud
```bash
cd ~
curl -sSL -o gcloud-cli.tar.gz \
  https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-linux-x86_64.tar.gz
tar -xzf gcloud-cli.tar.gz && rm gcloud-cli.tar.gz
./google-cloud-sdk/install.sh --quiet --path-update=true
```

### Terraform 1.9.8 (older versions hit a GPG-key-expired bug)
```bash
mkdir -p ~/bin && cd ~
curl -sSL -o tf.zip \
  https://releases.hashicorp.com/terraform/1.9.8/terraform_1.9.8_linux_amd64.zip
unzip -oq tf.zip terraform -d ~/bin && rm tf.zip
```

### Python venv + dbt-bigquery + ingestion deps
```bash
cd ~/Documents/learning/crypto-pipeline
python3 -m venv .venv
.venv/bin/pip install -q --upgrade pip
.venv/bin/pip install -q dbt-bigquery
.venv/bin/pip install -q -r ingestion/requirements.txt
```

### gh
- Linux: see https://github.com/cli/cli/blob/trunk/docs/install_linux.md
- macOS: `brew install gh`
- Other: https://cli.github.com

## Verify
```bash
gcloud --version | head -1                                         # Google Cloud SDK 5xx.x.x
~/bin/terraform version | head -1                                  # Terraform v1.9.8
.venv/bin/dbt --version | head -1                                  # Core: installed: 1.x.x
gh --version | head -1                                              # gh version 2.x

gcloud auth list --filter=status:ACTIVE --format='value(account)'   # your email
ls ~/.config/gcloud/application_default_credentials.json            # ADC file exists
gh auth status                                                       # ✓ Logged in
```

All good? → continue to [`02-gcp-projects.md`](02-gcp-projects.md).
