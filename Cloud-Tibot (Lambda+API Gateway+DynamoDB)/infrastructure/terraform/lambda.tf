/**
 * Project CORTEX - Lambda Functions Configuration
 * 
 * Defines three Lambda functions for the ChatOps system:
 * - Auto-Remediator: Handles Amplify build failure notifications
 * - Git Radar: Processes GitHub webhook events and updates dashboard
 * - FinOps Sentinel: Monitors and reports on cost optimization
 */

# -----------------------------------------------------------------------------
# Function A: Auto-Remediator (Module 1)
# Triggered by EventBridge on Amplify build failures
# -----------------------------------------------------------------------------

data "archive_file" "lambda_auto_remediator" {
  type        = "zip"
  source_dir  = "${path.module}/../../src/module1"
  output_path = "${path.module}/.terraform/archives/module1.zip"
}

resource "aws_lambda_function" "auto_remediator" {
  filename         = data.archive_file.lambda_auto_remediator.output_path
  function_name    = "${var.project_name}_auto_remediator"
  role             = aws_iam_role.lambda_auto_remediator.arn
  handler          = "lambda_function.lambda_handler"
  source_code_hash = data.archive_file.lambda_auto_remediator.output_base64sha256
  runtime          = var.lambda_runtime
  timeout          = var.lambda_timeout
  memory_size      = var.lambda_memory_size

  environment {
    variables = {
      TELEGRAM_TOKEN    = var.telegram_token
      TELEGRAM_CHAT_ID  = var.telegram_chat_id
      TELEGRAM_TOPIC_ID = var.telegram_topic_auto_remediator
      PROJECT_NAME      = var.project_name
      AMPLIFY_REGION    = var.amplify_region
    }
  }

  tags = {
    Name   = "${var.project_name}-auto-remediator"
    Module = "AutoRemediator"
  }
}

# CloudWatch Log Group for Function A
resource "aws_cloudwatch_log_group" "auto_remediator" {
  name              = "/aws/lambda/${aws_lambda_function.auto_remediator.function_name}"
  retention_in_days = 14

  tags = {
    Name   = "${var.project_name}-auto-remediator-logs"
    Module = "AutoRemediator"
  }
}

# -----------------------------------------------------------------------------
# Function B: Git Radar (Module 2)
# Triggered by API Gateway webhook from GitHub
# -----------------------------------------------------------------------------

data "archive_file" "lambda_git_radar" {
  type        = "zip"
  source_dir  = "${path.module}/../../src/module2"
  output_path = "${path.module}/.terraform/archives/module2.zip"
}

resource "aws_lambda_function" "git_radar" {
  filename         = data.archive_file.lambda_git_radar.output_path
  function_name    = "${var.project_name}_git_radar"
  role             = aws_iam_role.lambda_git_radar.arn
  handler          = "lambda_function.lambda_handler"
  source_code_hash = data.archive_file.lambda_git_radar.output_base64sha256
  runtime          = var.lambda_runtime
  timeout          = var.lambda_timeout
  memory_size      = var.lambda_memory_size

  environment {
    variables = {
      TELEGRAM_TOKEN                  = var.telegram_token
      TELEGRAM_CHAT_ID                = var.telegram_chat_id
      TELEGRAM_TOPIC_ID               = var.telegram_topic_git_radar
      TELEGRAM_TOPIC_GUARDIAN_ALERT   = var.telegram_topic_guardian_alert
      GITHUB_APP_ID                   = var.github_app_id
      GITHUB_APP_INSTALLATION_ID      = var.github_app_installation_id
      GITHUB_APP_PRIVATE_KEY          = var.github_app_private_key
      GITHUB_REPO_OWNER               = var.github_repo_owner
      GITHUB_REPO_NAME                = var.github_repo_name
      DYNAMODB_TABLE                  = aws_dynamodb_table.cortex_radar_state.name
      PROJECT_NAME                    = var.project_name
    }
  }

  tags = {
    Name   = "${var.project_name}-git-radar"
    Module = "GitRadar"
  }
}

# CloudWatch Log Group for Function B
resource "aws_cloudwatch_log_group" "git_radar" {
  name              = "/aws/lambda/${aws_lambda_function.git_radar.function_name}"
  retention_in_days = 14

  tags = {
    Name   = "${var.project_name}-git-radar-logs"
    Module = "GitRadar"
  }
}

# Grant API Gateway permission to invoke Function B
resource "aws_lambda_permission" "git_radar_apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.git_radar.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.cortex_api.execution_arn}/*/*"
}

# -----------------------------------------------------------------------------
# Function C: FinOps Sentinel (Module 3)
# Triggered by API Gateway webhook for cost notifications
# -----------------------------------------------------------------------------

data "archive_file" "lambda_finops_sentinel" {
  type        = "zip"
  source_dir  = "${path.module}/../../src/module3/build/package"
  output_path = "${path.module}/.terraform/archives/module3.zip"
}

resource "aws_lambda_function" "finops_sentinel" {
  filename         = data.archive_file.lambda_finops_sentinel.output_path
  function_name    = "${var.project_name}_finops_sentinel"
  role             = aws_iam_role.lambda_finops_sentinel.arn
  handler          = "lambda_function.lambda_handler"
  source_code_hash = data.archive_file.lambda_finops_sentinel.output_base64sha256
  runtime          = var.lambda_runtime
  timeout          = var.lambda_timeout
  memory_size      = var.lambda_memory_size

  environment {
    variables = {
      TELEGRAM_TOKEN              = var.telegram_token
      TELEGRAM_CHAT_ID            = var.telegram_chat_id
      TELEGRAM_TOPIC_ID           = var.telegram_topic_finops_sentinel
      GITHUB_APP_ID               = var.github_app_id
      GITHUB_APP_INSTALLATION_ID  = var.github_app_installation_id
      GITHUB_APP_PRIVATE_KEY      = var.github_app_private_key
      GITHUB_REPO_OWNER           = var.github_repo_owner
      GITHUB_REPO_NAME            = var.github_repo_name
      PROJECT_NAME                = var.project_name
    }
  }

  tags = {
    Name   = "${var.project_name}-finops-sentinel"
    Module = "FinOpsSentinel"
  }
}

# Grant EventBridge permission to invoke FinOps Sentinel (daily schedule)
resource "aws_lambda_permission" "finops_sentinel_eventbridge_daily" {
  statement_id  = "AllowEventBridgeDailyFinOps"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.finops_sentinel.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.finops_daily_report.arn
}

# Grant EventBridge permission to invoke FinOps Sentinel (weekly schedule)
resource "aws_lambda_permission" "finops_sentinel_eventbridge_weekly" {
  statement_id  = "AllowEventBridgeWeeklyFinOps"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.finops_sentinel.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.finops_weekly_report.arn
}

# CloudWatch Log Group for Function C
resource "aws_cloudwatch_log_group" "finops_sentinel" {
  name              = "/aws/lambda/${aws_lambda_function.finops_sentinel.function_name}"
  retention_in_days = 14

  tags = {
    Name   = "${var.project_name}-finops-sentinel-logs"
    Module = "FinOpsSentinel"
  }
}

# Grant API Gateway permission to invoke Function C
resource "aws_lambda_permission" "finops_sentinel_apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.finops_sentinel.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.cortex_api.execution_arn}/*/*"
}
