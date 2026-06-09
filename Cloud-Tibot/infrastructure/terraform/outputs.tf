/**
 * Project CORTEX - Terraform Outputs
 * 
 * Exposes important resource identifiers and endpoints
 * for integration with CI/CD pipelines and external systems.
 */

output "api_gateway_endpoint" {
  description = "Base URL of the API Gateway for webhook integrations"
  value       = aws_apigatewayv2_api.cortex_api.api_endpoint
}

output "github_webhook_url" {
  description = "Full URL for GitHub webhook configuration"
  value       = "${aws_apigatewayv2_api.cortex_api.api_endpoint}/webhook/github"
}

output "finops_webhook_url" {
  description = "Full URL for FinOps webhook configuration"
  value       = "${aws_apigatewayv2_api.cortex_api.api_endpoint}/webhook/finops"
}

output "dynamodb_table_name" {
  description = "DynamoDB table name for radar state storage"
  value       = aws_dynamodb_table.cortex_radar_state.name
}

output "lambda_function_names" {
  description = "Names of deployed Lambda functions"
  value = {
    auto_remediator  = aws_lambda_function.auto_remediator.function_name
    git_radar        = aws_lambda_function.git_radar.function_name
    finops_sentinel  = aws_lambda_function.finops_sentinel.function_name
  }
}

output "eventbridge_rule_name" {
  description = "EventBridge rule name for Amplify monitoring"
  value       = aws_cloudwatch_event_rule.amplify_build_status.name
}

output "cloudwatch_log_groups" {
  description = "CloudWatch Log Group names for Lambda functions"
  value = {
    auto_remediator  = aws_cloudwatch_log_group.auto_remediator.name
    git_radar        = aws_cloudwatch_log_group.git_radar.name
    finops_sentinel  = aws_cloudwatch_log_group.finops_sentinel.name
    api_gateway      = aws_cloudwatch_log_group.api_gateway.name
  }
}
