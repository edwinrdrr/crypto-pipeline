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

variable "project_id" { type = string }
variable "region" {
  type    = string
  default = "us-central1"
}
variable "location" {
  type    = string
  default = "US"
}

module "data_project" {
  source     = "../../modules/data-project"
  project_id = var.project_id
  env        = "dev"
  location   = var.location

  # Dev tidiness: raw tables auto-expire after 14 days; bucket files after 30.
  raw_lifecycle_days                    = 30
  dataset_default_table_expiration_days = 14

  # Dev does NOT deploy the Cloud Function — local ingestion only.
  deploy_function = false
}

output "raw_bucket" { value = module.data_project.raw_bucket }
output "dbt_ci_sa_email" { value = module.data_project.dbt_ci_sa_email }
