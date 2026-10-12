resource "aws_api_gateway_rest_api" "gmail_sender" {
  name        = "Submit Gmail Sender SQS API"
  description = "REST API that receives email send requests and routes them to SQS FIFO"

  tags = {
    Name   = "submit-gmail-sender-sqs-api"
    Module = "GmailSender"
  }
}

# /send_email
resource "aws_api_gateway_resource" "send_email" {
  rest_api_id = aws_api_gateway_rest_api.gmail_sender.id
  parent_id   = aws_api_gateway_rest_api.gmail_sender.root_resource_id
  path_part   = "send_email"
}

# /send_email/private
resource "aws_api_gateway_resource" "send_email_private" {
  rest_api_id = aws_api_gateway_rest_api.gmail_sender.id
  parent_id   = aws_api_gateway_resource.send_email.id
  path_part   = "private"
}

resource "aws_api_gateway_method" "post_send_email_private" {
  rest_api_id      = aws_api_gateway_rest_api.gmail_sender.id
  resource_id      = aws_api_gateway_resource.send_email_private.id
  http_method      = "POST"
  authorization    = "NONE"
  api_key_required = true
}

resource "aws_api_gateway_integration" "post_send_email_private" {
  rest_api_id             = aws_api_gateway_rest_api.gmail_sender.id
  resource_id             = aws_api_gateway_resource.send_email_private.id
  http_method             = aws_api_gateway_method.post_send_email_private.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.submit_sqs.invoke_arn
}

resource "aws_api_gateway_deployment" "prod" {
  rest_api_id = aws_api_gateway_rest_api.gmail_sender.id

  depends_on = [
    aws_api_gateway_integration.post_send_email_private,
  ]

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "prod" {
  deployment_id = aws_api_gateway_deployment.prod.id
  rest_api_id   = aws_api_gateway_rest_api.gmail_sender.id
  stage_name    = "prod"

  tags = {
    Name   = "submit-gmail-sender-sqs-api-prod"
    Module = "GmailSender"
  }
}

resource "aws_api_gateway_api_key" "main" {
  name    = "${var.project_name}-api-key"
  enabled = true

  tags = {
    Name   = "${var.project_name}-api-key"
    Module = "GmailSender"
  }
}

resource "aws_api_gateway_usage_plan" "main" {
  name = "${var.project_name}-usage-plan"

  api_stages {
    api_id = aws_api_gateway_rest_api.gmail_sender.id
    stage  = aws_api_gateway_stage.prod.stage_name
  }

  tags = {
    Name   = "${var.project_name}-usage-plan"
    Module = "GmailSender"
  }
}

resource "aws_api_gateway_usage_plan_key" "main" {
  key_id        = aws_api_gateway_api_key.main.id
  key_type      = "API_KEY"
  usage_plan_id = aws_api_gateway_usage_plan.main.id
}
