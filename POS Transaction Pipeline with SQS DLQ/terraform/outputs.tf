###############################################################################
# Outputs
###############################################################################

output "pos_transactions_topic_arn" {
  description = "ARN of the `pos-transactions` SNS topic. `scripts/pos_simulator.py` publishes here."
  value       = aws_sns_topic.pos_transactions.arn
}

output "ops_alerts_topic_arn" {
  description = "ARN of the `pos-ops-alerts` SNS topic that receives every DLQ alarm action."
  value       = aws_sns_topic.ops_alerts.arn
}

output "ops_alert_email_subscription_pending" {
  description = "True when an email subscription was created and still needs to be confirmed from the inbox before alarms will be delivered (R3)."
  value       = length(aws_sns_topic_subscription.ops_alerts_email) > 0
}

output "sns_delivery_dlq_url" {
  description = "URL of `pos-sns-delivery-dlq`, the subscription-level DLQ that catches SNS-layer delivery failures (TC-07)."
  value       = aws_sqs_queue.sns_delivery_dlq.id
}

output "sns_delivery_dlq_arn" {
  description = "ARN of `pos-sns-delivery-dlq`."
  value       = aws_sqs_queue.sns_delivery_dlq.arn
}

output "dlq_archive_bucket" {
  description = "Name of the S3 bucket that poison messages are archived into before deletion (runbook Path B). Written by a human operator with their own credentials; the consumer Lambda roles have no access to it."
  value       = aws_s3_bucket.dlq_archive.id
}

output "idempotency_table_name" {
  description = "Name of the DynamoDB idempotency table. Consumers read this from the IDEMPOTENCY_TABLE environment variable."
  value       = aws_dynamodb_table.processed_transactions.name
}

output "idempotency_table_arn" {
  description = "ARN of the DynamoDB idempotency table."
  value       = aws_dynamodb_table.processed_transactions.arn
}

output "idempotency_ttl_days" {
  description = "TTL horizon in days that consumers should write into the `expires_at` attribute."
  value       = var.idempotency_ttl_days
}

output "dashboard_name" {
  description = "Name of the CloudWatch dashboard covering all three lanes."
  value       = aws_cloudwatch_dashboard.pipeline.dashboard_name
}

output "dashboard_url" {
  description = "Console deep link to the pipeline dashboard."
  value       = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=${aws_cloudwatch_dashboard.pipeline.dashboard_name}"
}

###############################################################################
# Per-service map, built from the three module instances so adding a fourth
# lane means adding one entry to `local.consumers` and nothing here.
###############################################################################

output "consumers" {
  description = "Per-service map of source queue URL, DLQ URL, Lambda function name, log group and alarm names."
  value = {
    for name, consumer in local.consumers : name => {
      source_queue_url     = consumer.source_queue_url
      source_queue_arn     = consumer.source_queue_arn
      source_queue_name    = consumer.source_queue_name
      dlq_url              = consumer.dlq_url
      dlq_arn              = consumer.dlq_arn
      dlq_name             = consumer.dlq_name
      lambda_function_name = consumer.lambda_function_name
      lambda_log_group     = consumer.lambda_log_group_name
      alarm_names          = consumer.alarm_names
    }
  }
}

###############################################################################
# Ready-to-paste redrive commands (Phase 5).
#
# `start-message-move-task` moves messages from a DLQ back to their original
# source queue. The destination ARN is given explicitly here for clarity, even
# though SQS defaults to the original source when it is omitted.
#
# --max-number-of-messages-per-second 10 is not optional politeness: an
# unthrottled redrive of a large backlog will slam the downstream dependency
# that just recovered and knock it straight back over.
#
# Redrive only makes sense for TRANSIENT failures. Redriving poison messages
# sends them on another full lap of the retry window before they land back in
# the same DLQ, having burned maxReceiveCount invocations for nothing.
###############################################################################

output "redrive_commands" {
  description = "Per-service `aws sqs start-message-move-task` command, rate-limited to 10 messages/second. Only run these after the underlying transient failure is fixed."
  value = {
    for name, consumer in local.consumers : name => join(" ", [
      "aws sqs start-message-move-task",
      "--source-arn ${consumer.dlq_arn}",
      "--destination-arn ${consumer.source_queue_arn}",
      "--max-number-of-messages-per-second 10",
      "--region ${var.aws_region}",
    ])
  }
}

output "redrive_status_commands" {
  description = "Per-service `aws sqs list-message-move-tasks` command for tracking redrive progress."
  value = {
    for name, consumer in local.consumers : name => join(" ", [
      "aws sqs list-message-move-tasks",
      "--source-arn ${consumer.dlq_arn}",
      "--max-results 5",
      "--region ${var.aws_region}",
    ])
  }
}

output "dlq_depth_commands" {
  description = "Per-service `aws sqs get-queue-attributes` command for reading current DLQ depth during a drill."
  value = {
    for name, consumer in local.consumers : name => join(" ", [
      "aws sqs get-queue-attributes",
      "--queue-url ${consumer.dlq_url}",
      "--attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible",
      "--region ${var.aws_region}",
    ])
  }
}

output "account_id" {
  description = "AWS account the stack is deployed into. A DLQ must be in the same account and region as its source queue."
  value       = data.aws_caller_identity.current.account_id
}

output "region" {
  description = "AWS region the stack is deployed into."
  value       = var.aws_region
}
