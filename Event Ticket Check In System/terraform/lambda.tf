# ---------------------------------------------------------------------------
# Package Lambda source code from Setup/ directory
# Run `terraform plan` only after populating Setup/ with the source files.
# ---------------------------------------------------------------------------

data "archive_file" "submit_sqs" {
  type        = "zip"
  source_file = "${path.module}/${var.submit_sqs_source_file}"
  output_path = "${path.module}/.terraform/archives/submit_sqs.zip"
}

data "archive_file" "gmail_sender" {
  type        = "zip"
  source_dir  = "${path.module}/${var.gmail_sender_source_dir}"
  output_path = "${path.module}/.terraform/archives/gmail_sender.zip"
}

data "archive_file" "get_ticket_status" {
  type        = "zip"
  source_dir  = "${path.module}/${var.get_ticket_status_source_dir}"
  output_path = "${path.module}/.terraform/archives/get_ticket_status.zip"
}

# ---------------------------------------------------------------------------
# Lambda 1 — SubmitGmailSenderSQS
# HTTP entry point: validates access token and enqueues to SQS FIFO
# ---------------------------------------------------------------------------
resource "aws_lambda_function" "submit_sqs" {
  filename         = data.archive_file.submit_sqs.output_path
  function_name    = "SubmitGmailSenderSQS"
  role             = aws_iam_role.submit_sqs.arn
  handler          = "lambda_function.lambda_handler"
  runtime          = var.lambda_runtime
  timeout          = 30
  memory_size      = 128
  source_code_hash = data.archive_file.submit_sqs.output_base64sha256

  environment {
    variables = {
      PRIVATE_RESOURCE_PATH = "/send_email/private"
      QUEUE_URL             = aws_sqs_queue.gmail_sender.url
      TOKEN_TABLE           = aws_dynamodb_table.access_tokens.name
    }
  }

  tags = {
    Name   = "SubmitGmailSenderSQS"
    Module = "GmailSender"
  }
}

resource "aws_cloudwatch_log_group" "submit_sqs" {
  name              = "/aws/lambda/${aws_lambda_function.submit_sqs.function_name}"
  retention_in_days = 14

  tags = {
    Name   = "submit-gmail-sender-sqs-logs"
    Module = "GmailSender"
  }
}

resource "aws_lambda_permission" "submit_sqs_apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.submit_sqs.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.gmail_sender.execution_arn}/*/*"
}

# ---------------------------------------------------------------------------
# Lambda 2 — GmailSender
# Processes SQS messages; embeds QR into ticket template; sends HTML email
# 2048 MB / 4096 MB ephemeral storage required for Pillow image processing
# ---------------------------------------------------------------------------
resource "aws_lambda_function" "gmail_sender" {
  filename         = data.archive_file.gmail_sender.output_path
  function_name    = "GmailSender"
  role             = aws_iam_role.gmail_sender.arn
  handler          = "lambda_function.lambda_handler"
  runtime          = var.lambda_runtime
  timeout          = 30
  memory_size      = 2048
  source_code_hash = data.archive_file.gmail_sender.output_base64sha256

  ephemeral_storage {
    size = 4096
  }

  environment {
    variables = {
      HTML_CREDENTIAL = var.html_credential
      TOKEN_BUCKET    = aws_s3_bucket.gmail_tokens.bucket
      TEMPLATE_BUCKET = aws_s3_bucket.email_templates.bucket
      QR_CODES_BUCKET = aws_s3_bucket.qr_codes.bucket
      TICKET_TABLE    = aws_dynamodb_table.ticket_status.name
    }
  }

  tags = {
    Name   = "GmailSender"
    Module = "GmailSender"
  }
}

resource "aws_cloudwatch_log_group" "gmail_sender" {
  name              = "/aws/lambda/${aws_lambda_function.gmail_sender.function_name}"
  retention_in_days = 14

  tags = {
    Name   = "gmail-sender-logs"
    Module = "GmailSender"
  }
}

# SQS → GmailSender event source mapping; max concurrency 2 to respect Gmail API rate limits
resource "aws_lambda_event_source_mapping" "sqs_to_gmail_sender" {
  event_source_arn        = aws_sqs_queue.gmail_sender.arn
  function_name           = aws_lambda_function.gmail_sender.arn
  batch_size              = 1
  function_response_types = ["ReportBatchItemFailures"]

  scaling_config {
    maximum_concurrency = 2
  }
}

# ---------------------------------------------------------------------------
# Lambda 3 — GetTicketStatus
# Returns send state for one or more recipient emails
# ---------------------------------------------------------------------------
resource "aws_lambda_function" "get_ticket_status" {
  filename         = data.archive_file.get_ticket_status.output_path
  function_name    = "GetTicketStatus"
  role             = aws_iam_role.get_ticket_status.arn
  handler          = "lambda_function.lambda_handler"
  runtime          = var.lambda_runtime
  timeout          = 30
  memory_size      = 128
  source_code_hash = data.archive_file.get_ticket_status.output_base64sha256

  environment {
    variables = {
      TICKET_TABLE = aws_dynamodb_table.ticket_status.name
    }
  }

  tags = {
    Name   = "GetTicketStatus"
    Module = "GmailSender"
  }
}

resource "aws_cloudwatch_log_group" "get_ticket_status" {
  name              = "/aws/lambda/${aws_lambda_function.get_ticket_status.function_name}"
  retention_in_days = 14

  tags = {
    Name   = "get-ticket-status-logs"
    Module = "GmailSender"
  }
}
