# ── Polls (original general polling table) ────────────────────────────────────

resource "aws_dynamodb_table" "polls" {
  name         = "${var.project_name}-polls"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pollId"

  attribute {
    name = "pollId"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  tags = merge(local.common_tags, { Name = "${var.project_name}-polls" })
}

# ── Connections (shared across all scenarios) ─────────────────────────────────

resource "aws_dynamodb_table" "connections" {
  name         = "${var.project_name}-connections"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "connectionId"

  attribute {
    name = "connectionId"
    type = "S"
  }

  attribute {
    name = "sessionId"
    type = "S"
  }

  global_secondary_index {
    name            = "sessionId-index"
    hash_key        = "sessionId"
    projection_type = "ALL"
  }

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  tags = merge(local.common_tags, { Name = "${var.project_name}-connections" })
}

# ── LiveStreamSessions (Scenario 1) ───────────────────────────────────────────

resource "aws_dynamodb_table" "livestream_sessions" {
  name         = "${var.project_name}-livestream-sessions"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "sessionId"

  attribute {
    name = "sessionId"
    type = "S"
  }

  ttl {
    attribute_name = "expiresAt"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = true
  }

  tags = merge(local.common_tags, { Name = "${var.project_name}-livestream-sessions" })
}

# ── FlashSaleItems (Scenario 2) ───────────────────────────────────────────────

resource "aws_dynamodb_table" "flashsale_items" {
  name         = "${var.project_name}-flashsale-items"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "itemId"

  attribute {
    name = "itemId"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  tags = merge(local.common_tags, { Name = "${var.project_name}-flashsale-items" })
}

# ── DesignSurveys (Scenario 3) ────────────────────────────────────────────────

resource "aws_dynamodb_table" "design_surveys" {
  name         = "${var.project_name}-design-surveys"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "surveyId"

  attribute {
    name = "surveyId"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  tags = merge(local.common_tags, { Name = "${var.project_name}-design-surveys" })
}
