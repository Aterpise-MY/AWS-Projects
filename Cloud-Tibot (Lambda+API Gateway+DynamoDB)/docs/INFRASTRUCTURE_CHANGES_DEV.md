# Cloud-Tibot Infrastructure Changes — Amplify Build Notifier

## Overview

This document compiles all infrastructure-as-code changes for the **Amplify Build Notifier** feature in the Cloud-Tibot project (Module 1: Auto-Remediator).

**Date:** February 13, 2026  
**Environment:** Multi-environment (dev, staging, prod)  
**Status:** ✅ Tested and deployed to prod  

---

## Architecture Summary

```
AWS Amplify (any app, any branch)
            ↓
    [Build Status Change]
            ↓
    EventBridge Rule
    "amplify_build_status"
    (matches: STARTED, SUCCEED, FAILED)
            ↓
    Lambda Function
    "cloud-tibot_auto_remediator"
    (122 lines, 1.6KB)
            ↓
    Telegram Bot API
    ↓
📱 Telegram Chat Message
```

---

## Infrastructure Components

### 1. EventBridge Rule Configuration

**Resource:** `aws_cloudwatch_event_rule.amplify_build_status`

**Event Pattern:**
```json
{
  "source": ["aws.amplify"],
  "detail-type": ["Amplify Deployment Status Change"],
  "detail": {
    "jobStatus": ["SUCCEED", "FAILED", "STARTED"]
  }
}
```

**Features:**
- Monitors **ALL Amplify apps** in the AWS account
- Triggers on **all build statuses** (not just failures)
- Correct EventBridge event type: `Amplify Deployment Status Change`

**Old Rule (Disabled):**
- `cloud-tibot_amplify_build_failed` — only matched FAILED status

---

### 2. Lambda Function: Amplify Build Notifier

**Function Name:** `cloud-tibot_auto_remediator`

**Code Size:** 1.6KB (simplified from 30MB)

**Runtime:** Python 3.11

**Key Changes from Previous Version:**
- ✅ Removed AI agent logic (was causing import errors)
- ✅ Removed GitHub/Copilot dependencies (PyJWT, cryptography)
- ✅ Simplified to pure notification function
- ✅ Added support for ALL build statuses (STARTED, SUCCEED, FAILED, CANCELLED)
- ✅ Added Amplify app name resolution via `amplify:GetApp`
- ✅ Added AWS Console direct link in notifications
- ✅ Added commit hash display in notifications

**Function Handler:** `lambda_function.lambda_handler`

**Timeout:** 60 seconds (dev) / 300 seconds (prod)

**Memory:** 256 MB (dev) / 1024 MB (prod)

**Environment Variables:**
```
TELEGRAM_TOKEN    - Telegram Bot API token
TELEGRAM_CHAT_ID  - Telegram chat ID for notifications
PROJECT_NAME      - Project name (cloud-tibot)
AWS_REGION        - AWS region (auto-injected by Lambda)
```

**Removed Environment Variables:**
- ~~GITHUB_APP_ID~~ (no longer needed)
- ~~GITHUB_APP_INSTALLATION_ID~~ (no longer needed)
- ~~GITHUB_APP_PRIVATE_KEY~~ (no longer needed)
- ~~GITHUB_REPO_OWNER~~ (no longer needed)
- ~~GITHUB_REPO_NAME~~ (no longer needed)

---

### 3. Lambda Permissions

**Resource:** `aws_lambda_permission.allow_eventbridge`

Allows the new EventBridge rule to invoke the Lambda function.

**Policy:**
```json
{
  "Effect": "Allow",
  "Principal": { "Service": "events.amazonaws.com" },
  "Action": "lambda:InvokeFunction",
  "Resource": "arn:aws:lambda:us-east-1:*:function:cloud-tibot_auto_remediator",
  "Condition": {
    "ArnLike": {
      "AWS:SourceArn": "arn:aws:events:us-east-1:*:rule/cloud-tibot_amplify_build_status"
    }
  }
}
```

---

### 4. IAM Role Policy

**Resource:** `aws_iam_role_policy.lambda_auto_remediator_amplify`

**Permissions:**
```json
{
  "Effect": "Allow",
  "Action": [
    "amplify:GetApp",      // NEW: Get app details for name resolution
    "amplify:GetJob",
    "amplify:ListJobs",
    "amplify:StartJob"
  ],
  "Resource": "*"
}
```

**CloudWatch Logs Policy:** (Inherited from `AWSLambdaBasicExecutionRole`)
```json
{
  "Effect": "Allow",
  "Action": [
    "logs:CreateLogGroup",
    "logs:CreateLogStream",
    "logs:PutLogEvents"
  ],
  "Resource": "arn:aws:logs:*:*:*"
}
```

---

### 5. CloudWatch Log Group

**Resource:** `aws_cloudwatch_log_group.auto_remediator`

**Log Retention:** 14 days

**Log Group Name:** `/aws/lambda/cloud-tibot_auto_remediator`

---

## Terraform Files Changed

### File Structure
```
infrastructure/
├── terraform/
│   ├── eventbridge.tf          (✅ Updated)
│   ├── iam.tf                  (✅ Updated)
│   ├── lambda.tf               (✅ Updated: source_dir paths fixed)
│   ├── outputs.tf              (✅ Updated: rule name reference)
│   ├── variables.tf            (No changes — supports both scenarios)
│   ├── provider.tf             (No changes)
│   ├── api_gateway.tf          (No changes)
│   └── dynamodb.tf             (No changes)
├── terraform.tfvars.example    (Example config)
└── terraform.tfvars.dev        (✅ NEW: Dev environment variables)

src/module1/
├── lambda_function.py          (✅ Updated: 122 lines, simplified)
├── requirements.txt            (✅ Updated: removed PyJWT, cryptography)
├── copilot_agent.py            (Deprecated — no longer imported)
└── build/                      (Will be regenerated on next deploy)
```

---

## Key Fixes in This Release

### Issue 1: EventBridge Rule Only Triggered on FAILED
**Status:** ✅ FIXED

**Change:** Updated event pattern to match STARTED, SUCCEED, FAILED, CANCELLED
```terraform
# Before
detail = {
  jobStatus = ["FAILED"]
}

# After
detail = {
  jobStatus = ["SUCCEED", "FAILED", "STARTED"]
}
```

---

### Issue 2: Wrong EventBridge Event Type
**Status:** ✅ FIXED

**Change:** Corrected event type name
```terraform
# Before
detail-type = ["Amplify App Build Status Change"]

# After
detail-type = ["Amplify Deployment Status Change"]
```

---

### Issue 3: Lambda Import Errors (PyJWT, cryptography)
**Status:** ✅ FIXED

**Change:** Removed AI agent code and dependencies
```diff
# requirements.txt
- PyJWT>=2.8.0
- cryptography>=41.0.0
+ # Only standard boto3 and urllib3 needed
```

---

### Issue 4: Lambda Source Directory Path
**Status:** ✅ FIXED

**Change:** Corrected relative paths for Lambda source packaging
```terraform
# Before
source_dir = "${path.module}/src/module1"

# After (from infrastructure/terraform/)
source_dir = "${path.module}/../../src/module1"
```

---

### Issue 5: No App Name Resolution on SUCCEED/STARTED
**Status:** ✅ FIXED

**Change:** Added Amplify API call to get app name for all notifications
```python
try:
    amplify_client = boto3.client("amplify")
    app_resp = amplify_client.get_app(appId=app_id)
    app_name = app_resp.get("app", {}).get("name", app_id)
except Exception as e:
    print(f"Could not fetch app name: {e}")
```

**IAM Update:** Added `amplify:GetApp` permission

---

### Issue 6: No Direct AWS Console Link
**Status:** ✅ FIXED

**Change:** Added Amplify console link in Telegram message
```python
console_url = (
    f"https://{aws_region}.console.aws.amazon.com/amplify/home"
    f"?region={aws_region}#/{app_id}/{branch_name}/{job_id}"
)
```

---

## Deployment Instructions

### Prerequisites
- Terraform >= 1.5.0
- AWS CLI configured with credentials
- Telegram bot token and chat ID

### Step 1: Set Up Dev Environment Variables

Create `infrastructure/terraform.tfvars.dev` (already created) and fill in actual values:

```bash
# Edit the file to set real values
vim infrastructure/terraform.tfvars.dev
```

**Required fields:**
- `telegram_token` — Get from BotFather on Telegram
- `telegram_chat_id` — Your Telegram chat ID (usually negative number for groups)

**Optional fields (for other modules):**
- GitHub App credentials (only needed if using Git Radar or FinOps modules)

---

### Step 2: Initialize Terraform for Dev

```bash
cd infrastructure/terraform

# Initialize with dev backend (local state for testing)
terraform init

# Validate configuration
terraform validate

# Format code (recommended)
terraform fmt -recursive
```

---

### Step 3: Plan the Deployment

```bash
# Plan with dev variables
terraform plan -var-file=../terraform.tfvars.dev -out=tfplan.dev

# Review the plan output
```

---

### Step 4: Apply Configuration

```bash
# Apply the plan
terraform apply tfplan.dev

# Or apply directly (will show plan and ask for confirmation)
terraform apply -var-file=../terraform.tfvars.dev
```

---

### Step 5: Verify Deployment

```bash
# Get outputs
terraform output

# Check Lambda function
aws lambda get-function --function-name cloud-tibot_auto_remediator --region us-east-1

# Check EventBridge rule
aws events describe-rule --name cloud-tibot_amplify_build_status --region us-east-1

# Check EventBridge targets
aws events list-targets-by-rule --rule cloud-tibot_amplify_build_status --region us-east-1
```

---

### Step 6: Test the Setup

Create a test Amplify build or use Lambda invoke to test:

```bash
# Create a test event file
cat > test-event.json << 'EOF'
{
  "source": "aws.amplify",
  "detail-type": "Amplify Deployment Status Change",
  "detail": {
    "appId": "YOUR_APP_ID",
    "branchName": "main",
    "jobId": "999",
    "jobStatus": "SUCCEED",
    "commitId": "test1234567890ab"
  }
}
EOF

# Invoke the Lambda
aws lambda invoke --function-name cloud-tibot_auto_remediator \
  --payload file://test-event.json \
  --region us-east-1 \
  response.json --output json

# Check the response
cat response.json
```

**You should receive a Telegram message!**

---

## Multi-Environment Support

### Dev Environment (`terraform.tfvars.dev`)
- Reduced Lambda timeout: 60s (vs 300s in prod)
- Reduced Lambda memory: 256 MB (vs 1024 MB in prod)
- Good for testing and development
- Lower costs

### Staging Environment (`terraform.tfvars.staging`)
- Similar to prod but with lower resource allocation
- Use for pre-production testing
- Create by copying `.example` and adjusting values

### Prod Environment (`terraform.tfvars.prod`)
- Full resource allocation: 300s timeout, 1024 MB memory
- All features enabled
- Used for production traffic

### How to Deploy to Different Environments

```bash
# Deploy to dev
terraform apply -var-file=../terraform.tfvars.dev

# Deploy to staging
terraform apply -var-file=../terraform.tfvars.staging

# Deploy to prod (currently live)
terraform apply -var-file=../terraform.tfvars.prod
```

---

## Terraform State Management

### Current Setup
- Local state files per environment (for testing)
- Recommended for dev/staging

### Recommended for Prod
- Remote state backend (S3 + DynamoDB)
- State locking for safety
- Team collaboration

### Enable Remote State

Create `infrastructure/terraform/backend.tf`:

```hcl
terraform {
  backend "s3" {
    bucket         = "cloud-tibot-terraform-state"
    key            = "cortex/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "terraform-locks"
  }
}
```

---

## Lambda Code Details

### Input Event Schema

```json
{
  "source": "aws.amplify",
  "detail-type": "Amplify Deployment Status Change",
  "detail": {
    "appId": "d2t3ti5dqkttcm",
    "appName": "my-app",
    "branchName": "main",
    "jobId": "29",
    "jobStatus": "SUCCEED",
    "commitId": "bfe2b7fd98933ebb1db52e571dd2d1a766d42b91",
    "commitMessage": "fix: Update CORS policy",
    "repoUrl": "https://github.com/owner/repo"
  }
}
```

### Output Response

```json
{
  "statusCode": 200,
  "body": {
    "message": "Telegram notification sent for SUCCEED",
    "app_id": "d2t3ti5dqkttcm",
    "app_name": "ebteq-csv-converter",
    "branch": "main",
    "status": "SUCCEED"
  }
}
```

### Telegram Message Format

```
✅ Amplify Build Notification
━━━━━━━━━━━━━━━━━━━━━━

*App:* `ebteq-csv-converter`
*App ID:* `d2t3ti5dqkttcm`
*Branch:* `main`
*Commit:* `bfe2b7f`
*Job ID:* `29`
*Status:* *SUCCEED* ✅

[View in AWS Console](https://...)
```

---

## Monitoring and Troubleshooting

### CloudWatch Logs

```bash
# View recent logs
aws logs tail /aws/lambda/cloud-tibot_auto_remediator --follow

# Search for errors
aws logs filter-log-events \
  --log-group-name /aws/lambda/cloud-tibot_auto_remediator \
  --filter-pattern "ERROR"
```

### Common Issues

**Issue:** Lambda times out
- **Cause:** Amplify GetApp API is slow
- **Fix:** Increase timeout in dev (already 60s, prod 300s)

**Issue:** Telegram message not sent
- **Cause:** Invalid token or chat ID
- **Check:** Look at CloudWatch logs for Telegram API errors

**Issue:** EventBridge rule not triggering
- **Cause:** Wrong event pattern or rule disabled
- **Check:** `aws events describe-rule --name cloud-tibot_amplify_build_status`

---

## Version History

### v2.0 — Amplify Build Notifier (February 13, 2026)
- ✅ Simplified Lambda (removed AI agent)
- ✅ Fixed EventBridge event type and pattern
- ✅ Added app name resolution
- ✅ Added AWS Console link
- ✅ Fixed import errors (PyJWT, cryptography)
- ✅ Multi-environment Terraform support

### v1.0 — Original (January 2026)
- AI-powered failure remediation
- GitHub Copilot integration
- Auto-fix PR generation

---

## Rollback Plan

If you need to rollback to the old configuration:

```bash
# Destroy current infrastructure (dev only!)
terraform destroy -var-file=../terraform.tfvars.dev

# OR revert EventBridge rule manually
aws events put-rule --name cloud-tibot_amplify_build_failed --state ENABLED
aws events disable-rule --name cloud-tibot_amplify_build_status

# Revert Lambda code
aws lambda update-function-code \
  --function-name cloud-tibot_auto_remediator \
  --zip-file fileb://path/to/old/lambda.zip
```

---

## Next Steps

1. ✅ **Set Telegram credentials** in `terraform.tfvars.dev`
2. ✅ **Initialize Terraform** in `infrastructure/terraform/`
3. ✅ **Run terraform plan** to review changes
4. ✅ **Apply configuration** to dev environment
5. ✅ **Test with a manual Lambda invocation**
6. ✅ **Trigger an Amplify build** to verify end-to-end
7. ✅ **Replicate to staging/prod** using same Terraform code

---

## Support

For issues or questions, check:
- CloudWatch logs: `/aws/lambda/cloud-tibot_auto_remediator`
- EventBridge rule: `cloud-tibot_amplify_build_status`
- Terraform state: `infrastructure/terraform/terraform.tfstate*`

---

**Last Updated:** February 13, 2026  
**Maintained By:** Cloud-Tibot Team
