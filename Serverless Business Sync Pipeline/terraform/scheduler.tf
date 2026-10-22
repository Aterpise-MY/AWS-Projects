# Scheduler `input` is a heredoc string on purpose. jsonencode() escapes "<" and ">" to
# < / >, and then Scheduler never substitutes the <aws.scheduler.*> context attributes.

# One schedule per brand, weekdays during office hours. Disabled brands keep their schedule
# (state DISABLED), so enabling Warni is a one-line tfvars change.
resource "aws_scheduler_schedule" "sync" {
  for_each = var.portals

  name                         = "${local.name}-sync-${each.key}"
  description                  = "Business Sync ${each.key}: ${each.value.schedule_expression} ${var.schedule_timezone}"
  schedule_expression          = each.value.schedule_expression
  schedule_expression_timezone = var.schedule_timezone
  state                        = each.value.enabled ? "ENABLED" : "DISABLED"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_sqs_queue.trigger.arn
    role_arn = aws_iam_role.scheduler.arn
    input    = <<-EOT
      {"trigger":"eventbridge-scheduler","portal":"${each.key}","scheduled_time":"<aws.scheduler.scheduled-time>","execution_id":"<aws.scheduler.execution-id>","scheduler_attempt":"<aws.scheduler.attempt-number>"}
    EOT

    retry_policy {
      maximum_event_age_in_seconds = 1800 # a sync delivered >30 min late overlaps the next hour
      maximum_retry_attempts       = 5
    }

    dead_letter_config {
      arn = aws_sqs_queue.scheduler_dlq.arn
    }
  }
}

# Daily report, weekdays 18:00 MYT. Lambda templated target (async invoke).
resource "aws_scheduler_schedule" "daily_report" {
  name                         = "${local.name}-daily-report"
  description                  = "Business Sync daily report: ${var.report_schedule_expression} ${var.schedule_timezone}"
  schedule_expression          = var.report_schedule_expression
  schedule_expression_timezone = var.schedule_timezone
  state                        = "ENABLED"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.reporter.arn
    role_arn = aws_iam_role.scheduler.arn
    input    = <<-EOT
      {"trigger":"eventbridge-scheduler","scheduled_time":"<aws.scheduler.scheduled-time>"}
    EOT

    retry_policy {
      maximum_event_age_in_seconds = 3600
      maximum_retry_attempts       = 5
    }

    dead_letter_config {
      arn = aws_sqs_queue.scheduler_dlq.arn
    }
  }
}
