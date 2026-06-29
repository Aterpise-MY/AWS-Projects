output "webhook_url" {
  description = "Full URL to register as the Zendesk webhook endpoint (POST)"
  value       = "${aws_api_gateway_stage.v1.invoke_url}/webhook"
}

output "api_base_url" {
  description = "Base invoke URL of the API Gateway v1 stage"
  value       = aws_api_gateway_stage.v1.invoke_url
}

output "dynamodb_table_name" {
  description = "Name of the DynamoDB audit table"
  value       = aws_dynamodb_table.sentiment.name
}

output "dynamodb_table_arn" {
  description = "ARN of the DynamoDB audit table"
  value       = aws_dynamodb_table.sentiment.arn
}

output "lambda_function_name" {
  description = "Name of the triage Lambda function"
  value       = aws_lambda_function.triage.function_name
}

output "lambda_function_arn" {
  description = "ARN of the triage Lambda function"
  value       = aws_lambda_function.triage.arn
}

output "sns_topic_arn" {
  description = "ARN of the negative-sentiment SNS alert topic"
  value       = aws_sns_topic.alerts.arn
}

output "secret_arn" {
  description = "ARN of the Secrets Manager secret holding Zendesk credentials"
  value       = aws_secretsmanager_secret.zendesk.arn
}

output "rest_api_id" {
  description = "ID of the API Gateway REST API"
  value       = aws_api_gateway_rest_api.main.id
}

output "lambda_log_group" {
  description = "CloudWatch log group for Lambda function logs"
  value       = aws_cloudwatch_log_group.lambda.name
}
