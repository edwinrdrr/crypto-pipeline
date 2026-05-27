variable "project_id" {
  description = "Your GCP project id"
  type        = string
}

variable "region" {
  description = "Default region for regional resources"
  type        = string
  default     = "us-central1"
}

variable "location" {
  description = "Multi-region for BigQuery + GCS (US is free-tier friendly)"
  type        = string
  default     = "US"
}
