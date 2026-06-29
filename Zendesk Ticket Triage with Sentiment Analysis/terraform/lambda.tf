data "archive_file" "function" {
  type        = "zip"
  source_file = "${path.module}/../lambda/handler.py"
  output_path = "${path.module}/../lambda/function.zip"
}

resource "aws_lambda_function" "triage" {
  function_name    = "${var.project_name}-function"
  role             = aws_iam_role.lambda_exec.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.11"
  filename         = data.archive_file.function.output_path
  source_code_hash = data.archive_file.function.output_base64sha256
  memory_size      = var.lambda_memory_mb
  timeout          = var.lambda_timeout_seconds

  environment {
    variables = {
      TABLE_NAME                    = aws_dynamodb_table.sentiment.name
      SNS_TOPIC_ARN                 = aws_sns_topic.alerts.arn
      SECRET_ARN                    = aws_secretsmanager_secret.zendesk.arn
      ZENDESK_SUBDOMAIN             = var.zendesk_subdomain
      ZENDESK_ESCALATION_GROUP_ID   = tostring(var.zendesk_escalation_group_id)
      COMPREHEND_LANGUAGE_CODE      = var.comprehend_language_code
      NEGATIVE_CONFIDENCE_THRESHOLD = tostring(var.negative_confidence_threshold)
      POSITIVE_CONFIDENCE_THRESHOLD = tostring(var.positive_confidence_threshold)
    }
  }

  depends_on = [
    aws_iam_role_policy.lambda_logs,
    aws_cloudwatch_log_group.lambda,
  ]

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-function"
  })
}

resource "aws_lambda_permission" "api_gateway" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.triage.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.main.execution_arn}/*/*"
}
