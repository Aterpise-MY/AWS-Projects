data "aws_iam_policy_document" "appsync_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["appsync.amazonaws.com"]
    }
  }
}

# ── DynamoDB access role ──────────────────────────────────────────────────────

resource "aws_iam_role" "appsync_dynamodb" {
  name               = "${var.project_name}-appsync-dynamodb-role"
  assume_role_policy = data.aws_iam_policy_document.appsync_assume_role.json
  tags               = local.common_tags
}

data "aws_iam_policy_document" "dynamodb_access" {
  statement {
    sid = "TodosTableAccess"
    actions = [
      "dynamodb:PutItem",
      "dynamodb:GetItem",
      "dynamodb:UpdateItem",
      "dynamodb:DeleteItem",
      "dynamodb:Scan",
      "dynamodb:Query",
    ]
    resources = [aws_dynamodb_table.todos.arn]
  }
}

resource "aws_iam_role_policy" "appsync_dynamodb" {
  name   = "${var.project_name}-dynamodb-access"
  role   = aws_iam_role.appsync_dynamodb.id
  policy = data.aws_iam_policy_document.dynamodb_access.json
}

# ── CloudWatch Logs access role ───────────────────────────────────────────────

resource "aws_iam_role" "appsync_logs" {
  name               = "${var.project_name}-appsync-logs-role"
  assume_role_policy = data.aws_iam_policy_document.appsync_assume_role.json
  tags               = local.common_tags
}

data "aws_iam_policy_document" "cloudwatch_logs_access" {
  statement {
    sid = "CloudWatchLogsWrite"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["arn:aws:logs:*:*:*"]
  }
}

resource "aws_iam_role_policy" "appsync_logs" {
  name   = "${var.project_name}-cloudwatch-logs-access"
  role   = aws_iam_role.appsync_logs.id
  policy = data.aws_iam_policy_document.cloudwatch_logs_access.json
}
