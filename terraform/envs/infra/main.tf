terraform {
  required_version = ">= 1.5"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

variable "project_id" {
  description = "Infra project (hosts tfstate bucket + WIF pool)."
  type        = string
}
variable "region" {
  type    = string
  default = "us-central1"
}
variable "location" {
  type    = string
  default = "US"
}
variable "dev_project_id" { type = string }
variable "staging_project_id" { type = string }
variable "prod_project_id" { type = string }
variable "github_repository" {
  description = "owner/repo (e.g. edwinrdrr/crypto-pipeline)."
  type        = string
}
variable "github_repository_id" {
  description = "Immutable numeric repository_id (best practice over name)."
  type        = string
}

# ── State bucket (managed in IaC after initial bootstrap import) ────────────
# Note: the tfstate bucket is created by bootstrap.sh BEFORE this Terraform
# runs (chicken-and-egg). We `terraform import` it during PR C so it ends up
# managed by IaC going forward.
resource "google_storage_bucket" "tfstate" {
  name                        = "${var.project_id}-tfstate"
  project                     = var.project_id
  location                    = var.location
  uniform_bucket_level_access = true
  force_destroy               = false # state is precious; don't auto-destroy

  versioning { enabled = true }

  lifecycle_rule {
    condition { num_newer_versions = 30 } # keep 30 most-recent versions; delete older
    action { type = "Delete" }
  }

  labels = {
    env        = "infra"
    managed_by = "terraform"
    repo       = "crypto-pipeline"
  }
}

# ── Shared CI artifacts bucket (e.g. Slim CI manifest.json) ─────────────────
# Lives in infra so all envs' CI jobs can read/write a single shared location.
resource "google_storage_bucket" "ci_state" {
  name                        = "${var.project_id}-ci-state"
  project                     = var.project_id
  location                    = var.location
  uniform_bucket_level_access = true
  force_destroy               = true

  versioning { enabled = true }

  labels = {
    env        = "infra"
    managed_by = "terraform"
    repo       = "crypto-pipeline"
  }
}

# Per-env dbt-ci SAs need bucket access on ci_state:
#   - prod's dbt-ci: read+write (publishes manifest)
#   - staging's dbt-ci: read (downloads manifest if it ever Slim-builds)
#   - dev's dbt-ci: read (PR Slim CI baseline)
locals {
  ci_state_readers = [
    "serviceAccount:dbt-ci@${var.dev_project_id}.iam.gserviceaccount.com",
    "serviceAccount:dbt-ci@${var.staging_project_id}.iam.gserviceaccount.com",
  ]
  ci_state_writers = [
    "serviceAccount:dbt-ci@${var.prod_project_id}.iam.gserviceaccount.com",
  ]
}

resource "google_storage_bucket_iam_member" "ci_state_readers" {
  for_each = toset(local.ci_state_readers)
  bucket   = google_storage_bucket.ci_state.name
  role     = "roles/storage.objectViewer"
  member   = each.value
}

resource "google_storage_bucket_iam_member" "ci_state_writers" {
  for_each = toset(local.ci_state_writers)
  bucket   = google_storage_bucket.ci_state.name
  role     = "roles/storage.objectAdmin"
  member   = each.value
}

# ── Workload Identity Federation (keyless GitHub Actions → GCP) ─────────────
module "wif" {
  source               = "../../modules/wif"
  project_id           = var.project_id
  github_repository    = var.github_repository
  github_repository_id = var.github_repository_id
  dev_project_id       = var.dev_project_id
  staging_project_id   = var.staging_project_id
  prod_project_id      = var.prod_project_id

  env_dbt_ci_sa_emails = {
    dev     = "dbt-ci@${var.dev_project_id}.iam.gserviceaccount.com"
    staging = "dbt-ci@${var.staging_project_id}.iam.gserviceaccount.com"
    prod    = "dbt-ci@${var.prod_project_id}.iam.gserviceaccount.com"
  }
}

output "tfstate_bucket" { value = google_storage_bucket.tfstate.name }
output "ci_state_bucket" { value = google_storage_bucket.ci_state.name }
output "wif_provider_name" {
  description = "Put this in GitHub workflow as workload_identity_provider:"
  value       = module.wif.provider_name
}
