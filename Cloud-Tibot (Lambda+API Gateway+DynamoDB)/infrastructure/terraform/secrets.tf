/**
 * Project CORTEX — Secrets Manager Resources (Telegram Approval Handler)
 *
 * Creates the secret entries only — values must be populated manually
 * via AWS Console or CLI after running terraform apply.
 *
 *   aws secretsmanager put-secret-value \
 *     --secret-id /cortex-infra/telegram-bot-token \
 *     --secret-string "YOUR_BOT_TOKEN"
 *
 * Never commit secret values to the repository.
 */

resource "aws_secretsmanager_secret" "telegram_bot_token" {
  name        = "/cortex-infra/telegram-bot-token"
  description = "Telegram Bot API token for cortex-telegram-approval-handler"

  tags = {
    Name   = "${var.project_name}-telegram-bot-token"
    Module = "TelegramApprovalHandler"
  }
}

resource "aws_secretsmanager_secret" "telegram_bot_secret_token" {
  name        = "/cortex-infra/telegram-bot-secret-token"
  description = "Webhook X-Telegram-Bot-Api-Secret-Token header validation value"

  tags = {
    Name   = "${var.project_name}-telegram-bot-secret-token"
    Module = "TelegramApprovalHandler"
  }
}

resource "aws_secretsmanager_secret" "github_app_token" {
  name        = "/cortex-infra/github-app-token"
  description = "GitHub PAT or App private key for triggering repository_dispatch events"

  tags = {
    Name   = "${var.project_name}-github-app-token"
    Module = "TelegramApprovalHandler"
  }
}
