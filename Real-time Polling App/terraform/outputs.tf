output "websocket_url" {
  description = "WebSocket connection URL (wss://). Append ?sessionId=<id> when connecting."
  value       = aws_apigatewayv2_stage.stage.invoke_url
}

output "websocket_management_endpoint" {
  description = "HTTPS endpoint for the API Gateway Management API (PostToConnection)"
  value       = "https://${aws_apigatewayv2_api.websocket.id}.execute-api.${var.aws_region}.amazonaws.com/${var.stage_name}"
}

output "api_id" {
  description = "WebSocket API ID"
  value       = aws_apigatewayv2_api.websocket.id
}

output "stage_name" {
  description = "Deployed stage name"
  value       = aws_apigatewayv2_stage.stage.name
}

output "lambda_function_names" {
  description = "Map of logical name => deployed Lambda function name"
  value       = { for k, fn in aws_lambda_function.fn : k => fn.function_name }
}

output "dynamodb_tables" {
  description = "Names of all DynamoDB tables created"
  value = {
    polls               = aws_dynamodb_table.polls.name
    connections         = aws_dynamodb_table.connections.name
    livestream_sessions = aws_dynamodb_table.livestream_sessions.name
    flashsale_items     = aws_dynamodb_table.flashsale_items.name
    design_surveys      = aws_dynamodb_table.design_surveys.name
  }
}

output "connections_gsi" {
  description = "GSI used for session fan-out"
  value       = "sessionId-index"
}
