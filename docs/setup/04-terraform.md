# 04 — Terraform: per-env data projects + shared infra

Apply Terraform so each env project gets its bucket + datasets + SAs, and the infra project
gets WIF + the ci-state bucket + tf-runner SA.

## What you'll have when done
- Each env project (`dev`/`stg`/`prod`) has:
  - One GCS bucket: `<project>-crypto-raw` (with 30-day lifecycle on raw files)
  - Two BigQuery datasets: `crypto_raw`, `crypto_analytics`
  - SA: `dbt-ci@<project>` (data editor + jobUser + dataOwner)
  - In staging/prod only: also `crypto-ingest-fn@` + `crypto-scheduler@` SAs
  - Labels: `env`, `managed_by=terraform`, `repo=crypto-pipeline`
- The infra project has:
  - `<infra>-tfstate` bucket (created earlier; imported by Terraform)
  - `<infra>-ci-state` bucket (Slim CI manifest)
  - WIF pool `github-actions` + provider `github` (OIDC for GitHub)
  - `tf-runner@<infra>` SA (read-only across env projects, for terraform plan-on-PR)
  - Cross-project IAM bindings: each env's `dbt-ci` SA is impersonable by GitHub via WIF

## Structure recap
```
terraform/
├── modules/
│   ├── data-project/   # bucket + 2 datasets + SAs + project/bucket IAM + labels
│   └── wif/            # pool + provider + impersonation bindings
└── envs/
    ├── dev/            # deploy_function=false
    ├── staging/        # deploy_function=true
    ├── prod/           # deploy_function=true
    └── infra/          # tfstate + ci-state + WIF + tf-runner
```
Each env folder has its own `backend.tf` pointing at
`gs://crypto-pipeline-infra-260528-tfstate/envs/<env>/`.

> **Why remote state in the *infra* bucket** (vs one tfstate bucket per env project)?
> One canonical location is simpler to back up, audit, and IAM-restrict. Per-env *prefixes*
> in one bucket give the same isolation as separate buckets, with fewer moving parts.
> Object versioning is enabled (30 versions retained) so accidental destruction is
> recoverable.

> **`.terraform.lock.hcl` per env IS committed** — it pins provider versions for
> reproducible builds. Don't gitignore it.

## Fast path
This step is also part of `bootstrap.sh` (Phases 6–8). If you ran the fast path in doc 03,
Terraform has already been applied. To re-apply or to apply manually:

```bash
# Apply env data projects (in any order — they don't depend on each other)
for env in dev staging prod; do
  cd terraform/envs/$env
  terraform init -input=false
  terraform apply -auto-approve -input=false
  cd ../../..
done

# Apply infra LAST — it references the env SAs created above
cd terraform/envs/infra
terraform init -input=false
# Import the tfstate bucket so Terraform manages it going forward (one-time)
if ! terraform state list 2>/dev/null | grep -q '^google_storage_bucket\.tfstate$'; then
  terraform import google_storage_bucket.tfstate crypto-pipeline-infra-260528-tfstate
fi
terraform apply -auto-approve -input=false
cd ../../..
```

## terraform.tfvars (each env's `terraform.tfvars` is gitignored)
`bootstrap.sh` writes these for you. If applying manually, copy from the `.example`:
```bash
# envs/dev/terraform.tfvars
project_id = "crypto-pipeline-dev-260528"
region     = "us-central1"
location   = "US"

# envs/staging/terraform.tfvars   same shape, different project_id
# envs/prod/terraform.tfvars      same

# envs/infra/terraform.tfvars
project_id           = "crypto-pipeline-infra-260528"
region               = "us-central1"
location             = "US"
dev_project_id       = "crypto-pipeline-dev-260528"
staging_project_id   = "crypto-pipeline-stg-260528"
prod_project_id      = "crypto-pipeline-prod-260528"
github_repository    = "edwinrdrr/crypto-pipeline"
github_repository_id = "REPLACE_WITH_NUMERIC_ID"
```
Get the numeric repository_id with:
```bash
gh api repos/edwinrdrr/crypto-pipeline --jq .id    # → 1251445803
```
> Don't use `gh repo view --json id`; that returns the GraphQL node id (e.g.
> `R_kgDOSpeMKw`), not what WIF needs.

## Verify
```bash
# Per-env: datasets + bucket exist
for env in dev stg prod; do
  PROJECT=crypto-pipeline-${env}-260528
  echo "--- $PROJECT ---"
  bq ls --project_id=$PROJECT             # crypto_raw + crypto_analytics
  gcloud storage buckets list --project=$PROJECT --format='value(name)'
done

# Infra: WIF provider exists
gcloud iam workload-identity-pools providers list \
  --project=crypto-pipeline-infra-260528 --location=global \
  --workload-identity-pool=github-actions \
  --format='value(name)'
# → projects/.../workloadIdentityPools/github-actions/providers/github

# Infra: tf-runner SA exists
gcloud iam service-accounts list --project=crypto-pipeline-infra-260528 \
  | grep tf-runner
```

→ continue to [`05-github-environments-wif.md`](05-github-environments-wif.md).
