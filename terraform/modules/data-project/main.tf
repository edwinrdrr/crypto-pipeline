# Reusable module for one DATA project (dev / staging / prod).
# Creates: raw landing bucket, raw + analytics BigQuery datasets, project-scoped
# service accounts (dbt-ci, plus optionally crypto-ingest-fn + crypto-scheduler
# for envs that deploy the Cloud Function).
#
# Project = environment: inside a project we DON'T suffix dataset names.

locals {
  common_labels = {
    env        = var.env
    managed_by = "terraform"
    repo       = "crypto-pipeline"
  }
  raw_bucket_name = "${var.project_id}-crypto-raw"
}

# ── Raw landing bucket ──────────────────────────────────────────────────────
resource "google_storage_bucket" "raw" {
  name                        = local.raw_bucket_name
  project                     = var.project_id
  location                    = var.location
  uniform_bucket_level_access = true
  force_destroy               = var.bucket_force_destroy

  lifecycle_rule {
    condition { age = var.raw_lifecycle_days }
    action { type = "Delete" }
  }

  labels = local.common_labels
}

# ── BigQuery datasets (raw + analytics) ─────────────────────────────────────
resource "google_bigquery_dataset" "raw" {
  project       = var.project_id
  dataset_id    = "crypto_raw"
  friendly_name = "Raw CoinGecko data (${var.env})"
  description   = "Raw API snapshots landed by the ingestion job."
  location      = var.location
  labels        = local.common_labels

  # In dev, expire tables after N days to keep things tidy.
  default_table_expiration_ms = var.dataset_default_table_expiration_days != null ? (
    var.dataset_default_table_expiration_days * 24 * 60 * 60 * 1000
  ) : null
}

resource "google_bigquery_dataset" "analytics" {
  project       = var.project_id
  dataset_id    = "crypto_analytics"
  friendly_name = "dbt models (${var.env})"
  description   = "Analytics models built by dbt."
  location      = var.location
  labels        = local.common_labels
}

# ── Service accounts ────────────────────────────────────────────────────────
# dbt-ci: identity for CI (runs dbt against this project)
resource "google_service_account" "dbt_ci" {
  project      = var.project_id
  account_id   = "dbt-ci"
  display_name = "dbt CI (${var.env})"
  description  = "Used by GitHub Actions (via WIF) to run dbt in this project."
}

# Function runtime + scheduler SAs — only in envs that deploy the function
# (staging + prod). Dev omits them; dev's ingestion runs locally as the user.
resource "google_service_account" "function_runtime" {
  count        = var.deploy_function ? 1 : 0
  project      = var.project_id
  account_id   = "crypto-ingest-fn"
  display_name = "Crypto ingest function runtime (${var.env})"
  description  = "Runtime identity for the Cloud Function."
}

resource "google_service_account" "scheduler" {
  count        = var.deploy_function ? 1 : 0
  project      = var.project_id
  account_id   = "crypto-scheduler"
  display_name = "Crypto ingest scheduler (${var.env})"
  description  = "Identity that Cloud Scheduler uses to invoke the function via OIDC."
}

# ── Project-level IAM ───────────────────────────────────────────────────────
# dbt-ci roles: build models (dataEditor), run jobs (jobUser), drop ephemeral
# PR schemas (dataOwner — only really needed in dev, but harmless elsewhere).
locals {
  dbt_ci_roles = [
    "roles/bigquery.dataEditor",
    "roles/bigquery.jobUser",
    "roles/bigquery.dataOwner",
  ]
  function_runtime_roles = [
    "roles/bigquery.dataEditor",
    "roles/bigquery.jobUser",
  ]
}

resource "google_project_iam_member" "dbt_ci" {
  for_each = toset(local.dbt_ci_roles)
  project  = var.project_id
  role     = each.value
  member   = "serviceAccount:${google_service_account.dbt_ci.email}"
}

resource "google_project_iam_member" "function_runtime" {
  for_each = var.deploy_function ? toset(local.function_runtime_roles) : toset([])
  project  = var.project_id
  role     = each.value
  member   = "serviceAccount:${google_service_account.function_runtime[0].email}"
}

# ── Bucket IAM ──────────────────────────────────────────────────────────────
# dbt-ci needs storage access on this project's bucket (in prod: to publish the
# manifest.json for Slim CI; in dev: not strictly required but harmless).
resource "google_storage_bucket_iam_member" "dbt_ci_bucket" {
  bucket = google_storage_bucket.raw.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.dbt_ci.email}"
}

resource "google_storage_bucket_iam_member" "function_runtime_bucket" {
  count  = var.deploy_function ? 1 : 0
  bucket = google_storage_bucket.raw.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.function_runtime[0].email}"
}
