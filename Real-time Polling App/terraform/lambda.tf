locals {
  # Logical name => Lambda handler entrypoint. All six functions share one zip
  # (the whole lambda/ directory, so _broadcast.py is importable everywhere).
  functions = {
    manage_connections = "manage_connections.lambda_handler"
    handle_vote        = "handle_vote.lambda_handler"
    broadcast_results  = "broadcast_results.lambda_handler"
    livestream_vote    = "handle_livestream_vote.lambda_handler"
    flashsale_update   = "handle_flashsale_update.lambda_handler"
    design_vote        = "handle_design_vote.lambda_handler"
  }
}

data "archive_file" "lambda" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda"
  output_path = "${path.module}/../lambda/build/functions.zip"
}

resource "aws_lambda_function" "fn" {
  for_each = local.functions

  function_name    = "${var.project_name}-${each.key}"
  role             = aws_iam_role.lambda_exec.arn
  handler          = each.value
  runtime          = "python3.11"
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256
  memory_size      = var.lambda_memory_mb
  timeout          = var.lambda_timeout_seconds

  environment {
    variables = {
      POLLS_TABLE            = aws_dynamodb_table.polls.name
      CONNECTIONS_TABLE      = aws_dynamodb_table.connections.name
      LIVESTREAM_TABLE       = aws_dynamodb_table.livestream_sessions.name
      FLASHSALE_TABLE        = aws_dynamodb_table.flashsale_items.name
      DESIGN_TABLE           = aws_dynamodb_table.design_surveys.name
      CONNECTION_TTL_SECONDS = tostring(var.connection_ttl_seconds)
    }
  }

  depends_on = [
    aws_iam_role_policy.lambda_logs,
    aws_cloudwatch_log_group.lambda,
  ]

  tags = merge(local.common_tags, { Name = "${var.project_name}-${each.key}" })
}

resource "aws_lambda_permission" "apigw" {
  for_each = local.functions

  statement_id  = "AllowWebSocketInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.fn[each.key].function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.websocket.execution_arn}/*/*"
}
