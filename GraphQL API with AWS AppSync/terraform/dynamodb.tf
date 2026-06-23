resource "aws_dynamodb_table" "todos" {
  name         = "${var.project_name}-todos"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"

  attribute {
    name = "id"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  deletion_protection_enabled = false

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-todos"
  })
}
