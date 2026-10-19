output "api_gateway_invoke_url" {
  description = "API Gateway invoke URL for the /send_email/private endpoint"
  value       = "${aws_api_gateway_stage.prod.invoke_url}/send_email/private"
}

output "api_key_id" {
  description = "API Gateway key ID — retrieve the value with: aws apigateway get-api-key --api-key <id> --include-value"
  value       = aws_api_gateway_api_key.main.id
}

output "sqs_queue_url" {
  description = "SQS FIFO queue URL"
  value       = aws_sqs_queue.gmail_sender.url
}

output "sqs_queue_arn" {
  description = "SQS FIFO queue ARN"
  value       = aws_sqs_queue.gmail_sender.arn
}

output "dynamodb_access_tokens_table" {
  description = "DynamoDB table name for API access token management"
  value       = aws_dynamodb_table.access_tokens.name
}

output "dynamodb_ticket_status_table" {
  description = "DynamoDB table name for per-recipient ticket status"
  value       = aws_dynamodb_table.ticket_status.name
}

output "s3_gmail_tokens_bucket" {
  description = "S3 bucket for Gmail OAuth token persistence across Lambda cold starts"
  value       = aws_s3_bucket.gmail_tokens.bucket
}

output "s3_email_templates_bucket" {
  description = "S3 bucket for HTML email templates (update without Lambda redeploy)"
  value       = aws_s3_bucket.email_templates.bucket
}

output "s3_qr_codes_bucket" {
  description = "S3 bucket for public QR code images referenced in ticket emails"
  value       = aws_s3_bucket.qr_codes.bucket
}

output "lambda_submit_sqs_arn" {
  description = "ARN of the SubmitGmailSenderSQS Lambda function"
  value       = aws_lambda_function.submit_sqs.arn
}

output "lambda_gmail_sender_arn" {
  description = "ARN of the GmailSender Lambda function"
  value       = aws_lambda_function.gmail_sender.arn
}

output "lambda_get_ticket_status_arn" {
  description = "ARN of the GetTicketStatus Lambda function"
  value       = aws_lambda_function.get_ticket_status.arn
}
