output "appsync_api_url" {
  description = "AppSync GraphQL endpoint URL"
  value       = aws_appsync_graphql_api.todos.uris["GRAPHQL"]
}

output "appsync_api_id" {
  description = "AppSync GraphQL API ID"
  value       = aws_appsync_graphql_api.todos.id
}

output "appsync_api_arn" {
  description = "AppSync GraphQL API ARN"
  value       = aws_appsync_graphql_api.todos.arn
}

output "appsync_api_key" {
  description = "API key for authenticating GraphQL requests"
  value       = aws_appsync_api_key.main.key
  sensitive   = true
}

output "appsync_api_key_id" {
  description = "AppSync API key identifier"
  value       = aws_appsync_api_key.main.id
}

output "dynamodb_table_name" {
  description = "DynamoDB Todos table name"
  value       = aws_dynamodb_table.todos.name
}

output "dynamodb_table_arn" {
  description = "DynamoDB Todos table ARN"
  value       = aws_dynamodb_table.todos.arn
}

output "cloudwatch_log_group" {
  description = "CloudWatch log group for AppSync field-level logs"
  value       = aws_cloudwatch_log_group.appsync.name
}

output "region" {
  description = "AWS region where resources are deployed"
  value       = var.aws_region
}
