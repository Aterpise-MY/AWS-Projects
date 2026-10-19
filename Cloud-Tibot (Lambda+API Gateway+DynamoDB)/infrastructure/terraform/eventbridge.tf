/**
 * Project CORTEX - EventBridge Rules Configuration
 * 
 * Creates EventBridge rules to monitor ALL AWS Amplify build status changes
 * (SUCCEED, FAILED, STARTED) across all Amplify apps in the account.
 *
 * CROSS-REGION SETUP:
 *   - Amplify app lives in us-east-2 → EventBridge events emit in us-east-2
 *   - Lambda functions live in us-east-1
 *   - Solution: EventBridge rule in us-east-2 forwards to default bus in us-east-1
 *              Then us-east-1 rule picks up and invokes the Lambda
 */

# =============================================================================
# STEP 1: EventBridge Rule in us-east-2 (Amplify Region) — Capture & Forward
# =============================================================================

# IAM role for EventBridge to put events cross-region
resource "aws_iam_role" "eventbridge_cross_region" {
  name = "${var.project_name}_eventbridge_cross_region"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Name   = "${var.project_name}-eventbridge-cross-region-role"
    Module = "AutoRemediator"
  }
}

resource "aws_iam_role_policy" "eventbridge_cross_region" {
  name = "${var.project_name}_eventbridge_put_events"
  role = aws_iam_role.eventbridge_cross_region.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "events:PutEvents"
      Resource = "arn:aws:events:${var.aws_region}:*:event-bus/default"
    }]
  })
}

# EventBridge rule in us-east-2 to capture Amplify events
resource "aws_cloudwatch_event_rule" "amplify_build_status_source" {
  provider    = aws.amplify_region
  name        = "${var.project_name}_amplify_build_status_forward"
  description = "Captures Amplify build events in ${var.amplify_region} and forwards to ${var.aws_region}"

  event_pattern = jsonencode({
    source      = ["aws.amplify"]
    detail-type = ["Amplify Deployment Status Change"]
    detail = {
      jobStatus = ["SUCCEED", "FAILED", "STARTED"]
    }
  })

  tags = {
    Name   = "${var.project_name}-amplify-build-forward-rule"
    Module = "AutoRemediator"
  }
}

# Forward events from us-east-2 to us-east-1 default event bus
resource "aws_cloudwatch_event_target" "forward_to_primary_region" {
  provider  = aws.amplify_region
  rule      = aws_cloudwatch_event_rule.amplify_build_status_source.name
  target_id = "ForwardToPrimaryRegion"
  arn       = "arn:aws:events:${var.aws_region}:${data.aws_caller_identity.current.account_id}:event-bus/default"
  role_arn  = aws_iam_role.eventbridge_cross_region.arn
}

# Data source for account ID
data "aws_caller_identity" "current" {}

# =============================================================================
# STEP 2: EventBridge Rule in us-east-1 (Primary Region) — Invoke Lambda
# =============================================================================

resource "aws_cloudwatch_event_rule" "amplify_build_status" {
  name        = "${var.project_name}_amplify_build_status"
  description = "Triggers Auto-Remediator Lambda on any Amplify build status change (all apps)"

  event_pattern = jsonencode({
    source      = ["aws.amplify"]
    detail-type = ["Amplify Deployment Status Change"]
    detail = {
      jobStatus = ["SUCCEED", "FAILED", "STARTED"]
    }
  })

  tags = {
    Name   = "${var.project_name}-amplify-build-status-rule"
    Module = "AutoRemediator"
  }
}

# -----------------------------------------------------------------------------
# EventBridge Target - Auto-Remediator Lambda
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_event_target" "auto_remediator" {
  rule      = aws_cloudwatch_event_rule.amplify_build_status.name
  target_id = "AutoRemediatorLambda"
  arn       = aws_lambda_function.auto_remediator.arn

  retry_policy {
    maximum_event_age_in_seconds = 3600 # 1 hour
    maximum_retry_attempts       = 2
  }
}

# -----------------------------------------------------------------------------
# Lambda Permission for EventBridge to Invoke Function A
# -----------------------------------------------------------------------------

resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.auto_remediator.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.amplify_build_status.arn
}

# =============================================================================
# FinOps Sentinel — Scheduled Cost Reports (SGT 09:00 = UTC 01:00)
# =============================================================================

# Daily report — every day at 09:00 SGT (01:00 UTC)
resource "aws_cloudwatch_event_rule" "finops_daily_report" {
  name                = "${var.project_name}_finops_daily_report"
  description         = "Triggers FinOps Sentinel daily cost digest at 09:00 SGT (01:00 UTC)"
  schedule_expression = "cron(0 1 * * ? *)"

  tags = {
    Name   = "${var.project_name}-finops-daily-report"
    Module = "FinOpsSentinel"
  }
}

resource "aws_cloudwatch_event_target" "finops_daily_report" {
  rule      = aws_cloudwatch_event_rule.finops_daily_report.name
  target_id = "FinOpsSentinelDailyLambda"
  arn       = aws_lambda_function.finops_sentinel.arn

  input = jsonencode({ report_type = "daily" })

  retry_policy {
    maximum_event_age_in_seconds = 3600
    maximum_retry_attempts       = 2
  }
}

# Weekly deep dive — every Monday at 09:00 SGT (01:00 UTC)
resource "aws_cloudwatch_event_rule" "finops_weekly_report" {
  name                = "${var.project_name}_finops_weekly_report"
  description         = "Triggers FinOps Sentinel weekly deep dive every Monday at 09:00 SGT (01:00 UTC)"
  schedule_expression = "cron(0 1 ? * MON *)"

  tags = {
    Name   = "${var.project_name}-finops-weekly-report"
    Module = "FinOpsSentinel"
  }
}

resource "aws_cloudwatch_event_target" "finops_weekly_report" {
  rule      = aws_cloudwatch_event_rule.finops_weekly_report.name
  target_id = "FinOpsSentinelWeeklyLambda"
  arn       = aws_lambda_function.finops_sentinel.arn

  input = jsonencode({ report_type = "weekly" })

  retry_policy {
    maximum_event_age_in_seconds = 3600
    maximum_retry_attempts       = 2
  }
}
