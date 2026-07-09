variable "name_prefix" {
  description = "Prefix applied to secret names (used as the secret path root)."
  type        = string
}

variable "kms_key_arn" {
  description = "Customer-managed KMS key ARN used to encrypt the secrets."
  type        = string
}

# Phase 1: real RDS connection payload written into the EXISTING db secret.
# Left empty in Phase 0, which keeps the placeholder. When `host` is non-empty
# the same secret_version resource is updated in place with real values — no
# second secret is created.
variable "db_connection" {
  description = "RDS connection payload for the db credentials secret (sensitive)."
  type = object({
    engine       = string
    host         = string
    port         = number
    dbname       = string
    username     = string
    password     = string
    app_username = string
    app_password = string
  })
  sensitive = true
  default = {
    engine       = "postgres"
    host         = ""
    port         = 5432
    dbname       = ""
    username     = ""
    password     = ""
    app_username = ""
    app_password = ""
  }
}
