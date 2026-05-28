variable "project_id" {
  description = "The GCP project that holds this environment's resources."
  type        = string
}

variable "env" {
  description = "Environment name (dev / staging / prod). Used in labels and friendly names."
  type        = string
  validation {
    condition     = contains(["dev", "staging", "prod"], var.env)
    error_message = "env must be one of: dev, staging, prod."
  }
}

variable "location" {
  description = "BigQuery + GCS location. Use a multi-region (US/EU) for free-tier friendliness."
  type        = string
  default     = "US"
}

variable "raw_lifecycle_days" {
  description = "Auto-delete raw GCS files after this many days."
  type        = number
  default     = 30
}

variable "dataset_default_table_expiration_days" {
  description = "Default table expiration for the crypto_raw dataset (set in dev, leave null for staging/prod)."
  type        = number
  default     = null
}

variable "deploy_function" {
  description = "Whether to create the Cloud Function runtime + scheduler service accounts (staging/prod only)."
  type        = bool
  default     = false
}

variable "bucket_force_destroy" {
  description = "Allow Terraform to destroy the bucket even if it has objects. Keep true for the learning project."
  type        = bool
  default     = true
}
