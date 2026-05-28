# Remote state in the infra project's tfstate bucket, prefixed by env.
# Bootstrap creates the bucket out-of-band (chicken-and-egg).
terraform {
  backend "gcs" {
    bucket = "crypto-pipeline-infra-260528-tfstate"
    prefix = "envs/dev"
  }
}
