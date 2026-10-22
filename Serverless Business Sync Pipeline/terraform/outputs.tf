output "report_bucket" {
  description = "S3 bucket for run reports, failure records, latest.json and daily reports."
  value       = aws_s3_bucket.reports.id
}

output "ebteqdesk_secret_arn" {
  description = "Put {\"token\": \"...\"} here with the AWS CLI."
  value       = aws_secretsmanager_secret.ebteqdesk.arn
}

output "telegram_secret_arn" {
  description = "Put {\"bot_token\": \"...\", \"chat_id\": \"...\"} here with the AWS CLI."
  value       = aws_secretsmanager_secret.telegram.arn
}

output "trigger_queue_url" {
  value = aws_sqs_queue.trigger.url
}

output "sync_dlq_url" {
  value = aws_sqs_queue.sync_dlq.url
}

output "scheduler_dlq_url" {
  value = aws_sqs_queue.scheduler_dlq.url
}

output "report_dlq_url" {
  value = aws_sqs_queue.report_dlq.url
}

output "schedules" {
  description = "Sync schedule per brand with its state."
  value = {
    for k, s in aws_scheduler_schedule.sync : k => {
      name       = s.name
      expression = s.schedule_expression
      state      = s.state
    }
  }
}

output "failure_records_prefix" {
  value = "s3://${aws_s3_bucket.reports.id}/business-sync/failures/"
}

output "cmd_manual_trigger" {
  description = "Per brand: send one sync message now (works for disabled brands too)."
  value = {
    for k in keys(var.portals) : k => "aws sqs send-message --region ${var.aws_region} --queue-url ${aws_sqs_queue.trigger.url} --message-body '{\"trigger\":\"manual\",\"portal\":\"${k}\"}'"
  }
}

output "cmd_tail_logs" {
  value = "aws logs tail ${aws_cloudwatch_log_group.runner.name} --region ${var.aws_region} --follow"
}

output "cmd_latest_report" {
  description = "Per brand: print latest.json (last run + failure streak)."
  value = {
    for k in keys(var.portals) : k => "aws s3 cp s3://${aws_s3_bucket.reports.id}/business-sync/${k}/latest.json -"
  }
}

output "cmd_redrive_dlq" {
  description = "Move sync DLQ messages back to the trigger queue."
  value       = "aws sqs start-message-move-task --region ${var.aws_region} --source-arn ${aws_sqs_queue.sync_dlq.arn} --destination-arn ${aws_sqs_queue.trigger.arn}"
}

output "cmd_run_report" {
  description = "Re-run or backfill a daily report. Replace the date."
  value       = "aws lambda invoke --region ${var.aws_region} --function-name ${aws_lambda_function.reporter.function_name} --cli-binary-format raw-in-base64-out --payload '{\"report_date\":\"YYYY-MM-DD\"}' /dev/stdout"
}

output "cmd_daily_report" {
  description = "List a day's report files. Replace the date path."
  value       = "aws s3 ls s3://${aws_s3_bucket.reports.id}/business-sync/daily-reports/YYYY/MM/DD/"
}
