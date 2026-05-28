terraform {
  backend "gcs" {
    bucket = "crypto-pipeline-infra-260528-tfstate"
    prefix = "envs/staging"
  }
}
