# Terraform Deployment Quick Guide — Cloud-Tibot DEV

## One-Time Setup

### 1. Configure AWS Credentials
```bash
# If not already configured
aws configure

# Verify access
aws sts get-caller-identity
```

### 2. Install Terraform
```bash
# Check version (should be >= 1.5.0)
terraform version

# If not installed, download from https://www.terraform.io/downloads.html
```

### 3. Prepare Terraform Variables

Edit `infrastructure/terraform.tfvars.dev`:

```bash
cd infrastructure
# Copy example to dev
cp terraform.tfvars.example terraform.tfvars.dev

# Edit with your real values
nano terraform.tfvars.dev
# or
vim terraform.tfvars.dev
```

**Required fields to fill:**
```hcl
telegram_token   = "YOUR_TELEGRAM_BOT_TOKEN"
telegram_chat_id = "YOUR_TELEGRAM_CHAT_ID"
```

**Find your Telegram values:**
- **Bot Token:** Talk to [@BotFather](https://t.me/botfather) on Telegram
  - Create a new bot → Get the token
- **Chat ID:** 
  - Send a message in your group/chat
  - Forward to [@userinfobot](https://t.me/userinfobot)
  - Look for "Super Group ID" (negative number like `-1003702164149`)

---

## Deploy to DEV Environment

### Step 1: Initialize
```bash
cd infrastructure/terraform

terraform init
terraform validate
terraform fmt -recursive
```

### Step 2: Review Plan
```bash
terraform plan -var-file=../terraform.tfvars.dev -out=plan.dev
```

**Check the output for:**
- ✅ `Create` — EventBridge rule, Lambda updates
- 🔄 `Update` — Lambda environment variables, IAM policies
- ⚠️ `Destroy` — Should be NONE (unless replacing)

### Step 3: Apply Configuration
```bash
# Apply the saved plan
terraform apply plan.dev

# OR apply directly (with confirmation prompt)
terraform apply -var-file=../terraform.tfvars.dev
```

**Wait for completion** (~1-2 minutes)

### Step 4: Verify Deployment
```bash
# Show outputs
terraform output

# Check Lambda
aws lambda get-function --function-name cloud-tibot_auto_remediator

# Check EventBridge rule
aws events describe-rule --name cloud-tibot_amplify_build_status
```

---

## Test the Deployment

### Option 1: Direct Lambda Invocation

```bash
# Create test event
cat > test-event.json << 'EOF'
{
  "source": "aws.amplify",
  "detail-type": "Amplify Deployment Status Change",
  "detail": {
    "appId": "d2t3ti5dqkttcm",
    "branchName": "main",
    "jobId": "999",
    "jobStatus": "SUCCEED",
    "commitId": "testcommit123"
  }
}
EOF

# Invoke function
aws lambda invoke \
  --function-name cloud-tibot_auto_remediator \
  --payload file://test-event.json \
  --region us-east-1 \
  response.json

# Check response
cat response.json

# Check logs
aws logs tail /aws/lambda/cloud-tibot_auto_remediator --follow
```

### Option 2: Trigger Real Amplify Build

1. Go to AWS Amplify Console
2. Select your app (e.g., `ebteq-csv-converter`)
3. Click **"Redeploy this version"** on any branch
4. Watch for Telegram notification

---

## Manage Terraform State

### View Current State
```bash
# Show all resources
terraform state list

# Show specific resource details
terraform state show aws_lambda_function.auto_remediator
```

### Backup State
```bash
# Backup before major changes
cp terraform.tfstate terraform.tfstate.backup.$(date +%Y%m%d_%H%M%S)
```

### Clean Up (Dev Only)
```bash
# ONLY use this to destroy dev environment
terraform destroy -var-file=../terraform.tfvars.dev

# You'll be asked for confirmation
# Type: yes
```

---

## Environment Variables in `terraform.tfvars.dev`

```hcl
# Basic Configuration
aws_region   = "us-east-1"
project_name = "cloud-tibot"
environment  = "dev"

# Telegram (REQUIRED)
telegram_token   = "1234567890:ABCdefGHIjklMNOpqrsTUVwxyz1234567890"
telegram_chat_id = "-1003702164149"

# GitHub (only needed for modules 2 & 3)
github_app_id              = ""
github_app_installation_id = ""
github_app_private_key     = ""
github_repo_owner          = ""
github_repo_name           = ""

# Lambda Sizing (DEV = minimal)
lambda_runtime     = "python3.11"
lambda_timeout     = 60      # Dev: faster timeout
lambda_memory_size = 256     # Dev: lower cost
```

---

## Troubleshooting

### Error: "source_dir not found"
```
Error: Source directory does not exist: ...
```
**Fix:** Make sure you're running from `infrastructure/terraform/` directory
```bash
cd infrastructure/terraform
terraform init
```

### Error: "Missing required variable"
```
Error: Missing required variable: "telegram_token"
```
**Fix:** Make sure `terraform.tfvars.dev` exists and has values:
```bash
ls -la ../terraform.tfvars.dev
cat ../terraform.tfvars.dev
```

### Error: "Invalid event pattern"
```
Error: invalid event pattern JSON
```
**Fix:** Event pattern in `eventbridge.tf` must be valid JSON
- The Terraform file handles JSON encoding automatically
- Don't edit the EventPattern manually

### Lambda not receiving events
```
Condition: EventBridge rule exists but Lambda never executes
```
**Check:**
```bash
# 1. Rule is ENABLED
aws events describe-rule --name cloud-tibot_amplify_build_status

# 2. Target is configured
aws events list-targets-by-rule --rule cloud-tibot_amplify_build_status

# 3. Lambda has permission
aws lambda get-policy --function-name cloud-tibot_auto_remediator

# 4. Check logs
aws logs tail /aws/lambda/cloud-tibot_auto_remediator --follow
```

---

## Next Steps After Deployment

### 1. Deploy to Staging
```bash
# Copy and modify for staging
cp terraform.tfvars.dev terraform.tfvars.staging

# Edit with staging values
vim terraform.tfvars.staging

# Deploy
terraform apply -var-file=../terraform.tfvars.staging
```

### 2. Deploy to Production
```bash
# Same process with prod file
cp terraform.tfvars.example terraform.tfvars.prod
vim terraform.tfvars.prod
terraform apply -var-file=../terraform.tfvars.prod
```

### 3. Enable Remote State (Recommended for Prod)
Create `infrastructure/terraform/backend-s3.tf`:
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

Then:
```bash
# Migrate local state to S3
terraform init

# When asked: Copy existing state to the new backend? → yes
```

---

## Common Commands Reference

```bash
# Initialization & Validation
terraform init                                    # Initialize working directory
terraform validate                                # Check configuration
terraform fmt -recursive                          # Format code

# Planning & Applying
terraform plan -var-file=../terraform.tfvars.dev # Show changes
terraform apply -var-file=../terraform.tfvars.dev # Apply changes
terraform destroy -var-file=../terraform.tfvars.dev # Remove infrastructure

# State Management
terraform state list                              # List all resources
terraform state show <resource>                   # Show resource details
terraform refresh                                 # Sync state with real resources

# Outputs
terraform output                                  # Show all outputs
terraform output -json                            # JSON format

# Debugging
terraform console                                 # Interactive console
TF_LOG=DEBUG terraform apply                      # Enable debug logging
```

---

## Files Modified for This Release

```
infrastructure/
├── terraform/
│   ├── eventbridge.tf          ✏️ Rule name and pattern updated
│   ├── lambda.tf               ✏️ Source paths fixed, env vars simplified
│   ├── iam.tf                  ✏️ Added amplify:GetApp permission
│   ├── outputs.tf              ✏️ Updated rule reference
│   ├── variables.tf            ✓ No changes needed
│   ├── provider.tf             ✓ No changes needed
│   └── api_gateway.tf          ✓ No changes needed
├── terraform.tfvars.dev        ✨ NEW: Dev environment file
└── terraform.tfvars.example    ✓ Reference (unchanged)

src/module1/
├── lambda_function.py          ✏️ Simplified (122 lines, 1.6KB)
├── requirements.txt            ✏️ Removed PyJWT, cryptography
└── build/                      (Will regenerate automatically)

docs/
└── INFRASTRUCTURE_CHANGES_DEV.md ✨ NEW: Full documentation
```

---

## Tips for Success

1. **Always plan before apply** — Review `terraform plan` output
2. **Use descriptive branch names** — `git checkout -b infra/amplify-notifier-dev`
3. **Keep secrets out of git** — `terraform.tfvars.dev` is in `.gitignore`
4. **Test in dev first** — Deploy to dev before staging/prod
5. **Backup state files** — Keep copies of `terraform.tfstate`
6. **Use tags** — All resources tagged for cost allocation
7. **Monitor CloudWatch logs** — Check logs after every deployment

---

## Support & References

- 📚 [Terraform AWS Provider Docs](https://registry.terraform.io/providers/hashicorp/aws/latest)
- 🔧 [AWS Lambda Docs](https://docs.aws.amazon.com/lambda/)
- 📢 [EventBridge User Guide](https://docs.aws.amazon.com/eventbridge/)
- 🤖 [Telegram Bot API](https://core.telegram.org/bots/api)

---

**Last Updated:** February 13, 2026  
**Tested On:** Terraform v1.10.5, AWS CLI v2  
**Status:** ✅ Production Ready
