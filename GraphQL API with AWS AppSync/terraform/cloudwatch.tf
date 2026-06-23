resource "aws_cloudwatch_log_group" "appsync" {
  name              = "/aws/appsync/apis/${aws_appsync_graphql_api.todos.id}"
  retention_in_days = var.cloudwatch_retention_days

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-appsync-logs"
  })
}

resource "aws_cloudwatch_metric_alarm" "appsync_5xx" {
  alarm_name          = "${var.project_name}-5xx-errors"
  alarm_description   = "AppSync 5XX server-side error rate exceeds threshold"
  namespace           = "AWS/AppSync"
  metric_name         = "5XXError"
  comparison_operator = "GreaterThanThreshold"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = var.alarm_5xx_threshold
  treat_missing_data  = "notBreaching"

  dimensions = {
    GraphQLAPIId = aws_appsync_graphql_api.todos.id
  }

  tags = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "appsync_4xx" {
  alarm_name          = "${var.project_name}-4xx-errors"
  alarm_description   = "AppSync 4XX client-side error rate exceeds threshold"
  namespace           = "AWS/AppSync"
  metric_name         = "4XXError"
  comparison_operator = "GreaterThanThreshold"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = var.alarm_4xx_threshold
  treat_missing_data  = "notBreaching"

  dimensions = {
    GraphQLAPIId = aws_appsync_graphql_api.todos.id
  }

  tags = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "appsync_latency" {
  alarm_name          = "${var.project_name}-high-latency"
  alarm_description   = "AppSync p99 latency exceeds ${var.alarm_latency_p99_ms}ms over 3 consecutive minutes"
  namespace           = "AWS/AppSync"
  metric_name         = "Latency"
  comparison_operator = "GreaterThanThreshold"
  extended_statistic  = "p99"
  period              = 60
  evaluation_periods  = 3
  threshold           = var.alarm_latency_p99_ms
  treat_missing_data  = "notBreaching"

  dimensions = {
    GraphQLAPIId = aws_appsync_graphql_api.todos.id
  }

  tags = local.common_tags
}
