# Remote state backend for the dev environment.
#
# PREREQUISITE: `terraform/bootstrap` must be applied FIRST. It creates the
# S3 state bucket, the DynamoDB lock table, and the KMS key referenced below:
#
#   cd ../bootstrap && terraform init && terraform apply
#
# FIRST INIT of this directory (before the backend exists, or for offline
# validation) must skip the backend:
#
#   terraform init -backend=false
#
# Once the bootstrap resources exist, initialise the real backend with:
#
#   terraform init
#
# The bucket has default SSE-KMS with the bootstrap key, so objects are
# encrypted at rest regardless of the `encrypt` flag; `encrypt = true` also
# forces client-side enforcement.
terraform {
  backend "s3" {
    bucket         = "ticketing-dev-tfstate-022499047467"
    key            = "dev/terraform.tfstate"
    region         = "ap-southeast-1"
    dynamodb_table = "ticketing-dev-tflock"
    encrypt        = true
  }
}
