output "function_name" {
  description = "Migration Lambda function name."
  value       = aws_lambda_function.this.function_name
}

output "function_arn" {
  description = "Migration Lambda ARN."
  value       = aws_lambda_function.this.arn
}

output "role_arn" {
  description = "Migration Lambda execution role ARN."
  value       = aws_iam_role.this.arn
}

output "log_group_name" {
  description = "Migration Lambda CloudWatch log group."
  value       = aws_cloudwatch_log_group.this.name
}
