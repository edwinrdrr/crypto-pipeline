variable "project_id" {
  description = "The infra project that hosts the WIF pool + provider."
  type        = string
}

variable "pool_id" {
  description = "Workload identity pool id."
  type        = string
  default     = "github-actions"
}

variable "provider_id" {
  description = "Workload identity provider id (within the pool)."
  type        = string
  default     = "github"
}

variable "github_repository" {
  description = "Full repo slug (owner/name) — e.g. edwinrdrr/crypto-pipeline. Used for principalSet binding."
  type        = string
}

variable "github_repository_id" {
  description = "Immutable numeric repository_id from GitHub (use `gh repo view --json id -q .databaseId`). Best-practice over name (survives renames)."
  type        = string
}

variable "env_dbt_ci_sa_emails" {
  description = "Map of env name -> dbt-ci SA email to grant WIF impersonation."
  type        = map(string)
  # e.g. { dev = "dbt-ci@crypto-pipeline-dev-260528.iam.gserviceaccount.com", ... }
}

variable "dev_project_id" {
  description = "Dev project id (needed to construct the SA resource path)."
  type        = string
}

variable "staging_project_id" {
  description = "Staging project id."
  type        = string
}

variable "prod_project_id" {
  description = "Prod project id."
  type        = string
}
