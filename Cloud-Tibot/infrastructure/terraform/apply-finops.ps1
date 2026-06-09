#!/usr/bin/env pwsh
# Targeted apply — FinOps Sentinel EventBridge schedules + Lambda + IAM only
Set-Location $PSScriptRoot

$targets = @(
    "aws_iam_role.lambda_finops_sentinel",
    "aws_iam_role_policy_attachment.lambda_finops_sentinel_logs",
    "aws_iam_role_policy.lambda_finops_sentinel_cost",
    "aws_lambda_function.finops_sentinel",
    "aws_cloudwatch_event_rule.finops_daily_report",
    "aws_cloudwatch_event_rule.finops_weekly_report",
    "aws_cloudwatch_event_target.finops_daily_report",
    "aws_cloudwatch_event_target.finops_weekly_report",
    "aws_lambda_permission.finops_sentinel_eventbridge_daily",
    "aws_lambda_permission.finops_sentinel_eventbridge_weekly"
)

$targetFlags = $targets | ForEach-Object { "-target=$_" }

terraform apply `
    -var-file="../../infrastructure/terraform.tfvars.dev" `
    @targetFlags `
    -auto-approve
