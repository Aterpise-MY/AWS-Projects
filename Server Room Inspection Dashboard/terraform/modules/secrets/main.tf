# ---------------------------------------------------------------------------
# Secrets module — empty placeholder secret containers, KMS-encrypted.
#
# Phase 0 creates ONLY the containers with empty/placeholder values. Real
# values are injected in later phases (out-of-band, never committed):
#   - db      : RDS PostgreSQL credentials
#   - smtp    : SES / SMTP credentials for outbound email
#   - ad_bind : Active Directory bind / service account (AD Connector, later)
#
# NOTE: `recovery_window_in_days = 0` is intentionally NOT set, so accidental
# deletion is recoverable within the default 30-day window.
# ---------------------------------------------------------------------------

locals {
  # Phase 1: if a real RDS host has been supplied, populate the db secret with
  # the full connection payload; otherwise keep the empty Phase 0 placeholder.
  db_payload = var.db_connection.host != "" ? jsonencode({
    engine       = var.db_connection.engine
    host         = var.db_connection.host
    port         = var.db_connection.port
    dbname       = var.db_connection.dbname
    username     = var.db_connection.username
    password     = var.db_connection.password
    app_username = var.db_connection.app_username
    app_password = var.db_connection.app_password
  }) : local.db_placeholder

  # Placeholder payloads — deliberately empty. No real secret material here.
  db_placeholder = jsonencode({
    username = ""
    password = ""
    engine   = "postgres"
    host     = ""
    port     = 5432
    dbname   = ""
  })

  placeholders = {
    db = local.db_payload
    smtp = jsonencode({
      smtp_username = ""
      smtp_password = ""
      smtp_host     = ""
      smtp_port     = 587
      from_address  = ""
    })
    ad_bind = jsonencode({
      directory_id  = ""
      domain        = ""
      bind_dn       = ""
      bind_password = ""
    })
  }

  secret_defs = {
    db = {
      name        = "${var.name_prefix}/rds/credentials"
      description = "RDS PostgreSQL credentials for the Server Room Inspection Dashboard (placeholder)."
    }
    smtp = {
      name        = "${var.name_prefix}/ses/smtp"
      description = "SES/SMTP credentials for outbound notifications (placeholder)."
    }
    ad_bind = {
      name        = "${var.name_prefix}/ad/bind-account"
      description = "Active Directory bind/service account for AD Connector (placeholder)."
    }
  }
}

resource "aws_secretsmanager_secret" "this" {
  for_each = local.secret_defs

  name        = each.value.name
  description = each.value.description
  kms_key_id  = var.kms_key_arn

  tags = {
    Name   = each.value.name
    Secret = each.key
  }
}

resource "aws_secretsmanager_secret_version" "this" {
  for_each = local.secret_defs

  secret_id     = aws_secretsmanager_secret.this[each.key].id
  secret_string = local.placeholders[each.key]
}
