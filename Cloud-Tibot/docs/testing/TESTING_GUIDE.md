# Project CORTEX - Testing Guide

This guide will help you test all pipeline components for the Telegram bot system.

## Quick Start

### 1. Run All Tests (Recommended)
```powershell
.\Test-AllPipelines.ps1
```

This will:
- ✅ Check prerequisites (AWS CLI, Terraform, credentials)
- ✅ Verify infrastructure deployment
- ✅ Test Module 1 (Auto-Remediator) - Amplify build failures
- ✅ Test Module 2 (Git Radar) - GitHub webhooks
- ✅ Test Module 3 (FinOps Sentinel) - Cost optimization
- ✅ Verify CloudWatch Logs
- ✅ Verify DynamoDB state

### 2. Run Tests with Verbose Output
```powershell
.\Test-AllPipelines.ps1 -Verbose
```

### 3. Test Individual Modules
```powershell
# Test only Module 1 (Auto-Remediator)
.\Test-AllPipelines.ps1 -Module1Only

# Test only Module 2 (Git Radar)
.\Test-AllPipelines.ps1 -Module2Only

# Test only Module 3 (FinOps Sentinel)
.\Test-AllPipelines.ps1 -Module3Only
```

## Test Payloads

All test payloads are located in the `test-payloads/` directory:

### Module 1: Auto-Remediator
- `test-amplify-failure.json` - Simulates AWS Amplify build failure event

### Module 2: Git Radar
- `test-github-push.json` - Simulates GitHub push event
- `test-github-pr.json` - Simulates GitHub pull request event
- `test-github-workflow-failure.json` - Simulates GitHub Actions workflow failure

### Module 3: FinOps Sentinel
- `test-finops-cost-alert.json` - Simulates cost anomaly alert
- `test-finops-terraform-failure.json` - Simulates Terraform deployment failure

## Manual Testing

### Test Lambda Function Directly
```powershell
# Get function name from Terraform outputs
terraform output lambda_function_names

# Invoke a specific function
aws lambda invoke `
    --function-name cortex-auto-remediator `
    --payload file://test-payloads/test-amplify-failure.json `
    --cli-binary-format raw-in-base64-out `
    response.json

# View response
Get-Content response.json | ConvertFrom-Json | ConvertTo-Json -Depth 5
```

### Test API Gateway Endpoint
```powershell
# Get webhook URL
terraform output github_webhook_url

# Test with curl
$webhookUrl = terraform output -raw github_webhook_url
$payload = Get-Content test-payloads/test-github-push.json -Raw | ConvertFrom-Json

Invoke-RestMethod -Uri $webhookUrl -Method Post -Body $payload.body -Headers @{
    "Content-Type" = "application/json"
    "x-github-event" = "push"
}
```

### Check CloudWatch Logs
```powershell
# Get log group name
terraform output cloudwatch_log_groups

# View recent logs
aws logs tail /aws/lambda/cortex-git-radar --follow

# Or use the monitoring script
python monitor_logs.py
```

### Check DynamoDB State
```powershell
# Get table name
$tableName = terraform output -raw dynamodb_table_name

# Scan table
aws dynamodb scan --table-name $tableName --max-items 10
```

## Expected Results

### ✅ Successful Test
- Lambda function returns statusCode: 200
- CloudWatch logs show execution without errors
- Telegram notification received (check your Telegram chat)
- DynamoDB updated (for Module 2 only)

### ❌ Common Issues

#### Issue: "AccessDeniedException"
**Solution**: Check AWS credentials
```powershell
aws sts get-caller-identity
```

#### Issue: "ResourceNotFoundException"
**Solution**: Deploy infrastructure first
```powershell
terraform apply
```

#### Issue: "Telegram notification not received"
**Solutions**:
1. Verify `telegram_token` in `terraform.tfvars`
2. Verify `telegram_chat_id` in `terraform.tfvars`
3. Check if bot is added to the chat
4. Test bot manually: `https://api.telegram.org/bot<YOUR_TOKEN>/getMe`

#### Issue: "GitHub API authentication failed"
**Solutions**:
1. Check GitHub App credentials in `terraform.tfvars`:
   - `github_app_id`
   - `github_app_installation_id`
   - `github_app_private_key`
2. Verify GitHub App permissions (must have "Copilot: Read")
3. See [GITHUB_APP_SETUP.md](GITHUB_APP_SETUP.md) for setup guide

#### Issue: Lambda timeout
**Solution**: Increase timeout in `lambda.tf`
```hcl
timeout = 300  # 5 minutes
```

## Monitoring in Production

### Real-time Log Monitoring
```powershell
# Monitor all Lambda logs
.\monitor.ps1

# Or use Python script
python monitor_logs.py
```

### CloudWatch Insights Queries

**Find all errors:**
```
fields @timestamp, @message
| filter @message like /ERROR/
| sort @timestamp desc
| limit 20
```

**Function duration:**
```
fields @timestamp, @duration
| stats avg(@duration), max(@duration), min(@duration)
```

## Integration Testing

### 1. GitHub Webhook Integration
1. Get webhook URL: `terraform output github_webhook_url`
2. Add webhook in GitHub repository settings
3. Push a commit to trigger the webhook
4. Check Telegram for push notification
5. Verify DynamoDB entry

### 2. EventBridge Integration
1. Trigger an Amplify build failure
2. EventBridge should invoke Module 1
3. Check Telegram for remediation notification
4. Check CloudWatch logs

### 3. Cost Alert Integration
1. Configure cost monitoring tool to send alerts to FinOps webhook URL
2. Trigger a test cost alert
3. Check Telegram for cost optimization recommendations
4. Check CloudWatch logs

## Performance Benchmarks

Expected execution times:
- Module 1 (Auto-Remediator): 10-30 seconds
- Module 2 (Git Radar): 5-15 seconds
- Module 3 (FinOps Sentinel): 10-25 seconds

If execution times exceed these, consider:
- Optimizing AI agent prompts
- Increasing Lambda memory
- Caching GitHub API responses

## Troubleshooting Commands

```powershell
# Check Terraform state
terraform show

# Validate configuration
terraform validate

# View all outputs
terraform output

# Check Lambda configuration
aws lambda get-function-configuration --function-name cortex-git-radar

# Test Telegram bot
$botToken = terraform output -raw telegram_token
Invoke-RestMethod "https://api.telegram.org/bot$botToken/getMe"

# Check DynamoDB table
aws dynamodb describe-table --table-name $(terraform output -raw dynamodb_table_name)

# List recent Lambda invocations
aws lambda list-functions | ConvertFrom-Json | 
    Select-Object -ExpandProperty Functions | 
    Where-Object { $_.FunctionName -like "cortex-*" }
```

## Next Steps After Testing

1. ✅ Configure production GitHub webhook
2. ✅ Set up cost monitoring integration
3. ✅ Configure CloudWatch alarms
4. ✅ Set up log retention policies
5. ✅ Document incident response procedures
6. ✅ Train team on Telegram notifications

## Support

If tests fail consistently, check:
1. [DEPLOYMENT_CHECKLIST.md](DEPLOYMENT_CHECKLIST.md) - Deployment steps
2. [GITHUB_APP_SETUP.md](GITHUB_APP_SETUP.md) - GitHub authentication
3. [COPILOT_AUTH_SETUP.md](COPILOT_AUTH_SETUP.md) - Alternative auth methods
4. CloudWatch logs for detailed error messages
5. Terraform state for resource configuration

---
**Project CORTEX** - Serverless ChatOps on AWS
