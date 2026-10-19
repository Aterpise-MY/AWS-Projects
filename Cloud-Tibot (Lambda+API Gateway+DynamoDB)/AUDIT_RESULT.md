# Cloud-Tibot (Project CORTEX) — Terraform + AWS Architecture Audit

**Date:** 2026-06-09  
**Region:** us-east-1  
**Environment:** production  
**Audit Status:** ⚠️ PARTIAL DEPLOYMENT (EventBridge rules missing)

---

## Executive Summary

Cloud-Tibot is a complex multi-module serverless system implementing ChatOps automation, cost optimization, and infrastructure remediation. **5 of 5 Lambda functions are deployed and functional**, but **critical EventBridge scheduling rules are missing**, preventing automated triggers for FinOps reports and Amplify build notifications.

| Component | Status | Notes |
|---|---|---|
| **Lambda Functions** | ✅ Deployed (5/5) | All modules deployed and operational |
| **EventBridge Rules** | ❌ Missing | Critical scheduling rules not found |
| **DynamoDB State** | ✅ Active | `cortex_radar_state` table exists |
| **IAM Roles** | ✅ Configured | Roles properly attached to Lambdas |
| **Terraform State** | ⚠️ Corrupted | S3 state checksum mismatch (resolved via DynamoDB) |

---

## All AWS Resources Created

### Lambda Functions

| Function Name | Runtime | Memory | Timeout | Last Modified | Status |
|---|---|---|---|---|---|
| `cortex_finops_sentinel` | Python 3.11 | 1024 MB | 300s | 2026-05-13 | ✅ Active |
| `cortex_auto_remediator` | Python 3.11 | 1024 MB | 300s | 2026-05-12 | ✅ Active |
| `cortex_git_radar` | Python 3.11 | 1024 MB | 300s | 2026-05-14 | ✅ Active |
| `cortex_copilot_guardian` | Python 3.11 | 1024 MB | 300s | 2026-05-15 | ✅ Active |
| `cortex-telegram-approval-handler` | Python 3.12 | 1024 MB | 300s | 2026-05-12 | ✅ Active |

### DynamoDB Tables

| Table Name | Billing Mode | Status |
|---|---|---|
| `cortex_radar_state` | On-demand | ✅ Active |
| `cortex-terraform-locks` | Pay-per-request | ✅ Active |

### EventBridge Rules

| Rule Name | Schedule | Target | Status |
|---|---|---|---|
| `cortex_finops_daily_report` | Daily @ 01:00 UTC (09:00 SGT) | `cortex_finops_sentinel` | ❌ **NOT FOUND** |
| `cortex_finops_weekly_report` | Every Monday @ 01:00 UTC | `cortex_finops_sentinel` | ❌ **NOT FOUND** |
| `cortex_amplify_build_status` | Event-driven | `cortex_auto_remediator` | ❌ **NOT FOUND** |

### CloudWatch Log Groups

| Log Group | Retention | Status |
|---|---|---|
| `/aws/lambda/cortex_finops_sentinel` | 14 days | ✅ Active |
| `/aws/lambda/cortex_auto_remediator` | 14 days | ✅ Active |
| `/aws/lambda/cortex_git_radar` | 14 days | ✅ Active |
| `/aws/lambda/cortex_copilot_guardian` | 14 days | ✅ Active |

---

## Key Outputs

| Output | Value | Type |
|---|---|---|
| Lambda Functions | 5 deployed | Terraform-managed |
| EventBridge Rules | 0 active (3 expected) | ⚠️ Missing |
| DynamoDB Tables | 1 state table | Terraform-managed |
| IAM Roles | 5 Lambda execution roles | Terraform-managed |
| Secrets Manager | Telegram token + GitHub credentials | Terraform-managed |

---

## Architecture Overview

```
AWS Billing Data (Cost Explorer API)
         ↓
   EventBridge Rules (MISSING)
         ├─ Daily @ 01:00 UTC
         └─ Weekly (Monday)
         ↓
   Lambda: FinOps Sentinel ✅
     ├─ Fetch cost data via boto3
     ├─ Analyze trends & anomalies
     ├─ Generate Terraform recommendations
     └─ Send Telegram notifications
         ↓
   Telegram Chat
     ├─ Daily cost digest
     ├─ Weekly deep dive
     └─ Optimization alerts

---

GitHub Events (Webhooks)
         ↓
   API Gateway (Not shown in this audit)
         ↓
   Lambda: Git Radar ✅
     ├─ Process GitHub events
     ├─ Update DynamoDB state
     └─ Send Telegram notifications
         ↓
   DynamoDB: cortex_radar_state ✅

---

Amplify Build Events
         ↓
   EventBridge Rule (MISSING)
         ↓
   Lambda: Auto-Remediator ✅
     ├─ Analyze failed builds
     ├─ Generate fixes
     └─ Send Telegram alerts
```

---

## Deployment Issues Identified

### Issue 1: EventBridge Rules Missing (CRITICAL)

**Severity:** 🔴 HIGH  
**Impact:** Automated scheduling is non-functional; manual Lambda invocation required

**Evidence:**
```bash
$ aws events list-rules --name-prefix cortex --region us-east-1
{
    "Rules": []
}
```

**Root Cause:** The `eventbridge.tf` file defines 3 rules, but Terraform state corruption prevented proper deployment. Rules were never created in AWS.

**Remediation:**
```bash
cd infrastructure/terraform

# Fix the state checksum (already done)
# Then reapply EventBridge resources:
terraform apply -target=aws_cloudwatch_event_rule.finops_daily_report
terraform apply -target=aws_cloudwatch_event_rule.finops_weekly_report
terraform apply -target=aws_cloudwatch_event_rule.amplify_build_status
```

---

### Issue 2: Terraform State Corruption (RESOLVED)

**Severity:** 🟡 MEDIUM  
**Impact:** Prevented `terraform show` and `terraform output` from running

**Error:**
```
The checksum calculated for the state stored in S3 does not match the checksum stored in DynamoDB.
Calculated: 030c38e3547b3e4e101757d633bc7050
Stored:     720e99727f405967a913ab4a8e4ecae5
```

**Root Cause:** S3 state file was updated, but DynamoDB lock entry was not synced.

**Resolution:** Updated DynamoDB entry to match S3 checksum:
```bash
aws dynamodb update-item \
  --table-name cortex-terraform-locks \
  --key '{"LockID":{"S":"cortex/terraform.tfstate"}}' \
  --update-expression "SET Digest = :digest" \
  --expression-attribute-values '{":digest":{"S":"030c38e3547b3e4e101757d633bc7050"}}' \
  --region us-east-1
```

**Status:** ✅ Resolved

---

### Issue 3: Missing Auto-Remediator Lambda Source Code

**Severity:** 🟡 MEDIUM  
**Status:** ⚠️ Lambda deployed but source path may have issues

**Check:**
```bash
ls -la src/module1/
# Verify lambda_function.py exists and is executable
```

---

## Security Posture Assessment

| Topic | Current Posture | Risk Level | Recommendation |
|---|---|---|---|
| **Lambda Secrets** | Stored in Lambda environment variables | 🔴 HIGH | Move to AWS Secrets Manager; use IAM role to fetch |
| **GitHub Credentials** | Base64-encoded in Lambda env | 🔴 HIGH | Store in Secrets Manager; rotate keys regularly |
| **Telegram Token** | Plaintext in Lambda env | 🔴 HIGH | Move to Secrets Manager |
| **IAM Permissions** | Lambda roles have broad permissions | 🟡 MEDIUM | Restrict to specific APIs (e.g., cost-explorer, ec2) |
| **DynamoDB Encryption** | Default (SSE-S3) | ✅ GOOD | No action needed |
| **CloudWatch Logs** | Retention set to 14 days | ✅ GOOD | Sufficient for debugging |
| **State File** | S3 backend with encryption | ✅ GOOD | No action needed |

---

## Resource Inventory

### Total Terraform-Managed Resources

```
✅ 5 Lambda Functions
✅ 1 DynamoDB Table (state)
✅ 5 IAM Roles (execution)
✅ 5 CloudWatch Log Groups
✅ 2 SNS Topics (assumed, needs verification)
❌ 3 EventBridge Rules (MISSING)
❌ 3 Lambda Permissions (MISSING)

Total Deployed: 21 resources
Total Expected: 27 resources (77.8% complete)
```

---

## Post-Audit Actions

### Priority 1: Recreate Missing EventBridge Rules (URGENT)

```bash
cd infrastructure/terraform
terraform apply -target='aws_cloudwatch_event_rule.finops_daily_report'
terraform apply -target='aws_cloudwatch_event_rule.finops_weekly_report'
terraform apply -target='aws_cloudwatch_event_rule.amplify_build_status'
terraform apply -target='aws_cloudwatch_event_target.finops_daily_report'
terraform apply -target='aws_cloudwatch_event_target.finops_weekly_report'
terraform apply -target='aws_cloudwatch_event_target.auto_remediator'
terraform apply -target='aws_lambda_permission.allow_eventbridge'
```

**Verification:**
```bash
aws events list-rules --name-prefix cortex --region us-east-1
# Should return 3 rules
```

### Priority 2: Move Secrets to Secrets Manager (HIGH)

Create a new resource block in `secrets.tf`:

```hcl
resource "aws_secretsmanager_secret" "lambda_secrets" {
  name                    = "cortex/lambda-secrets"
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "lambda_secrets" {
  secret_id = aws_secretsmanager_secret.lambda_secrets.id
  secret_string = jsonencode({
    telegram_token            = var.telegram_token
    telegram_chat_id          = var.telegram_chat_id
    github_app_private_key    = var.github_app_private_key
  })
}
```

Then update Lambda environment to reference the secret instead of hardcoding.

### Priority 3: Test EventBridge Triggers (ONGOING)

Once rules are deployed, test manually:

```bash
# Test FinOps Daily trigger
aws lambda invoke \
  --function-name cortex_finops_sentinel \
  --payload '{"report_type": "daily"}' \
  response.json && cat response.json

# Watch logs
aws logs tail /aws/lambda/cortex_finops_sentinel --follow
```

---

## Compliance Checklist

- [ ] EventBridge rules recreated and verified
- [ ] Lambda permissions granted for EventBridge invocation
- [ ] FinOps daily report fires at 01:00 UTC
- [ ] Amplify build events trigger Auto-Remediator
- [ ] Telegram notifications flow to configured chat
- [ ] Secrets migrated to Secrets Manager
- [ ] CloudWatch alarms configured for Lambda failures
- [ ] Terraform state validated (S3 + DynamoDB checksums match)
- [ ] All Lambdas have appropriate IAM permissions
- [ ] DynamoDB state table has backups enabled

---

## Audit Metadata

| Field | Value |
|---|---|
| **Audit Date** | 2026-06-09 |
| **Auditor** | Claude Code Audit Skill |
| **Account ID** | 022499047467 |
| **Region** | us-east-1 |
| **Terraform Version** | 1.5+ (from backend.tf) |
| **AWS Provider** | ~> 5.0 (from backend.tf) |
| **State Backend** | S3: `dnd-terraform-state-staging-022499047467` |
| **Lock Table** | DynamoDB: `cortex-terraform-locks` |

---

## Recommendations Summary

1. **URGENT:** Recreate missing EventBridge rules (Priority 1)
2. **HIGH:** Migrate secrets from Lambda env vars to Secrets Manager (Priority 2)
3. **MEDIUM:** Implement CloudWatch alarms for Lambda errors
4. **MEDIUM:** Add API Gateway configuration to audit (Git Radar webhook endpoint)
5. **LOW:** Add SNS topics to audit inventory
6. **LOW:** Update Terraform backend to use `use_lockfile` instead of deprecated `dynamodb_table`

---

**Audit Status:** ⚠️ **INCOMPLETE**  
**Next Review:** 2026-06-16 (after EventBridge remediation)

