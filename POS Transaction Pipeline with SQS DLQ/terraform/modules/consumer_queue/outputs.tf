###############################################################################
# module "consumer_queue" — outputs
###############################################################################

output "source_queue_url" {
  description = "URL of the source queue, e.g. for `aws sqs send-message` / `get-queue-attributes`."
  value       = aws_sqs_queue.source.id
}

output "source_queue_arn" {
  description = "ARN of the source queue. Used as the `--destination-arn` of a redrive task."
  value       = aws_sqs_queue.source.arn
}

output "source_queue_name" {
  description = "Name of the source queue, e.g. `pos-loyalty-queue`."
  value       = aws_sqs_queue.source.name
}

output "dlq_url" {
  description = "URL of the dead-letter queue."
  value       = aws_sqs_queue.dlq.id
}

output "dlq_arn" {
  description = "ARN of the dead-letter queue. Used as the `--source-arn` of a redrive task."
  value       = aws_sqs_queue.dlq.arn
}

output "dlq_name" {
  description = "Name of the dead-letter queue, e.g. `pos-loyalty-dlq`."
  value       = aws_sqs_queue.dlq.name
}

output "lambda_function_name" {
  description = "Name of the consumer Lambda function, e.g. `pos-loyalty-fn`."
  value       = aws_lambda_function.this.function_name
}

output "lambda_function_arn" {
  description = "ARN of the consumer Lambda function."
  value       = aws_lambda_function.this.arn
}

output "lambda_log_group_name" {
  description = "CloudWatch Logs group for the consumer, for Logs Insights traceability queries (R5)."
  value       = aws_cloudwatch_log_group.lambda.name
}

output "alarm_names" {
  description = "Names of the two CloudWatch alarms watching this lane's DLQ."
  value = [
    aws_cloudwatch_metric_alarm.dlq_not_empty.alarm_name,
    aws_cloudwatch_metric_alarm.dlq_message_aging.alarm_name,
  ]
}
