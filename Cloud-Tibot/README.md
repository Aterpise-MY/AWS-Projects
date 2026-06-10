# FinOps Sentinel - AWS Cost Optimization Alerts

Serverless Lambda function that monitors AWS cost anomalies and sends real-time alerts to Telegram for cost optimization notifications.

## Overview

FinOps Sentinel is a lightweight, serverless cost monitoring solution that detects unusual AWS spending patterns and sends instant alerts to your Telegram chat. It integrates with AWS services via EventBridge and DynamoDB to track cost anomalies without manual intervention.

## Architecture

```
AWS Cost Anomaly Detection
         │
         ▼
    EventBridge (Triggers on cost anomalies)
         │
         ▼
   Lambda Function (FinOps Sentinel)
    └─ Analyzes cost data
    └─ Stores history in DynamoDB
    └─ Sends alert to Telegram
         │
         ▼
   Telegram Chat (Real-time notification)
```

## Infrastructure Components

- **Lambda Function** (Python 3.11) — Cost anomaly analyzer and Telegram notifier
- **API Gateway v2** (HTTP API) — Webhook endpoint for cost alerts
- **DynamoDB Table** (On-demand) — Stores cost history and anomaly records
- **EventBridge Rule** — Triggers Lambda on cost anomalies
- **IAM Role** — Least privilege permissions for Lambda
- **CloudWatch Logs** — All execution logs (14-day retention)

## Features

✅ **Real-time Cost Alerts** — Auto schedule Telegram notifications for every morning 
✅ **Cost History Tracking** — DynamoDB stores all cost events for trend analysis  
✅ **Anomaly Detection** — AWS native Cost Anomaly Detection service  
✅ **Customizable Thresholds** — Set alert sensitivity via Terraform variables  
✅ **Telegram Integration** — Formatted messages with cost details  
✅ **Production-Ready** — Least privilege IAM, encryption, logging  

## Prerequisites

- **Terraform** >= 1.5.0
- **AWS Account** with Cost Anomaly Detection enabled
- **Telegram Bot Token** (create with @BotFather)
- **Telegram Chat ID** (your chat ID)
- **AWS CLI** configured with credentials

## Quick Start

### 1. Create Telegram Bot

1. Open Telegram and chat with @BotFather
2. Send `/newbot`
3. Follow prompts to create your bot
4. Save the bot token (looks like `123456789:ABCdefGHIjklmNOpqrsTUVwxyz`)
5. Get your Chat ID by sending `/getids` to @userinfobot

### 2. Configure Terraform Variables

```bash
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`:

```hcl
# Telegram Configuration
telegram_token   = "your-bot-token-here"
telegram_chat_id = "your-chat-id-here"

# AWS Configuration
aws_region   = "us-east-1"
project_name = "finops"
environment  = "prod"

# Cost Alert Settings
cost_anomaly_threshold = 100  # Alert if costs increase by 100% or more
```

### 3. Deploy

```bash
terraform init
terraform plan
terraform apply
```

### 4. Test

Wait 5-10 minutes for AWS Cost Anomaly Detection to initialize, then trigger a test:

```bash
# Invoke Lambda manually
aws lambda invoke \
  --function-name finops-sentinel \
  --payload '{"test": true}' \
  response.json
```

Check Telegram for test notification.

## How It Works

### Cost Anomaly Detection Flow

1. **AWS Cost Explorer** monitors your spending patterns
2. **Anomaly Detection** identifies unusual cost increases
3. **EventBridge Rule** triggers on anomaly events
4. **Lambda Function** receives the event
5. **FinOps Sentinel** analyzes the cost data
6. **DynamoDB** stores the anomaly record
7. **Telegram Bot** sends instant alert to your chat

### Alert Message Example

```
💰 AWS Cost Anomaly Detected!

Service: Amazon EC2
Cost Increase: +$450.00 (150% above normal)
Current Cost: $750.00
Normal Cost: $300.00

⚠️ Action: Review EC2 instances and consider optimization
```

## Configuration

### Terraform Variables

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `telegram_token` | string | — | Telegram bot token (required) |
| `telegram_chat_id` | string | — | Telegram chat ID (required) |
| `aws_region` | string | `us-east-1` | AWS region |
| `project_name` | string | `finops` | Project name prefix |
| `environment` | string | `prod` | Environment tag |
| `lambda_timeout` | number | `60` | Lambda timeout in seconds |
| `lambda_memory` | number | `256` | Lambda memory in MB |
| `cost_anomaly_threshold` | number | `100` | Anomaly threshold percentage |

## Deployment

### Option 1: Full Terraform Deployment

```bash
# Step 1: Initialize Terraform
terraform init

# Step 2: Review changes
terraform plan

# Step 3: Deploy
terraform apply -auto-approve

# Step 4: Get outputs
terraform output
```

### Option 2: Manual AWS CLI

```bash
# Create IAM role
aws iam create-role --role-name finops-lambda-role \
  --assume-role-policy-document file://trust-policy.json

# Create Lambda function
aws lambda create-function \
  --function-name finops-sentinel \
  --runtime python3.11 \
  --role arn:aws:iam::ACCOUNT_ID:role/finops-lambda-role \
  --handler lambda_function.lambda_handler \
  --zip-file fileb://lambda.zip

# Create DynamoDB table
aws dynamodb create-table \
  --table-name finops-cost-history \
  --attribute-definitions AttributeName=anomaly_id,AttributeType=S \
  --key-schema AttributeName=anomaly_id,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST
```

## Lambda Function

**Location:** `src/module3/lambda_function.py`

### Handler Signature

```python
def lambda_handler(event, context):
    """
    Process cost anomaly events and send Telegram alerts.
    
    Args:
        event: EventBridge event containing cost anomaly data
        context: Lambda context object
    
    Returns:
        dict: Status response
    """
    # Parse cost anomaly event
    # Store in DynamoDB
    # Format Telegram message
    # Send notification
    # Return success/failure
```

### Key Features

- Parses EventBridge cost anomaly events
- Extracts service name, cost increase percentage, amount
- Stores anomaly record in DynamoDB with timestamp
- Formats human-readable Telegram message
- Sends instant notification via Telegram Bot API
- Handles errors gracefully with CloudWatch logging

## DynamoDB Schema

**Table Name:** `finops-cost-history`

**Attributes:**
- `anomaly_id` (String, Partition Key) — Unique anomaly identifier
- `timestamp` (Number) — Unix timestamp
- `service` (String) — AWS service name (e.g., "Amazon EC2")
- `cost_increase_percentage` (Number) — Percentage increase
- `cost_increase_amount` (Number) — Dollar amount increase
- `current_cost` (Number) — Current hourly/daily cost
- `baseline_cost` (Number) — Normal cost
- `message_sent` (Boolean) — Whether Telegram notification sent

**TTL:** 90 days (automatic cleanup of old records)

## Telegram Integration

### Message Format

Alerts are formatted with:
- ⚠️ **Alert Icon** — Visual indicator
- **Service Name** — Which AWS service
- **Cost Increase** — Percentage and dollar amount
- **Action Suggestion** — Recommended next step

### Customization

Edit the message template in `src/module3/lambda_function.py`:

```python
def format_message(anomaly):
    return f"""
💰 AWS Cost Anomaly Detected!

Service: {anomaly['service']}
Cost Increase: +${anomaly['cost_increase_amount']:.2f} ({anomaly['cost_increase_percentage']}%)
Current Cost: ${anomaly['current_cost']:.2f}
Baseline Cost: ${anomaly['baseline_cost']:.2f}

⚠️ Action: Review {anomaly['service']} resources
    """
```

## Monitoring and Logs

### CloudWatch Logs

All Lambda executions logged to:

```bash
/aws/lambda/finops-sentinel
```

View logs:

```bash
# Real-time logs
aws logs tail /aws/lambda/finops-sentinel --follow

# Specific time range
aws logs filter-log-events \
  --log-group-name /aws/lambda/finops-sentinel \
  --start-time $(date -d '1 hour ago' +%s)000
```

### Metrics

CloudWatch automatically tracks:
- **Invocations** — Number of anomalies detected
- **Duration** — Lambda execution time (avg <2 seconds)
- **Errors** — Failed notifications
- **Throttles** — Rate limiting (none expected)

## Cost Estimates

**Monthly Cost Breakdown:**
- **Lambda:** ~$0.50 (millions of free invocations)
- **DynamoDB:** ~$0.30 (on-demand, <1GB)
- **CloudWatch Logs:** ~$0.50 (14-day retention)
- **EventBridge:** Free (AWS service events)
- **Total:** ~$1.30/month

## Security Considerations

| Topic | Current Posture | Hardening |
|-------|-----------------|-----------|
| **Telegram Token** | In Terraform variables | Move to AWS Secrets Manager |
| **DynamoDB Encryption** | Enabled (AWS managed keys) | Use customer-managed CMK |
| **IAM Permissions** | Least privilege per Lambda | Regularly audit |
| **CloudWatch Logs** | 14-day retention | Increase retention as needed |
| **API Gateway CORS** | Restricted | Add IP whitelisting |
| **Lambda Code** | Plain Python | Add input validation |

### Production Hardening

```bash
# Store secrets in AWS Secrets Manager
aws secretsmanager create-secret \
  --name finops/telegram-token \
  --secret-string "your-token"

# Update Lambda to use secret
# Edit src/module3/lambda_function.py to fetch from Secrets Manager
```

## Troubleshooting

### Lambda Not Triggered

**Problem:** EventBridge rule not firing  
**Solution:** Verify Cost Anomaly Detection is enabled in AWS Cost Explorer

```bash
# Check Cost Anomaly Detection status
aws ce describe-cost-anomaly-detectors
```

### Telegram Not Receiving Messages

**Problem:** Alerts not appearing in Telegram  
**Solution:** Check CloudWatch logs for errors

```bash
aws logs tail /aws/lambda/finops-sentinel --follow
```

Common issues:
- Invalid bot token (wrong format or revoked)
- Wrong chat ID (get via @userinfobot)
- Bot not added to chat (add bot to group first)

### DynamoDB Permission Error

**Problem:** Lambda can't write to DynamoDB  
**Solution:** Verify IAM role has `dynamodb:PutItem` permission

```bash
aws iam get-role-policy --role-name finops-lambda-role \
  --policy-name finops-policy
```

## Cleanup

To destroy all resources:

```bash
terraform destroy
```

This removes:
- Lambda function and logs
- DynamoDB table (data deleted)
- IAM role and policies
- EventBridge rule
- API Gateway

**Note:** S3 buckets (if any) and Cost Anomaly Detection settings are NOT deleted.

## Updating

### Update Lambda Code

```bash
# Edit src/module3/lambda_function.py
# Then redeploy:
terraform apply -replace="aws_lambda_function.finops_sentinel"
```

### Update Telegram Token

```bash
# Update terraform.tfvars
vim terraform.tfvars

# Redeploy
terraform apply
```

### Update Cost Threshold

```bash
# Edit terraform.tfvars
variable "cost_anomaly_threshold" {
  default = 150  # Increased from 100
}

terraform apply
```

## Advanced Configuration

### Custom Alerts Per Service

Modify `src/module3/lambda_function.py` to alert differently for specific services:

```python
SERVICE_ALERT_THRESHOLDS = {
    "Amazon EC2": 50,        # Alert if EC2 costs increase 50%+
    "Amazon RDS": 25,        # Alert if RDS costs increase 25%+
    "AWS Lambda": 200,       # Alert if Lambda costs increase 200%+
}
```

### Integration with Cost Optimization Tools

Send alerts to:
- **Slack:** Add Slack webhook integration
- **PagerDuty:** Send critical alerts
- **CloudWatch Alarms:** Create Dashboard widgets
- **Email:** SNS topic forwarding

## Support & Feedback

For questions about FinOps Sentinel:
1. Check CloudWatch logs: `aws logs tail /aws/lambda/finops-sentinel`
2. Review Terraform outputs: `terraform output`
3. Test Lambda manually: `aws lambda invoke --function-name finops-sentinel`
4. Verify Telegram bot permissions in @BotFather

---

**Status:** ✅ Production Ready  
**Last Updated:** June 10, 2026  
**Terraform Version:** 1.5+  
**AWS Provider:** ~> 5.0  
**Python Runtime:** 3.11+  
**License:** MIT
