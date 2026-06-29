# Secrets Manager holds the Zendesk credentials Lambda needs:
#   email                  — Zendesk agent email used for API token (Basic) auth
#   api_token              — Zendesk API token (Admin Center → APIs → Zendesk API)
#   webhook_signing_secret — secret shown when the Zendesk webhook is created; used
#                            by Lambda to verify the HMAC-SHA256 request signature
#
# Terraform seeds a placeholder version only. Update the real values out-of-band so
# secrets never live in Terraform state:
#   aws secretsmanager put-secret-value --secret-id zendesk-triage/zendesk \
#     --secret-string '{"email":"agent@corp.com/token","api_token":"...","webhook_signing_secret":"..."}'

resource "aws_secretsmanager_secret" "zendesk" {
  name        = "${var.project_name}/zendesk"
  description = "Zendesk API token + webhook signing secret for the ticket triage Lambda"

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-zendesk"
  })
}

resource "aws_secretsmanager_secret_version" "zendesk" {
  secret_id = aws_secretsmanager_secret.zendesk.id
  secret_string = jsonencode({
    email                  = "REPLACE_ME@example.com/token"
    api_token              = "REPLACE_ME"
    webhook_signing_secret = "REPLACE_ME"
  })

  lifecycle {
    # Real values are injected via put-secret-value after apply; do not let
    # Terraform overwrite them back to the placeholder on subsequent applies.
    ignore_changes = [secret_string]
  }
}
