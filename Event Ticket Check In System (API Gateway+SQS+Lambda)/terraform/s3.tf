# ---------------------------------------------------------------------------
# Gmail OAuth token storage — private; versioned to survive accidental overwrites
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "gmail_tokens" {
  bucket = "${var.project_name}-gmail-sender-tokens"

  tags = {
    Name   = "${var.project_name}-gmail-sender-tokens"
    Module = "GmailSender"
  }
}

resource "aws_s3_bucket_versioning" "gmail_tokens" {
  bucket = aws_s3_bucket.gmail_tokens.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "gmail_tokens" {
  bucket                  = aws_s3_bucket.gmail_tokens.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------------------------------------------------------------------------
# Email template storage — private; updated without Lambda redeployment
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "email_templates" {
  bucket = "${var.project_name}-email-templates"

  tags = {
    Name   = "${var.project_name}-email-templates"
    Module = "GmailSender"
  }
}

resource "aws_s3_bucket_public_access_block" "email_templates" {
  bucket                  = aws_s3_bucket.email_templates.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------------------------------------------------------------------------
# QR code image storage — public read for permanent download links in emails
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "qr_codes" {
  bucket = "${var.project_name}-qr-codes"

  tags = {
    Name   = "${var.project_name}-qr-codes"
    Module = "GmailSender"
  }
}

resource "aws_s3_bucket_public_access_block" "qr_codes" {
  bucket                  = aws_s3_bucket.qr_codes.id
  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_policy" "qr_codes_public_read" {
  depends_on = [aws_s3_bucket_public_access_block.qr_codes]
  bucket     = aws_s3_bucket.qr_codes.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "PublicReadGetObject"
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.qr_codes.arn}/*"
      }
    ]
  })
}
