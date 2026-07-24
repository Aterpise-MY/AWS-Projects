###############################################################################
# Secrets — application-level secrets that belong to no other module.
#
#   ticketing-dev/app-key   Laravel APP_KEY, generated here
#   ticketing-dev/smtp      mail transport credentials, placeholder then manual
#
# > The database and Redis secrets are deliberately NOT created here. Each is
# > owned by the module that generates the credential (`database`, `cache`), so
# > no plaintext credential ever crosses a module boundary as a Terraform
# > output. `terraform/dev/main.tf` composes the four ARNs into the list the
# > External Secrets IRSA policy is scoped to.
#
# No secret VALUE appears in this file or in any output. `app_key` is generated
# by the random provider and lands only in Terraform state and Secrets Manager.
###############################################################################

locals {
  tags = merge(var.tags, { Component = "data" })
}

###############################################################################
# Laravel APP_KEY
###############################################################################

# Laravel's AES-256-CBC cipher requires exactly 32 bytes of key material, which
# `php artisan key:generate` writes as `base64:<44-char base64 of 32 bytes>`.
# Generating it in Terraform rather than in the container keeps the key stable
# across pod restarts — a rotated APP_KEY invalidates every existing session
# and makes previously encrypted column values undecryptable.
resource "random_bytes" "app_key" {
  length = 32
}

resource "aws_secretsmanager_secret" "app_key" {
  name                    = "${var.name_prefix}/app-key"
  description             = "Laravel APP_KEY for ${var.name_prefix}. Rotating this invalidates all sessions and encrypted column data."
  recovery_window_in_days = var.recovery_window_in_days

  tags = merge(local.tags, { Name = "${var.name_prefix}-app-key" })
}

resource "aws_secretsmanager_secret_version" "app_key" {
  secret_id = aws_secretsmanager_secret.app_key.id

  # Stored as a plain string, not JSON: External Secrets maps it straight onto
  # the APP_KEY environment variable with no key extraction.
  secret_string = "base64:${random_bytes.app_key.base64}"
}

###############################################################################
# SMTP credentials
###############################################################################

resource "aws_secretsmanager_secret" "smtp" {
  name                    = "${var.name_prefix}/smtp"
  description             = "SMTP transport credentials for ${var.name_prefix}. Seeded with placeholders; real values are set out-of-band."
  recovery_window_in_days = var.recovery_window_in_days

  tags = merge(local.tags, { Name = "${var.name_prefix}-smtp" })
}

resource "aws_secretsmanager_secret_version" "smtp" {
  secret_id = aws_secretsmanager_secret.smtp.id

  secret_string = jsonencode({
    host         = var.smtp_placeholder_host
    port         = var.smtp_placeholder_port
    username     = "PLACEHOLDER_SET_OUT_OF_BAND"
    password     = "PLACEHOLDER_SET_OUT_OF_BAND"
    encryption   = var.smtp_placeholder_encryption
    from_address = var.smtp_placeholder_from_address
  })

  lifecycle {
    # Terraform seeds the shape of the document once, then never touches it
    # again. The real credentials are written by an operator with
    # `aws secretsmanager put-secret-value`, and without this the next `apply`
    # would silently revert the mailer to the placeholder and break outbound
    # mail with no error anywhere in the Terraform run.
    ignore_changes = [secret_string]
  }
}
