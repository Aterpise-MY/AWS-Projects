output "dashboard_name" {
  description = "CloudWatch dashboard name."
  value       = aws_cloudwatch_dashboard.this.dashboard_name
}

output "sns_topic_arn" {
  description = "Alarms SNS topic ARN."
  value       = aws_sns_topic.alarms.arn
}

output "ad_connector_id" {
  description = "AD Connector directory ID (null when disabled)."
  value       = try(aws_directory_service_directory.ad_connector[0].id, null)
}
