# ---------------------------------------------------------------------------
# Remote state backend (S3 with S3-native lockfile locking).
# State locking uses S3 conditional writes (use_lockfile = true, GA since
# Terraform 1.10) instead of a DynamoDB lock table. The state bucket is
# created by ../bootstrap BEFORE `terraform init` is run here; values must
# match the bootstrap config.
#
# NOTE: The `mcf-srid-tfstate-lock` DynamoDB table (created by ../bootstrap)
# is now unused/legacy. It is retained for now and is safe to remove in a
# later cleanup once S3-native locking is confirmed in all environments.
# ---------------------------------------------------------------------------
terraform {
  backend "s3" {
    bucket       = "mcf-srid-tfstate-022499047467-apse1"
    key          = "server-room-inspection-dashboard/phase0/terraform.tfstate"
    region       = "ap-southeast-1"
    use_lockfile = true
    encrypt      = true
  }
}
