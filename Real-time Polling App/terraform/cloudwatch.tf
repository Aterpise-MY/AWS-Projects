# ── Log groups ────────────────────────────────────────────────────────────────

resource "aws_cloudwatch_log_group" "lambda" {
  for_each = local.functions

  name              = "/aws/lambda/${var.project_name}-${each.key}"
  retention_in_days = var.cloudwatch_retention_days

  tags = local.common_tags
}

resource "aws_cloudwatch_log_group" "access_logs" {
  name              = "/aws/apigateway/${var.project_name}-ws"
  retention_in_days = var.cloudwatch_retention_days

  tags = local.common_tags
}

# ── Alarms ────────────────────────────────────────────────────────────────────

# Per-function Lambda error alarm.
resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  for_each = local.functions

  alarm_name          = "${var.project_name}-${each.key}-errors"
  alarm_description   = "Lambda ${each.key} errors exceed threshold"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 60
  statistic           = "Sum"
  threshold           = var.alarm_lambda_error_threshold
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.fn[each.key].function_name
  }

  tags = local.common_tags
}

# WebSocket API integration errors across the stage.
resource "aws_cloudwatch_metric_alarm" "integration_errors" {
  alarm_name          = "${var.project_name}-ws-integration-errors"
  alarm_description   = "WebSocket API integration errors exceed threshold"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "IntegrationError"
  namespace           = "AWS/ApiGateway"
  period              = 60
  statistic           = "Sum"
  threshold           = var.alarm_integration_error_threshold
  treat_missing_data  = "notBreaching"

  dimensions = {
    ApiId = aws_apigatewayv2_api.websocket.id
    Stage = var.stage_name
  }

  tags = local.common_tags
}
