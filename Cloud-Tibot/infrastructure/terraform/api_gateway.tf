/**
 * Project CORTEX - API Gateway Configuration
 * 
 * Creates an HTTP API Gateway (v2) with two webhook endpoints:
 * - POST /webhook/github -> Git Radar Lambda
 * - POST /webhook/finops -> FinOps Sentinel Lambda
 */

# -----------------------------------------------------------------------------
# HTTP API Gateway V2
# -----------------------------------------------------------------------------

resource "aws_apigatewayv2_api" "cortex_api" {
  name          = "${var.project_name}-chatops-api"
  protocol_type = "HTTP"
  description   = "CORTEX ChatOps API Gateway for webhook integrations"

  cors_configuration {
    allow_origins = ["*"]
    allow_methods = ["POST", "OPTIONS"]
    allow_headers = ["content-type", "x-github-event", "x-github-delivery"]
    max_age       = 300
  }

  tags = {
    Name = "${var.project_name}-chatops-api"
  }
}

# -----------------------------------------------------------------------------
# API Gateway Stage (Production)
# -----------------------------------------------------------------------------

resource "aws_apigatewayv2_stage" "prod" {
  api_id      = aws_apigatewayv2_api.cortex_api.id
  name        = "$default"
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_gateway.arn
    format = jsonencode({
      requestId      = "$context.requestId"
      ip             = "$context.identity.sourceIp"
      requestTime    = "$context.requestTime"
      httpMethod     = "$context.httpMethod"
      routeKey       = "$context.routeKey"
      status         = "$context.status"
      protocol       = "$context.protocol"
      responseLength = "$context.responseLength"
    })
  }

  tags = {
    Name = "${var.project_name}-api-stage-prod"
  }
}

# CloudWatch Log Group for API Gateway
resource "aws_cloudwatch_log_group" "api_gateway" {
  name              = "/aws/apigateway/${var.project_name}-chatops-api"
  retention_in_days = 14

  tags = {
    Name = "${var.project_name}-api-gateway-logs"
  }
}

# -----------------------------------------------------------------------------
# Lambda Integration for Git Radar (Function B)
# -----------------------------------------------------------------------------

resource "aws_apigatewayv2_integration" "git_radar" {
  api_id             = aws_apigatewayv2_api.cortex_api.id
  integration_type   = "AWS_PROXY"
  integration_method = "POST"
  integration_uri    = aws_lambda_function.git_radar.invoke_arn
  payload_format_version = "2.0"

  description = "Integration with Git Radar Lambda function"
}

# Route: POST /webhook/github -> Git Radar
resource "aws_apigatewayv2_route" "github_webhook" {
  api_id    = aws_apigatewayv2_api.cortex_api.id
  route_key = "POST /webhook/github"
  target    = "integrations/${aws_apigatewayv2_integration.git_radar.id}"
}

# -----------------------------------------------------------------------------
# Lambda Integration for FinOps Sentinel (Function C)
# -----------------------------------------------------------------------------

resource "aws_apigatewayv2_integration" "finops_sentinel" {
  api_id             = aws_apigatewayv2_api.cortex_api.id
  integration_type   = "AWS_PROXY"
  integration_method = "POST"
  integration_uri    = aws_lambda_function.finops_sentinel.invoke_arn
  payload_format_version = "2.0"

  description = "Integration with FinOps Sentinel Lambda function"
}

# Route: POST /webhook/finops -> FinOps Sentinel
resource "aws_apigatewayv2_route" "finops_webhook" {
  api_id    = aws_apigatewayv2_api.cortex_api.id
  route_key = "POST /webhook/finops"
  target    = "integrations/${aws_apigatewayv2_integration.finops_sentinel.id}"
}
