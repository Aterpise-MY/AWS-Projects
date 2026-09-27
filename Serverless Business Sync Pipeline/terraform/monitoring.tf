# CloudWatch alarm -> SNS -> notifier Lambda -> Telegram.
# SNS is left unencrypted: CloudWatch cannot publish to a topic encrypted with the AWS-managed
# alias/aws/sns key, and CMKs are out of scope. Alarm messages carry no secrets.
resource "aws_sns_topic" "alerts" {
  name = "${local.name}-alerts"
}

data "aws_iam_policy_document" "alerts_topic" {
  statement {
    sid       = "AllowCloudWatchAlarms"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]
    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_sns_topic_policy" "alerts" {
  arn    = aws_sns_topic.alerts.arn
  policy = data.aws_iam_policy_document.alerts_topic.json
}

locals {
  dlq_alarms = {
    "sync-dlq-not-empty"      = { queue = aws_sqs_queue.sync_dlq.name, desc = "Sync DLQ 有消息：某个 brand 的 sync 两次尝试都失败。修好后 redrive（见 README Runbook）。" }
    "scheduler-dlq-not-empty" = { queue = aws_sqs_queue.scheduler_dlq.name, desc = "Scheduler DLQ 有消息：Scheduler 连触发都失败（IAM / queue / Lambda drift）。用 terraform plan 查 drift。" }
    "report-dlq-not-empty"    = { queue = aws_sqs_queue.report_dlq.name, desc = "Report DLQ 有消息：18:00 日报 Lambda 重试 2 次仍失败。手动重跑日报（见 README Runbook）。" }
  }
}

resource "aws_cloudwatch_metric_alarm" "dlq" {
  for_each = local.dlq_alarms

  alarm_name          = "${local.name}-${each.key}"
  alarm_description   = each.value.desc
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = each.value.queue }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

# Replaces the old 28 h heartbeat (which would fire every weekend). The 18:00 report is the daily
# health check; this alarm watches the reporter itself. 74 hourly datapoints = Fri 18:00 -> Mon
# 18:00 (72 h) + 2 h slack. 74 x 3600 s = 266,400 s, inside CloudWatch's 7-day (604,800 s) limit
# for alarms with a period of at least one hour.
resource "aws_cloudwatch_metric_alarm" "report_not_generated" {
  alarm_name          = "${local.name}-daily-report-missing"
  alarm_description   = "${var.report_alarm_hours} 小时内没有产生 Business Sync 日报（ReportGenerated）。检查 reporter Lambda、daily-report schedule 与 report DLQ。"
  namespace           = local.metric_ns
  metric_name         = "ReportGenerated"
  dimensions          = { Service = local.name }
  statistic           = "Sum"
  period              = 3600
  evaluation_periods  = var.report_alarm_hours
  datapoints_to_alarm = var.report_alarm_hours
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}
