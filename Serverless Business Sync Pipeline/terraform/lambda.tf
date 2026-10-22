data "archive_file" "lambda" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda"
  output_path = "${path.module}/.build/lambda.zip"
  excludes = [
    "tests",
    "tests/**",
    "__pycache__",
    "__pycache__/**",
    "**/__pycache__/**",
    ".pytest_cache/**",
  ]
}

# ---------------------------------------------------------------- runner

resource "aws_cloudwatch_log_group" "runner" {
  name              = "/aws/lambda/${local.name}-runner"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "runner" {
  function_name    = "${local.name}-runner"
  role             = aws_iam_role.runner.arn
  runtime          = "python3.13"
  architectures    = ["arm64"]
  handler          = "handler.lambda_handler"
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256
  timeout          = var.lambda_timeout_seconds
  memory_size      = 256

  environment {
    variables = {
      REPORT_BUCKET              = aws_s3_bucket.reports.id
      SERVICE_NAME               = local.name
      ALLOWED_PORTALS            = local.allowed_portals
      EBTEQDESK_BASE_URL         = var.ebteqdesk_base_url
      EBTEQDESK_SECRET_ARN       = aws_secretsmanager_secret.ebteqdesk.arn
      TELEGRAM_SECRET_ARN        = aws_secretsmanager_secret.telegram.arn
      MAX_RECEIVE_COUNT          = tostring(var.max_receive_count)
      ALERT_EVERY_N_FAILURES     = tostring(var.alert_every_n_failures)
      TELEGRAM_NOTIFY_ON_SUCCESS = tostring(var.telegram_notify_on_success)
      POLL_INTERVAL_SECONDS      = tostring(var.poll_interval_seconds)
    }
  }

  depends_on = [aws_cloudwatch_log_group.runner]
}

resource "aws_lambda_event_source_mapping" "runner" {
  event_source_arn = aws_sqs_queue.trigger.arn
  function_name    = aws_lambda_function.runner.arn
  batch_size       = 1 # one brand-sync per invocation; a failure retries only that message

  scaling_config {
    maximum_concurrency = var.runner_max_concurrency
  }
}

# ---------------------------------------------------------------- notifier (CloudWatch alarm -> Telegram)

resource "aws_cloudwatch_log_group" "notifier" {
  name              = "/aws/lambda/${local.name}-notifier"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "notifier" {
  function_name    = "${local.name}-notifier"
  role             = aws_iam_role.notifier.arn
  runtime          = "python3.13"
  architectures    = ["arm64"]
  handler          = "notifier.lambda_handler"
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256
  timeout          = 30
  memory_size      = 128

  environment {
    variables = {
      TELEGRAM_SECRET_ARN = aws_secretsmanager_secret.telegram.arn
    }
  }

  depends_on = [aws_cloudwatch_log_group.notifier]
}

resource "aws_lambda_permission" "notifier_sns" {
  statement_id  = "AllowSNSInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.notifier.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.alerts.arn
}

resource "aws_sns_topic_subscription" "notifier" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.notifier.arn
}

# ---------------------------------------------------------------- reporter (weekday 18:00 daily report)

resource "aws_cloudwatch_log_group" "reporter" {
  name              = "/aws/lambda/${local.name}-reporter"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "reporter" {
  function_name    = "${local.name}-reporter"
  role             = aws_iam_role.reporter.arn
  runtime          = "python3.13"
  architectures    = ["arm64"]
  handler          = "reporter.lambda_handler"
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256
  timeout          = 120
  memory_size      = 256

  environment {
    variables = {
      REPORT_BUCKET       = aws_s3_bucket.reports.id
      SERVICE_NAME        = local.name
      ALLOWED_PORTALS     = local.allowed_portals
      PORTALS_JSON        = jsonencode(var.portals)
      SYNC_DLQ_URL        = aws_sqs_queue.sync_dlq.url
      SCHEDULER_DLQ_URL   = aws_sqs_queue.scheduler_dlq.url
      TELEGRAM_SECRET_ARN = aws_secretsmanager_secret.telegram.arn
    }
  }

  depends_on = [aws_cloudwatch_log_group.reporter]
}

# Scheduler invokes asynchronously: 2 Lambda retries, then the report DLQ (+ alarm).
resource "aws_lambda_function_event_invoke_config" "reporter" {
  function_name                = aws_lambda_function.reporter.function_name
  maximum_retry_attempts       = 2
  maximum_event_age_in_seconds = 3600

  destination_config {
    on_failure {
      destination = aws_sqs_queue.report_dlq.arn
    }
  }
}
