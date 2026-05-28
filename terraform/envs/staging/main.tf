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
  source             = "../../modules/data-project"
  project_id         = var.project_id
  env                = "staging"
  location           = var.location
  raw_lifecycle_days = 30

  # Staging deploys the Cloud Function (scheduler PAUSED — see deploy.sh).
  deploy_function = true
}

output "raw_bucket" { value = module.data_project.raw_bucket }
output "dbt_ci_sa_email" { value = module.data_project.dbt_ci_sa_email }
output "function_runtime_sa_email" { value = module.data_project.function_runtime_sa_email }
output "scheduler_sa_email" { value = module.data_project.scheduler_sa_email }
