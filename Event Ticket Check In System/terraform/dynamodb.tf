# Access token management — validates callers; TTL auto-expires tokens
resource "aws_dynamodb_table" "access_tokens" {
  name         = "gmail_api_access_tokens"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "token"

  attribute {
    name = "token"
    type = "S"
  }

  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  tags = {
    Name   = "gmail-api-access-tokens"
    Module = "GmailSender"
  }
}

# Ticket status tracking — records per-recipient send state and QR link
resource "aws_dynamodb_table" "ticket_status" {
  name         = "yrc2027_ticket_status"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "email"

  attribute {
    name = "email"
    type = "S"
  }

  tags = {
    Name   = "yrc2027-ticket-status"
    Module = "GmailSender"
  }
}
