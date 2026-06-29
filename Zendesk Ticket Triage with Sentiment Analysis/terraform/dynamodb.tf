resource "aws_dynamodb_table" "sentiment" {
  name         = "SentimentAnalysis"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "TicketID"
  range_key    = "CreatedAt"

  attribute {
    name = "TicketID"
    type = "S"
  }

  attribute {
    name = "CreatedAt"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  deletion_protection_enabled = false

  tags = merge(local.common_tags, {
    Name = "SentimentAnalysis"
  })
}
