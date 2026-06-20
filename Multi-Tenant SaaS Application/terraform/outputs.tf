output "user_pool_id" {
  description = "Cognito User Pool ID"
  value       = aws_cognito_user_pool.main.id
}

output "app_client_id" {
  description = "Cognito App Client ID (used by SPA / mobile to initiate auth)"
  value       = aws_cognito_user_pool_client.main.id
}

output "cognito_hosted_ui_url" {
  description = "Base URL for the Cognito hosted login UI"
  value       = "https://saas-app-prod.auth.${var.region}.amazoncognito.com"
}

output "rds_endpoint" {
  description = "RDS PostgreSQL instance writer endpoint"
  value       = aws_db_instance.main.address
}

output "api_gateway_invoke_url" {
  description = "API Gateway production stage invoke URL (append /users or /orders)"
  value       = aws_api_gateway_stage.prod.invoke_url
}

output "db_secret_arn" {
  description = "ARN of the Secrets Manager secret holding the RDS master password"
  value       = aws_secretsmanager_secret.db_password.arn
}

output "lambda_role_arn" {
  description = "ARN of the IAM role shared by all three Lambda functions"
  value       = aws_iam_role.lambda.arn
}
