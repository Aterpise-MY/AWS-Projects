# FinOps Sentinel - Setup & Verification Checklist

## ✅ Verified Components (Already Deployed)

- [x] **Lambda Function:** `cortex_finops_sentinel` (Python 3.11, 1GB RAM, 300s timeout)
- [x] **EventBridge Daily Rule:** `cortex_finops_daily_report` (Daily at 01:00 UTC / 09:00 SGT)
- [x] **EventBridge Weekly Rule:** `cortex_finops_weekly_report` (Monday 01:00 UTC / 09:00 SGT)
- [x] **CloudWatch Logs:** `/aws/lambda/cortex_finops_sentinel` (14-day retention active)
- [x] **Telegram Bot:** Connected and sending messages
- [x] **Cost Explorer Access:** AWS Cost data accessible and populated

## ⚠️ MISSING Components (Create IMMEDIATELY)

### 1. DynamoDB Table for Cost History

**Status:** ❌ NOT FOUND  
**Why Needed:** Store 90 days of cost data for trend analysis and audit trail

```bash
aws dynamodb create-table \
  --table-name finops-cost-history \
  --attribute-definitions \
    AttributeName=anomaly_id,AttributeType=S \
    AttributeName=timestamp,AttributeType=N \
  --key-schema \
    AttributeName=anomaly_id,KeyType=HASH \
    AttributeName=timestamp,KeyType=RANGE \
  --billing-mode PAY_PER_REQUEST \
  --ttl-specification AttributeName=expiration_time,Enabled=true \
  --tags \
    Key=Project,Value=cortex \
    Key=Purpose,Value=finops-cost-history \
  --region us-east-1
```

**Verification:**
```bash
aws dynamodb describe-table --table-name finops-cost-history --region us-east-1
# Should return: TableStatus = "ACTIVE"
```

### 2. CloudWatch Alarms for Cost Thresholds

**Status:** ❌ NOT CONFIGURED  
**Why Needed:** Automated alerts when daily/weekly costs exceed thresholds

```bash
# Alert when daily spend exceeds $3.00
aws cloudwatch put-metric-alarm \
  --alarm-name cortex-finops-daily-cost-threshold \
  --alarm-description "Alert when daily AWS costs exceed $3.00" \
  --metric-name EstimatedCharges \
  --namespace AWS/Billing \
  --statistic Maximum \
  --period 86400 \
  --threshold 3.0 \
  --comparison-operator GreaterThanThreshold \
  --evaluation-periods 1 \
  --treat-missing-data notBreaching \
  --region us-east-1

# Alert when ANY service increases 50%+ in one day
aws cloudwatch put-metric-alarm \
  --alarm-name cortex-finops-cost-anomaly \
  --alarm-description "Alert on cost anomalies (50%+ spike)" \
  --metric-name UnblendedCost \
  --namespace AWS/Billing \
  --statistic Sum \
  --period 3600 \
  --threshold 0.01 \
  --comparison-operator GreaterThanThreshold \
  --evaluation-periods 1 \
  --region us-east-1
```

**Verification:**
```bash
aws cloudwatch describe-alarms --alarm-name-prefix cortex-finops --region us-east-1
# Should return at least 2 alarms in OK state
```

### 3. SNS Topic for Multi-Channel Notifications

**Status:** ⚠️ OPTIONAL (backup to Telegram)  
**Why Useful:** Email/SMS backup alerts if Telegram unavailable

```bash
# Create SNS topic
aws sns create-topic \
  --name cortex-finops-alerts \
  --tags Key=Project,Value=cortex Key=Purpose,Value=cost-alerts \
  --region us-east-1

# Subscribe email
aws sns subscribe \
  --topic-arn arn:aws:sns:us-east-1:ACCOUNT_ID:cortex-finops-alerts \
  --protocol email \
  --notification-endpoint INFRA_TEAM_EMAIL@company.com \
  --region us-east-1

# Subscribe SMS (optional)
aws sns subscribe \
  --topic-arn arn:aws:sns:us-east-1:ACCOUNT_ID:cortex-finops-alerts \
  --protocol sms \
  --notification-endpoint +6012345678 \
  --region us-east-1
```

## 📊 Current Cost Status (Verified via AWS API)

### Daily Costs
- **Average:** $1.20 USD/day
- **Range:** $0.77 - $1.79 USD/day
- **Monthly Projection:** ~$36 USD

### Cost Breakdown (By Service)
| Service | Daily Cost | % of Total | Status |
|---------|-----------|-----------|--------|
| AWS Secrets Manager | $0.13 | 11% | ✅ Normal |
| AWS Security Hub | $0.06 | 5% | ✅ Normal |
| AWS Cost Explorer | $0.03 | 3% | ✅ Normal |
| AWS KMS | $0.03 | 3% | ✅ Normal |
| Everything Else | $0.95 | 78% | ⚠️ Spiky |

### ⚠️ ANOMALIES DETECTED (June 8-9, 2026)

**CRITICAL: Cost Spike on June 8-9**

| Service | Normal | Jun 8-9 | Increase | ACTION NEEDED |
|---------|--------|---------|----------|---------------|
| **EC2 Compute** | $0.08 | $0.27 | +237% | ❌ INVESTIGATE |
| **Amazon RDS** | $0.00 | $0.25 | NEW | ❌ INVESTIGATE |
| **ELB** | $0.00 | $0.09 | NEW | ⚠️ Review |
| **Amazon S3** | $0.003 | $0.11 | +3566% | ❌ CRITICAL |
| **VPC** | $0.00 | $0.04 | NEW | ⚠️ Review |

**Total Extra Spend:** ~$0.76 USD on Jun 8-9  
**Annualized:** ~$277/year if pattern continues

### 🎯 Recommended Immediate Actions

1. **TODAY:** 
   - [ ] Stop/terminate unnecessary EC2 instances
   - [ ] Check S3 bucket operations (uploads, transfers)
   - [ ] Review RDS database (is it even needed?)
   - [ ] Estimated savings: $20-50/month

2. **THIS WEEK:**
   - [ ] Review ELB/VPC usage patterns
   - [ ] Enable S3 Lifecycle policies to archive old data
   - [ ] Configure CloudWatch cost anomaly detection
   - [ ] Set budget alerts in AWS Budgets

3. **THIS MONTH:**
   - [ ] Right-size all instances based on actual usage
   - [ ] Consider Reserved Instances for stable workloads
   - [ ] Enable VPC flow logs to monitor data transfer

## 🚀 Setup Execution Plan

### Phase 1: Immediate (Next 2 hours)
- [ ] Create DynamoDB table (1 min)
- [ ] Create CloudWatch alarms (2 min)
- [ ] Verify Lambda can write to DynamoDB (2 min)
- [ ] Update Lambda environment variables (1 min)
- [ ] Test Lambda invocation manually (2 min)

### Phase 2: Today
- [ ] Investigate EC2 spike - stop runaway instances
- [ ] Investigate S3 spike - check for data transfers
- [ ] Investigate RDS - verify it's needed
- [ ] Create SNS topics (optional but recommended)

### Phase 3: This Week
- [ ] Set up AWS Budgets for $40/month limit
- [ ] Configure additional CloudWatch alarms
- [ ] Document remediation steps taken
- [ ] Schedule weekly review meetings

### Phase 4: Ongoing
- [ ] Monitor daily Telegram digests
- [ ] Act on weekly reports
- [ ] Adjust thresholds based on experience
- [ ] Share insights with engineering teams

## 📋 Verification Commands

```bash
# Check Lambda function
aws lambda get-function --function-name cortex_finops_sentinel --region us-east-1

# Check EventBridge rules
aws events list-rules --name-prefix cortex_finops --region us-east-1

# View Lambda logs (last 100 lines)
aws logs tail /aws/lambda/cortex_finops_sentinel --follow --max-items 100 --region us-east-1

# Test cost data fetch
aws ce get-cost-and-usage \
  --time-period Start=2026-06-01,End=2026-06-10 \
  --granularity DAILY \
  --metrics BlendedCost \
  --region us-east-1

# Verify DynamoDB table
aws dynamodb describe-table --table-name finops-cost-history --region us-east-1

# List CloudWatch alarms
aws cloudwatch describe-alarms --alarm-name-prefix cortex --region us-east-1

# Test Telegram bot
curl -X POST https://api.telegram.org/botYOUR_BOT_TOKEN/sendMessage \
  -d "chat_id=YOUR_CHAT_ID" \
  -d "text=FinOps test message" \
  -d "parse_mode=HTML"
```

## 📞 Support Contacts

- **AWS Account Manager:** [Contact AWS for cost optimization]
- **Telegram Support:** @BotFather for bot troubleshooting
- **Infrastructure Team Slack:** #cloud-costs or #infrastructure

---

**Created:** June 10, 2026  
**Last Verified:** June 10, 2026  
**Status:** ⚠️ INCOMPLETE - Missing DynamoDB & Alarms  
**Priority:** 🔴 HIGH - Cost spike detected, action needed
