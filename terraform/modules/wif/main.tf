# Workload Identity Federation for GitHub Actions → GCP (keyless auth).
# Creates a single Pool + OIDC Provider in the infra project, and grants each
# env's dbt-ci service account the impersonation binding so GitHub Actions can
# act as it via a short-lived OIDC token (no long-lived SA keys).
#
# Best practice (Google):
# - One pool per use case (single provider per pool to avoid subject collisions)
# - Attribute conditions to restrict by repository_id (immutable)
# - Use repository_id (system-generated, immutable) not repository name

resource "google_iam_workload_identity_pool" "github" {
  project                   = var.project_id
  workload_identity_pool_id = var.pool_id
  display_name              = "GitHub Actions"
  description               = "Pool for keyless auth from GitHub Actions"
}

resource "google_iam_workload_identity_pool_provider" "github" {
  project                            = var.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = var.provider_id
  display_name                       = "GitHub OIDC"

  attribute_mapping = {
    "google.subject"             = "assertion.sub"
    "attribute.repository"       = "assertion.repository"
    "attribute.repository_id"    = "assertion.repository_id"
    "attribute.repository_owner" = "assertion.repository_owner"
    "attribute.ref"              = "assertion.ref"
    "attribute.environment"      = "assertion.environment"
  }

  # Restrict the provider to ONLY accept tokens from this specific repository
  # (using the immutable repository_id, per Google's best-practice doc).
  attribute_condition = "assertion.repository_id == \"${var.github_repository_id}\""

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

# Bind each env's dbt-ci SA to be impersonatable by GitHub's OIDC subject for
# this repo. The principalSet uses the pool name + attribute filter.
locals {
  pool_principal_set = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.github_repository}"
}

resource "google_service_account_iam_member" "dbt_ci_impersonation" {
  for_each           = var.env_dbt_ci_sa_emails
  service_account_id = "projects/${each.key == "dev" ? var.dev_project_id : (each.key == "staging" ? var.staging_project_id : var.prod_project_id)}/serviceAccounts/${each.value}"
  role               = "roles/iam.workloadIdentityUser"
  member             = local.pool_principal_set
}
