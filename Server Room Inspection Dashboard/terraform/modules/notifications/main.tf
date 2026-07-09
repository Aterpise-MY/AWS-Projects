# ===========================================================================
# notifications module — Phase 5 breach alerting (SES + EventBridge + Lambda).
# ---------------------------------------------------------------------------
# On a schedule (after each AM/PM shift) an in-VPC Lambda queries
# srid.v_flagged_records and emails a breach digest via SES.
#
# GATED: every active resource is count/for_each-gated on enable_notifications
# (default false) so plan/apply is clean out of the box — SES requires verified
# sender/recipient identities and (in sandbox) verified recipients, which are
# real artifacts that cannot be created purely in Terraform. Turn on only once
# those identities are verified.
# ===========================================================================

locals {
  # Identities to register in SES: the sender plus every recipient (sandbox
  # requires recipients verified too). Empty unless the module is enabled.
  ses_identities = var.enable_notifications ? distinct(compact(concat([var.sender_email], var.recipient_emails))) : []

  # Prefer a caller-supplied zip; otherwise use the self-contained stub.
  notifier_zip = var.notifier_package_path != "" ? var.notifier_package_path : data.archive_file.notifier.output_path
}

# Self-contained deployment package built from ./src/handler.py — no external
# artifact required. This data source is cheap and always evaluates; it is only
# referenced by the (gated) Lambda.
data "archive_file" "notifier" {
  type        = "zip"
  source_file = "${path.module}/src/handler.py"
  output_path = "${path.module}/dist/notifier.zip"
}

# ------------------------------- SES ---------------------------------------
resource "aws_ses_configuration_set" "this" {
  count = var.enable_notifications ? 1 : 0
  name  = "${var.name_prefix}-notifications"
}

resource "aws_ses_email_identity" "this" {
  for_each = toset(local.ses_identities)
  email    = each.value
}

# ------------------------------ Notifier Lambda ----------------------------
resource "aws_lambda_function" "notifier" {
  count            = var.enable_notifications ? 1 : 0
  function_name    = "${var.name_prefix}-breach-notifier"
  description      = "Emails a breach digest from srid.v_flagged_records after each shift."
  role             = var.lambda_execution_role_arn
  runtime          = "python3.12"
  handler          = "handler.handler"
  architectures    = ["x86_64"]
  timeout          = 60
  memory_size      = 256
  filename         = local.notifier_zip
  source_code_hash = data.archive_file.notifier.output_base64sha256

  vpc_config {
    subnet_ids         = var.subnet_ids
    security_group_ids = var.security_group_ids
  }

  environment {
    variables = {
      DB_SECRET_ARN    = var.db_secret_arn
      SENDER_EMAIL     = var.sender_email
      RECIPIENT_EMAILS = join(",", var.recipient_emails)
      REGION           = var.region
    }
  }

  tags = { Name = "${var.name_prefix}-breach-notifier" }
}

# ---------------------------- EventBridge schedule -------------------------
resource "aws_cloudwatch_event_rule" "schedule" {
  count               = var.enable_notifications ? 1 : 0
  name                = "${var.name_prefix}-breach-notify"
  description         = "Triggers the breach-notifier Lambda after the AM/PM shifts."
  schedule_expression = var.schedule_expression
}

resource "aws_cloudwatch_event_target" "lambda" {
  count     = var.enable_notifications ? 1 : 0
  rule      = aws_cloudwatch_event_rule.schedule[0].name
  target_id = "breach-notifier"
  arn       = aws_lambda_function.notifier[0].arn
}

resource "aws_lambda_permission" "events" {
  count         = var.enable_notifications ? 1 : 0
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.notifier[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.schedule[0].arn
}

# ------------------------------- IAM (inline) ------------------------------
data "aws_iam_policy_document" "notifier" {
  statement {
    sid       = "SendEmail"
    effect    = "Allow"
    actions   = ["ses:SendEmail", "ses:SendRawEmail"]
    resources = ["*"]
  }

  statement {
    sid       = "ReadDbSecret"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [var.db_secret_arn]
  }

  statement {
    sid       = "DecryptSecret"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = [var.kms_key_arn]
  }
}

resource "aws_iam_role_policy" "notifier" {
  count  = var.enable_notifications ? 1 : 0
  name   = "${var.name_prefix}-breach-notifier-inline"
  role   = var.lambda_execution_role_name
  policy = data.aws_iam_policy_document.notifier.json
}
