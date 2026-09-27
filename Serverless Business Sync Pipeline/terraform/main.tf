data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  name       = "${var.project_name}-${var.environment}" # also the EMF "Service" dimension
  account_id = data.aws_caller_identity.current.account_id

  # Retry gap = visibility timeout. Default 600 + 300 = 900 s (~15 min), see sqs.tf.
  visibility_timeout = coalesce(var.visibility_timeout_seconds, var.lambda_timeout_seconds + 300)

  # All brands (enabled or not) are allowed, so a manual test of a disabled brand still works.
  allowed_portals = join(",", sort(keys(var.portals)))
  metric_ns       = "EbteqdeskBusinessSync"
}

# Secrets Manager containers only. Values are put with the AWS CLI (see README) so they never
# reach tfvars or Terraform state.
resource "aws_secretsmanager_secret" "ebteqdesk" {
  name                    = "${local.name}/ebteqdesk-trigger-token"
  description             = "{\"token\": \"<BUSINESS_SYNC_TRIGGER_TOKEN>\"} - must match Ebteqdesk env"
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret" "telegram" {
  name                    = "${local.name}/telegram"
  description             = "{\"bot_token\": \"...\", \"chat_id\": \"-100...\"}"
  recovery_window_in_days = 7
}
