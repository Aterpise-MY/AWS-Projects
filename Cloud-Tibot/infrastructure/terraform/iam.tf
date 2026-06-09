/**
 * Project CORTEX - IAM Roles and Policies
 * 
 * Defines IAM roles and policies for Lambda functions following
 * the principle of least privilege. Each function has its own
 * role with specific permissions required for its operation.
 */

# -----------------------------------------------------------------------------
# Lambda Assume Role Policy (Common for all Lambda functions)
# -----------------------------------------------------------------------------

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

# -----------------------------------------------------------------------------
# Function A (Auto-Remediator) - EventBridge Trigger
# -----------------------------------------------------------------------------

resource "aws_iam_role" "lambda_auto_remediator" {
  name               = "${var.project_name}_lambda_auto_remediator_role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json

  tags = {
    Name   = "${var.project_name}-auto-remediator-role"
    Module = "AutoRemediator"
  }
}

# CloudWatch Logs policy for Function A
resource "aws_iam_role_policy_attachment" "lambda_auto_remediator_logs" {
  role       = aws_iam_role.lambda_auto_remediator.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Custom policy for Amplify operations
resource "aws_iam_role_policy" "lambda_auto_remediator_amplify" {
  name = "${var.project_name}_auto_remediator_amplify_policy"
  role = aws_iam_role.lambda_auto_remediator.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "amplify:GetApp",
          "amplify:GetJob",
          "amplify:ListJobs",
          "amplify:StartJob"
        ]
        Resource = "*" # Consider restricting to specific Amplify app ARNs in production
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# Function B (Git Radar) - API Gateway Trigger with DynamoDB Access
# -----------------------------------------------------------------------------

resource "aws_iam_role" "lambda_git_radar" {
  name               = "${var.project_name}_lambda_git_radar_role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json

  tags = {
    Name   = "${var.project_name}-git-radar-role"
    Module = "GitRadar"
  }
}

# CloudWatch Logs policy for Function B
resource "aws_iam_role_policy_attachment" "lambda_git_radar_logs" {
  role       = aws_iam_role.lambda_git_radar.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# DynamoDB read/write policy for Function B
resource "aws_iam_role_policy" "lambda_git_radar_dynamodb" {
  name = "${var.project_name}_git_radar_dynamodb_policy"
  role = aws_iam_role.lambda_git_radar.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
          "dynamodb:DeleteItem",
          "dynamodb:Query",
          "dynamodb:Scan"
        ]
        Resource = aws_dynamodb_table.cortex_radar_state.arn
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# Function C (FinOps Sentinel) - API Gateway Trigger
# -----------------------------------------------------------------------------

resource "aws_iam_role" "lambda_finops_sentinel" {
  name               = "${var.project_name}_lambda_finops_sentinel_role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json

  tags = {
    Name   = "${var.project_name}-finops-sentinel-role"
    Module = "FinOpsSentinel"
  }
}

# CloudWatch Logs policy for Function C (basic execution only)
resource "aws_iam_role_policy_attachment" "lambda_finops_sentinel_logs" {
  role       = aws_iam_role.lambda_finops_sentinel.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Cost Explorer + CloudWatch Metrics policy for scheduled FinOps reports
resource "aws_iam_role_policy" "lambda_finops_sentinel_cost" {
  name = "${var.project_name}_finops_sentinel_cost_policy"
  role = aws_iam_role.lambda_finops_sentinel.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "CostExplorerReadOnly"
        Effect   = "Allow"
        Action   = ["ce:GetCostAndUsage"]
        Resource = "*" # CE has no resource-level ARN scoping
      },
      {
        Sid      = "CloudWatchMetricsReadOnly"
        Effect   = "Allow"
        Action   = ["cloudwatch:GetMetricStatistics"]
        Resource = "*"
      }
    ]
  })
}
