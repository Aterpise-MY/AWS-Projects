data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

# ---------------------------------------------------------------------------
# SubmitGmailSenderSQS — needs SQS send + DynamoDB token validation
# ---------------------------------------------------------------------------
resource "aws_iam_role" "submit_sqs" {
  name               = "${var.project_name}_submit_sqs_role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json

  tags = {
    Name   = "${var.project_name}-submit-sqs-role"
    Module = "GmailSender"
  }
}

resource "aws_iam_role_policy_attachment" "submit_sqs_logs" {
  role       = aws_iam_role.submit_sqs.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "submit_sqs_policy" {
  name = "${var.project_name}_submit_sqs_policy"
  role = aws_iam_role.submit_sqs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SQSSend"
        Effect = "Allow"
        Action = ["sqs:SendMessage", "sqs:GetQueueAttributes"]
        Resource = aws_sqs_queue.gmail_sender.arn
      },
      {
        Sid    = "DynamoDBTokenValidation"
        Effect = "Allow"
        Action = ["dynamodb:GetItem", "dynamodb:UpdateItem"]
        Resource = aws_dynamodb_table.access_tokens.arn
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# GmailSender — needs SQS consume + S3 read/write + DynamoDB ticket updates
# ---------------------------------------------------------------------------
resource "aws_iam_role" "gmail_sender" {
  name               = "${var.project_name}_gmail_sender_role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json

  tags = {
    Name   = "${var.project_name}-gmail-sender-role"
    Module = "GmailSender"
  }
}

resource "aws_iam_role_policy_attachment" "gmail_sender_logs" {
  role       = aws_iam_role.gmail_sender.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "gmail_sender_policy" {
  name = "${var.project_name}_gmail_sender_policy"
  role = aws_iam_role.gmail_sender.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SQSConsume"
        Effect = "Allow"
        Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
        Resource = aws_sqs_queue.gmail_sender.arn
      },
      {
        Sid    = "S3OAuthToken"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:PutObject"]
        Resource = "${aws_s3_bucket.gmail_tokens.arn}/*"
      },
      {
        Sid    = "S3TemplateRead"
        Effect = "Allow"
        Action = ["s3:GetObject"]
        Resource = "${aws_s3_bucket.email_templates.arn}/*"
      },
      {
        Sid    = "S3QRCodeWrite"
        Effect = "Allow"
        Action = ["s3:PutObject"]
        Resource = "${aws_s3_bucket.qr_codes.arn}/*"
      },
      {
        Sid    = "DynamoDBTicketStatus"
        Effect = "Allow"
        Action = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem"]
        Resource = aws_dynamodb_table.ticket_status.arn
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# GetTicketStatus — read-only access to ticket status table
# ---------------------------------------------------------------------------
resource "aws_iam_role" "get_ticket_status" {
  name               = "${var.project_name}_get_ticket_status_role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json

  tags = {
    Name   = "${var.project_name}-get-ticket-status-role"
    Module = "GmailSender"
  }
}

resource "aws_iam_role_policy_attachment" "get_ticket_status_logs" {
  role       = aws_iam_role.get_ticket_status.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "get_ticket_status_policy" {
  name = "${var.project_name}_get_ticket_status_policy"
  role = aws_iam_role.get_ticket_status.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DynamoDBTicketRead"
        Effect = "Allow"
        Action = ["dynamodb:GetItem", "dynamodb:Query", "dynamodb:Scan"]
        Resource = aws_dynamodb_table.ticket_status.arn
      }
    ]
  })
}
