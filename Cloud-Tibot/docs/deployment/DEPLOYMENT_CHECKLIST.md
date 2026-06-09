# Project CORTEX - Deployment Checklist

Use this checklist to ensure a smooth deployment of your serverless ChatOps infrastructure.

## Pre-Deployment Checklist

### 1. Prerequisites
- [ ] Terraform >= 1.5.0 installed (`terraform version`)
- [ ] AWS CLI configured (`aws sts get-caller-identity`)
- [ ] Sufficient AWS permissions (Lambda, API Gateway, DynamoDB, IAM, EventBridge)
- [ ] Valid Telegram Bot Token obtained from @BotFather
- [ ] Telegram Chat ID identified (use @userinfobot)
- [ ] GitHub Personal Access Token created with appropriate scopes

### 2. Configuration Files
- [ ] Created `terraform.tfvars` from `terraform.tfvars.example`
- [ ] Updated `telegram_token` in `terraform.tfvars`
- [ ] Updated `telegram_chat_id` in `terraform.tfvars`
- [ ] Updated `github_pat` in `terraform.tfvars`
- [ ] Reviewed and adjusted `aws_region` if needed
- [ ] Customized `project_name` if desired

### 3. Lambda Source Code
- [ ] Python 3.11 code exists in `src/module1/lambda_function.py`
- [ ] Python 3.11 code exists in `src/module2/lambda_function.py`
- [ ] Python 3.11 code exists in `src/module3/lambda_function.py`
- [ ] Each module has `lambda_handler(event, context)` function
- [ ] Tested Lambda functions locally (optional but recommended)

## Deployment Steps

### 4. Terraform Initialization
```bash
terraform init
```
- [ ] Terraform initialized successfully
- [ ] Provider plugins downloaded
- [ ] Backend configured (if using remote state)

### 5. Validation
```bash
terraform validate
```
- [ ] Configuration validated without errors
- [ ] All syntax correct

### 6. Plan Review
```bash
terraform plan
```
- [ ] Plan shows 30+ resources to create
- [ ] No unexpected deletions or modifications
- [ ] IAM policies appear correct
- [ ] Lambda functions reference correct source directories

### 7. Infrastructure Deployment
```bash
terraform apply
```
- [ ] Reviewed plan output
- [ ] Typed "yes" to confirm
- [ ] All resources created successfully
- [ ] No errors during apply

### 8. Outputs Verification
```bash
terraform output
```
- [ ] `api_gateway_endpoint` URL retrieved
- [ ] `github_webhook_url` URL retrieved
- [ ] `finops_webhook_url` URL retrieved
- [ ] All Lambda function names displayed

## Post-Deployment Configuration

### 9. GitHub Webhook Setup
- [ ] Navigated to GitHub repository settings
- [ ] Added webhook with `github_webhook_url`
- [ ] Set content type to `application/json`
- [ ] Selected appropriate events (push, pull_request, etc.)
- [ ] Webhook created and active
- [ ] Test delivery succeeded

### 10. EventBridge Testing
- [ ] Identified an Amplify app for testing (or created one)
- [ ] Triggered a build failure (optional)
- [ ] Verified Telegram notification received
- [ ] Checked CloudWatch Logs for execution

### 11. FinOps Webhook Integration
- [ ] Configured cost monitoring tool/script to use `finops_webhook_url`
- [ ] Tested webhook with sample payload
- [ ] Verified Telegram alert received

## Monitoring Setup

### 12. CloudWatch Logs
- [ ] Verified log groups created for all 3 Lambda functions
- [ ] Verified API Gateway log group created
- [ ] Set up CloudWatch Insights queries (optional)
- [ ] Configured log retention as needed

### 13. CloudWatch Alarms (Optional)
- [ ] Created alarm for Lambda errors
- [ ] Created alarm for Lambda duration
- [ ] Created alarm for API Gateway 5xx errors
- [ ] Created alarm for DynamoDB throttling

## Security Hardening

### 14. Secrets Management (Recommended for Production)
- [ ] Migrated secrets to AWS Secrets Manager
- [ ] Updated Lambda environment variables to reference secrets
- [ ] Removed plaintext secrets from `terraform.tfvars`
- [ ] Added IAM permissions for Secrets Manager access

### 15. Network Security (Optional)
- [ ] Deployed Lambdas in VPC (if accessing private resources)
- [ ] Configured security groups
- [ ] Set up VPC endpoints for AWS services

### 16. API Gateway Security
- [ ] Implemented API key authentication (if needed)
- [ ] Configured rate limiting/throttling
- [ ] Set up AWS WAF rules (optional)
- [ ] Enabled request validation

## Testing & Validation

### 17. End-to-End Testing
- [ ] Triggered GitHub push event → Verified Telegram message
- [ ] Triggered GitHub PR event → Verified Telegram message
- [ ] Triggered Amplify build failure → Verified Telegram alert
- [ ] Sent FinOps webhook → Verified cost alert received

### 18. Performance Testing
- [ ] Monitored Lambda cold start times
- [ ] Checked API Gateway latency
- [ ] Verified DynamoDB read/write performance
- [ ] Reviewed CloudWatch metrics

## Documentation

### 19. Team Documentation
- [ ] Shared API webhook URLs with team
- [ ] Documented architecture diagram
- [ ] Created runbook for common issues
- [ ] Established on-call procedures

### 20. Infrastructure Documentation
- [ ] Documented Terraform state location
- [ ] Noted any manual configuration steps
- [ ] Created disaster recovery plan
- [ ] Documented rollback procedures

## Ongoing Maintenance

### 21. Regular Tasks
- [ ] Schedule monthly cost review
- [ ] Plan quarterly Terraform updates
- [ ] Monitor security advisories for dependencies
- [ ] Review and optimize Lambda memory/timeout settings

---

## Troubleshooting Common Issues

### Issue: "Error creating Lambda function"
**Solution**: Check IAM permissions and ensure source code exists in correct directory

### Issue: "API Gateway returns 403"
**Solution**: Verify `aws_lambda_permission` resources are correctly configured

### Issue: "DynamoDB access denied"
**Solution**: Review IAM policy in `iam.tf` - ensure table ARN matches

### Issue: "EventBridge rule not triggering"
**Solution**: Verify event pattern matches Amplify event structure

### Issue: "Telegram messages not sending"
**Solution**: Validate bot token and chat ID; check Lambda logs for errors

---

## Success Criteria

✅ All 3 Lambda functions deployed successfully  
✅ API Gateway accessible and responding  
✅ GitHub webhook deliveries successful  
✅ EventBridge rule active  
✅ DynamoDB table created with encryption  
✅ Telegram notifications working  
✅ CloudWatch Logs showing execution traces  
✅ No IAM permission errors

---

**Deployment Date**: _______________  
**Deployed By**: _______________  
**Environment**: _______________  
**Notes**: _______________
