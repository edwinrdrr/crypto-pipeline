output "pool_name" {
  description = "Full WIF pool resource name (use as workload_identity_pool in google_iam_workload_identity_pool_provider)."
  value       = google_iam_workload_identity_pool.github.name
}

output "provider_name" {
  description = "Full WIF provider resource name. THIS is the value GitHub Actions needs as `workload_identity_provider:`."
  value       = google_iam_workload_identity_pool_provider.github.name
}
