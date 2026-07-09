output "notifier_lambda_name" {
  description = "Breach-notifier Lambda name (null when notifications disabled)."
  value       = try(aws_lambda_function.notifier[0].function_name, null)
}

output "ses_configuration_set" {
  description = "SES configuration set name (null when notifications disabled)."
  value       = try(aws_ses_configuration_set.this[0].name, null)
}

output "schedule_rule_name" {
  description = "EventBridge schedule rule name (null when notifications disabled)."
  value       = try(aws_cloudwatch_event_rule.schedule[0].name, null)
}
