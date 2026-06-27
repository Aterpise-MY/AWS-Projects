locals {
  # WebSocket route key => Lambda logical name (from local.functions).
  routes = {
    "$connect"         = "manage_connections"
    "$disconnect"      = "manage_connections"
    "sendVote"         = "handle_vote"
    "broadcastResults" = "broadcast_results"
    "liveVote"         = "livestream_vote"
    "flashPurchase"    = "flashsale_update"
    "designVote"       = "design_vote"
  }
}

resource "aws_apigatewayv2_api" "websocket" {
  name                       = "${var.project_name}-ws-api"
  protocol_type              = "WEBSOCKET"
  route_selection_expression = "$request.body.action"

  tags = local.common_tags
}

# One AWS_PROXY integration per Lambda function.
resource "aws_apigatewayv2_integration" "fn" {
  for_each = local.functions

  api_id                    = aws_apigatewayv2_api.websocket.id
  integration_type          = "AWS_PROXY"
  integration_uri           = aws_lambda_function.fn[each.key].invoke_arn
  content_handling_strategy = "CONVERT_TO_TEXT"
  passthrough_behavior      = "WHEN_NO_MATCH"
}

# One route per WebSocket action, wired to the matching integration.
resource "aws_apigatewayv2_route" "route" {
  for_each = local.routes

  api_id    = aws_apigatewayv2_api.websocket.id
  route_key = each.key
  target    = "integrations/${aws_apigatewayv2_integration.fn[each.value].id}"
}

resource "aws_apigatewayv2_stage" "stage" {
  api_id      = aws_apigatewayv2_api.websocket.id
  name        = var.stage_name
  auto_deploy = true

  default_route_settings {
    throttling_burst_limit   = 5000
    throttling_rate_limit    = 10000
    data_trace_enabled       = false
    detailed_metrics_enabled = true
    logging_level            = "INFO"
  }

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.access_logs.arn
    format = jsonencode({
      requestId       = "$context.requestId"
      ip              = "$context.identity.sourceIp"
      routeKey        = "$context.routeKey"
      status          = "$context.status"
      connectionId    = "$context.connectionId"
      integrationErr  = "$context.integrationErrorMessage"
      responseLatency = "$context.responseLatency"
    })
  }

  tags = local.common_tags

  depends_on = [aws_apigatewayv2_route.route]
}
