output "raw_bucket" {
  description = "Name of the raw landing bucket"
  value       = google_storage_bucket.raw.name
}

output "datasets" {
  description = "BigQuery datasets created (the environments)"
  value       = [for d in google_bigquery_dataset.datasets : d.dataset_id]
}
