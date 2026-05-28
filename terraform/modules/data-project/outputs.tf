output "raw_bucket" {
  description = "Name of this env's raw landing bucket."
  value       = google_storage_bucket.raw.name
}

output "raw_dataset" {
  description = "BigQuery dataset id for raw data."
  value       = google_bigquery_dataset.raw.dataset_id
}

output "analytics_dataset" {
  description = "BigQuery dataset id for dbt analytics models."
  value       = google_bigquery_dataset.analytics.dataset_id
}

output "dbt_ci_sa_email" {
  description = "Email of the dbt-ci service account in this project (used by WIF for impersonation)."
  value       = google_service_account.dbt_ci.email
}

output "function_runtime_sa_email" {
  description = "Email of the Cloud Function runtime SA (only created when deploy_function = true)."
  value       = var.deploy_function ? google_service_account.function_runtime[0].email : null
}

output "scheduler_sa_email" {
  description = "Email of the Cloud Scheduler SA (only created when deploy_function = true)."
  value       = var.deploy_function ? google_service_account.scheduler[0].email : null
}
