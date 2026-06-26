output "api_base_url" {
  description = "Base URL of the API Gateway stage — append /shorten, /redirect, or /stats"
  value       = aws_api_gateway_stage.v1.invoke_url
}

output "shorten_endpoint" {
  description = "POST endpoint to create a short link"
  value       = "${aws_api_gateway_stage.v1.invoke_url}/shorten"
}

output "redirect_endpoint" {
  description = "GET endpoint to follow a short link — append ?short_code=<code>"
  value       = "${aws_api_gateway_stage.v1.invoke_url}/redirect"
}

output "stats_endpoint" {
  description = "GET endpoint to retrieve click statistics — append ?short_code=<code>"
  value       = "${aws_api_gateway_stage.v1.invoke_url}/stats"
}

output "dynamodb_table_name" {
  description = "Name of the DynamoDB table storing short links"
  value       = aws_dynamodb_table.links.name
}

output "dynamodb_table_arn" {
  description = "ARN of the DynamoDB table"
  value       = aws_dynamodb_table.links.arn
}

output "lambda_function_name" {
  description = "Name of the Lambda function"
  value       = aws_lambda_function.url_shortener.function_name
}

output "lambda_function_arn" {
  description = "ARN of the Lambda function"
  value       = aws_lambda_function.url_shortener.arn
}

output "rest_api_id" {
  description = "ID of the API Gateway REST API"
  value       = aws_api_gateway_rest_api.main.id
}

output "lambda_log_group" {
  description = "CloudWatch log group for Lambda function logs"
  value       = aws_cloudwatch_log_group.lambda.name
}
