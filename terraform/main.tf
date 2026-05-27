terraform {
  required_version = ">= 1.5"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
  # Store state in GCS so it's shared + versioned (free tier). Create the bucket
  # once manually, then uncomment and run `terraform init -migrate-state`.
  # backend "gcs" {
  #   bucket = "YOUR_PROJECT_ID-tfstate"
  #   prefix = "crypto-pipeline"
  # }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# --- Data lake: raw landing bucket -------------------------------------------
resource "google_storage_bucket" "raw" {
  name                        = "${var.project_id}-crypto-raw"
  location                    = var.location
  uniform_bucket_level_access = true
  force_destroy               = true # ok for a learning project

  # Auto-delete raw files after 30 days to stay comfortably in the free tier.
  lifecycle_rule {
    condition { age = 30 }
    action { type = "Delete" }
  }
}

# --- Environments as BigQuery datasets ---------------------------------------
# Raw (loaded by the ingestion job) + analytics (built by dbt), each per-env.
locals {
  datasets = {
    crypto_raw_dev           = "Raw CoinGecko data - dev"
    crypto_raw               = "Raw CoinGecko data - prod"
    crypto_analytics_dev     = "dbt models - dev"
    crypto_analytics_staging = "dbt models - staging"
    crypto_analytics         = "dbt models - prod"
  }
}

resource "google_bigquery_dataset" "datasets" {
  for_each      = local.datasets
  dataset_id    = each.key
  friendly_name = each.key
  description   = each.value
  location      = var.location
  # Expire raw dev tables after 14 days; keep prod/analytics indefinitely.
  default_table_expiration_ms = each.key == "crypto_raw_dev" ? 14 * 24 * 60 * 60 * 1000 : null
}
