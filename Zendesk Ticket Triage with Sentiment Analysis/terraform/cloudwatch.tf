resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${var.project_name}-function"
  retention_in_days = var.cloudwatch_retention_days

  tags = local.common_tags
}

resource "aws_cloudwatch_log_group" "api_gateway" {
  name              = "/aws/apigateway/${var.project_name}"
  retention_in_days = var.cloudwatch_retention_days

  tags = local.common_tags
}

# ── Alarms ────────────────────────────────────────────────────────────────────

resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = "${var.project_name}-lambda-errors"
  alarm_description   = "Triage Lambda errors exceed threshold"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 60
  statistic           = "Sum"
  threshold           = var.alarm_lambda_error_threshold
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    FunctionName = aws_lambda_function.triage.function_name
  }

  tags = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "api_5xx" {
  alarm_name          = "${var.project_name}-api-5xx"
  alarm_description   = "API Gateway 5XX errors exceed threshold"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "5XXError"
  namespace           = "AWS/ApiGateway"
  period              = 60
  statistic           = "Sum"
  threshold           = var.alarm_api_5xx_threshold
  treat_missing_data  = "notBreaching"

  dimensions = {
    ApiName = aws_api_gateway_rest_api.main.name
    Stage   = aws_api_gateway_stage.v1.stage_name
  }

  tags = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "api_4xx" {
  alarm_name          = "${var.project_name}-api-4xx"
  alarm_description   = "API Gateway 4XX errors exceed threshold — sustained 4XX may indicate failed HMAC verification or webhook misconfiguration"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "4XXError"
  namespace           = "AWS/ApiGateway"
  period              = 60
  statistic           = "Sum"
  threshold           = var.alarm_api_4xx_threshold
  treat_missing_data  = "notBreaching"

  dimensions = {
    ApiName = aws_api_gateway_rest_api.main.name
    Stage   = aws_api_gateway_stage.v1.stage_name
  }

  tags = local.common_tags
}
