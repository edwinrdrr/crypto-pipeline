# Fork & customize (use this repo as a template)

This repo's setup scripts and docs hardcode names tied to **my account** (`edwinrdrr`),
date suffix (`260528`), and currency (IDR). To make it yours, change these.

## TL;DR — the 4 things you must change

| Thing | Where | Default | Yours |
|-------|-------|---------|-------|
| **GitHub repo slug** | everywhere (docs + workflows + bootstrap.sh) | `edwinrdrr/crypto-pipeline` | `<you>/<your-repo>` |
| **Project ID suffix** | `bootstrap.sh`, `terraform/envs/*/backend.tf`, `.env.example` | `260528` | `$(date +%y%m%d)` or your choice |
| **Billing currency / budget amount** | `bootstrap.sh` (`BUDGET_AMOUNT=80000` = 80,000 IDR ≈ $5) | IDR 80000 | match **your** billing account |
| **GitHub `repository_id`** | `terraform/envs/infra/terraform.tfvars` | `1251445803` | `gh api repos/<you>/<repo> --jq .id` |

If you change these four, everything else just works.

---

## 1. GitHub repo slug

Find-and-replace `edwinrdrr/crypto-pipeline` → `<YOUR_ORG>/<YOUR_REPO>` in:

```bash
# safe to run from repo root after fork
grep -rl "edwinrdrr/crypto-pipeline" --include='*.md' --include='*.sh' --include='*.yml' --include='*.tf' \
  | xargs sed -i 's|edwinrdrr/crypto-pipeline|<YOUR_ORG>/<YOUR_REPO>|g'
```

That covers: `scripts/setup-github-environments.sh`, `scripts/bootstrap.sh` defaults,
all the doc examples, and `terraform/envs/infra/terraform.tfvars.example`.

> Also flip the repo visibility yourself (`gh repo edit --visibility public`) — needed for
> the free required-reviewer rule on the `production` Environment.

---

## 2. Project ID suffix

`260528` is the date we created the projects. Pick your own (any 6-char-ish alphanumeric
suffix unique among GCP project IDs globally):

```bash
SUFFIX=$(date +%y%m%d)         # e.g. 261104

# bootstrap.sh: override at call time
PROJECT_SUFFIX=$SUFFIX BILLING_ACCOUNT_ID=… ./scripts/bootstrap.sh

# Terraform backend bucket name is hardcoded — find-and-replace:
grep -rl "crypto-pipeline-infra-260528" --include='*.tf' --include='*.sh' --include='*.md' \
  | xargs sed -i "s|crypto-pipeline-infra-260528|crypto-pipeline-infra-$SUFFIX|g"
grep -rl "crypto-pipeline-(dev|stg|prod)-260528" --include='*.tf' --include='*.sh' --include='*.md' \
  | xargs sed -i -E "s|crypto-pipeline-(dev|stg|prod)-260528|crypto-pipeline-\\1-$SUFFIX|g"
```

Also update `.env.example` to match.

> Tip: if `PROJECT_SUFFIX=$(date +%y%m%d)` would collide with an existing GCP project
> globally, add a random tail: `PROJECT_SUFFIX=$(date +%y%m%d)-$RANDOM`.

---

## 3. Billing currency / budget amount

`bootstrap.sh` defaults `BUDGET_AMOUNT=80000` — that's **80,000 IDR ≈ $5** because my
billing account is in IDR. The `gcloud billing budgets create` API requires the budget
currency to match your account currency, OR you omit the currency suffix and pass the
native-currency amount.

```bash
# If your billing account is USD:
BUDGET_AMOUNT=5 BILLING_ACCOUNT_ID=… ./scripts/bootstrap.sh

# If your account is EUR:
BUDGET_AMOUNT=5 …    # the literal `5` is interpreted in your account's currency
```

You can confirm your account's currency on the Billing console (or just try; if it errors
with `INVALID_ARGUMENT`, change the amount).

---

## 4. GitHub `repository_id` (for WIF attribute condition)

The WIF provider in `terraform/modules/wif/main.tf` uses an attribute condition that only
accepts OIDC tokens whose `repository_id` matches a specific value. This **prevents another
public repo from impersonating yours**.

After you fork (your fork has a different numeric id):
```bash
# get YOUR repo's numeric id
NEW_ID=$(gh api repos/<YOUR_ORG>/<YOUR_REPO> --jq .id)

# update the infra tfvars
sed -i "s|github_repository_id = \"1251445803\"|github_repository_id = \"$NEW_ID\"|" \
  terraform/envs/infra/terraform.tfvars.example

# update your local tfvars + re-apply infra
sed -i "s|github_repository_id = \"1251445803\"|github_repository_id = \"$NEW_ID\"|" \
  terraform/envs/infra/terraform.tfvars
( cd terraform/envs/infra && terraform apply -auto-approve )
```

`bootstrap.sh` Phase 8 picks this up automatically if you start clean (it reads the id from
`gh api`).

---

## 5. (Optional) Customize the data pipeline itself

These aren't "to reproduce" changes; they're "make it yours":

- **CoinGecko coins**: env var `COINS` in `ingestion/main.py` (default
  `bitcoin,ethereum,solana,cardano`). Change in `ingestion/deploy.sh`'s `--set-env-vars`
  to make it permanent.
- **Ingestion cadence**: change `SCHEDULE` cases in `ingestion/deploy.sh` (default
  `*/5 * * * *` for prod, `0 */6 * * *` paused for staging).
- **dbt model logic**: edit `dbt/models/marts/fct_crypto_prices.sql` and friends.
- **Cron for `scheduled-dbt.yml`**: see doc 09.

---

## Verify your fork after customizing

After running through docs 01–08 with your customizations:

```bash
# All 4 projects exist with your suffix
gcloud projects list --filter="projectId~crypto-pipeline-(infra|dev|stg|prod)-${SUFFIX}"

# WIF provider attribute-condition matches YOUR repo
gcloud iam workload-identity-pools providers describe github \
  --project=crypto-pipeline-infra-${SUFFIX} --location=global \
  --workload-identity-pool=github-actions \
  --format='value(attributeCondition)'
# expected: assertion.repository_id == "<your-numeric-id>"

# Open a test PR; pr-ephemeral should authenticate via WIF as YOUR repo's identity
gh pr create --fill
```

If any step fails, see [`10-troubleshooting.md`](10-troubleshooting.md).
