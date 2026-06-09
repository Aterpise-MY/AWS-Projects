# Project Cloud Tibot - Serverless ChatOps on AWS

Production-ready Terraform configuration for deploying a serverless ChatOps system integrating Telegram, GitHub, and AWS Amplify monitoring.

## 🚀 NEW: Complete CI/CD System with AI-Powered Reviews

**⭐ Latest Addition**: Comprehensive GitHub Actions workflows with AI-powered code reviews, Telegram notifications, and optional Copilot SDK integration for the IB-DND-5e-Platform project!

### What's Included:

✅ **3x GitHub Actions Workflows** - Continuous Integration, PR Review, Production Deployment  
✅ **Telegram Bot Integration** - Real-time notifications with interactive buttons  
✅ **AI Code Reviews** - Powered by Gemini 1.5 Pro  
✅ **Copilot SDK Integration** - Optional advanced custom agents for specialized reviews  
✅ **Complete Documentation** - 3000+ lines covering setup, deployment, and best practices  

### Quick Links:
 
⚡ **[docs/setup/QUICK_START_30MIN.md](docs/setup/QUICK_START_30MIN.md)** - Deploy in 30 minutes  
📊 **[docs/architecture/COMPLETE_SYSTEM_SUMMARY.md](docs/architecture/COMPLETE_SYSTEM_SUMMARY.md)** - Complete system overview  
🤖 **[docs/integration/GITHUB_COPILOT_SDK_INTEGRATION.md](docs/integration/GITHUB_COPILOT_SDK_INTEGRATION.md)** - Copilot SDK guide (750+ lines)  
📚 **[docs/integration/GITHUB_ACTIONS_TELEGRAM_GUIDE.md](docs/integration/GITHUB_ACTIONS_TELEGRAM_GUIDE.md)** - Complete guide (850+ lines)

### System Features:

- **CI Workflow**: Validates frontend, Lambda functions, Terraform, security scanning (~7 min)
- **PR Review**: AI-powered analysis, auto-labeling, Terraform plan preview (~5 min)
- **Deploy Workflow**: Infrastructure, Lambda functions, Supabase, frontend, smoke tests (~12 min)
- **Telegram Bot**: PR notifications, deployment alerts, interactive buttons
- **Cost**: ~$3/month basic or ~$8/month with Copilot SDK enhancement

---

## Architecture Overview

**Project CORTEX** consists of three Lambda-based modules:

1. **Auto-Remediator (Module 1)**: Monitors AWS Amplify build failures via EventBridge and sends notifications
2. **Git Radar (Module 2)**: Processes GitHub webhooks and maintains a Telegram dashboard with DynamoDB state
3. **FinOps Sentinel (Module 3)**: Handles cost optimization alerts and financial operations notifications

## Infrastructure Components

- **3x Lambda Functions** (Python 3.11)
- **API Gateway v2** (HTTP API with 2 routes)
- **DynamoDB Table** (On-demand billing)
- **EventBridge Rule** (Amplify monitoring)
- **IAM Roles & Policies** (Least privilege)
- **CloudWatch Log Groups** (14-day retention)

## Prerequisites

- Terraform >= 1.5.0
- AWS CLI configured with appropriate credentials
- Telegram Bot Token and Chat ID
- **GitHub App** with Copilot: Read permission (REQUIRED - see setup below)
- Python 3.11 Lambda source code in `src/module1`, `src/module2`, `src/module3`
- Node.js 18+ (for GitHub Actions workflows)
- PowerShell 7+ (for setup scripts)

## 🎯 Quick Start: CI/CD System Deployment

### For IB-DND-5e-Platform Project:

**Time**: 30 minutes | **Cost**: $3-8/month | **Setup**: Automated scripts provided

1. **Open** [docs/setup/QUICK_START_30MIN.md](docs/setup/QUICK_START_30MIN.md)
2. **Create** Telegram bot with @BotFather
3. **Copy** workflow files to your repo
4. **Run** `infrastructure/scripts/setup-github-actions.ps1` to configure secrets
5. **Test** with first pull request

**What you get:**
- ✅ Automated CI/CD for every commit
- ✅ AI-powered code reviews on PRs
- ✅ Real-time Telegram notifications
- ✅ Production deployment automation
- ✅ Security scanning and compliance

**Need help?** Start with [docs/INDEX.md](docs/INDEX.md) for the complete reading guide.

---

---

## 📚 CI/CD Documentation & Guides

Complete documentation for the GitHub Actions CI/CD system has been created to help you deploy, understand, and customize the automation system.

### Reading Paths by Goal:

| Goal | Documents | Time |
|------|-----------|------|
| **Deploy Immediately** | [docs/setup/QUICK_START_30MIN.md](docs/setup/QUICK_START_30MIN.md) | 30 min |
| **Understand System** | [docs/architecture/COMPLETE_SYSTEM_SUMMARY.md](docs/architecture/COMPLETE_SYSTEM_SUMMARY.md) + [docs/integration/GITHUB_ACTIONS_SUMMARY.md](docs/integration/GITHUB_ACTIONS_SUMMARY.md) | 30 min |
| **Learn Workflows** | [docs/integration/GITHUB_ACTIONS_TELEGRAM_GUIDE.md](docs/integration/GITHUB_ACTIONS_TELEGRAM_GUIDE.md) | 45 min |
| **Add Copilot SDK** | [docs/integration/COPILOT_SDK_QUICK_START.md](docs/integration/COPILOT_SDK_QUICK_START.md) | 20 min |
| **Deep Dive** | [docs/integration/GITHUB_COPILOT_SDK_INTEGRATION.md](docs/integration/GITHUB_COPILOT_SDK_INTEGRATION.md) | 60 min |

### Documentation Overview:

**[docs/INDEX.md](docs/INDEX.md)** - Master index with navigation  
**[docs/setup/QUICK_START_30MIN.md](docs/setup/QUICK_START_30MIN.md)** - Step-by-step deployment guide  
**[docs/architecture/COMPLETE_SYSTEM_SUMMARY.md](docs/architecture/COMPLETE_SYSTEM_SUMMARY.md)** - What was created and why  
**[docs/integration/GITHUB_ACTIONS_SUMMARY.md](docs/integration/GITHUB_ACTIONS_SUMMARY.md)** - Quick reference for workflows  

**[docs/integration/GITHUB_ACTIONS_TELEGRAM_GUIDE.md](docs/integration/GITHUB_ACTIONS_TELEGRAM_GUIDE.md)** - Complete guide (850+ lines)
- Workflow explanations
- Telegram bot setup
- GitHub secrets configuration
- Troubleshooting guide

**[docs/integration/GITHUB_COPILOT_SDK_INTEGRATION.md](docs/integration/GITHUB_COPILOT_SDK_INTEGRATION.md)** - Copilot SDK guide (750+ lines)
- SDK architecture
- Custom agents configuration
- Implementation examples
- Best practices

**[docs/integration/COPILOT_SDK_QUICK_START.md](docs/integration/COPILOT_SDK_QUICK_START.md)** - Quick Copilot reference
- Feature comparison
- Migration paths
- Integration instructions

**[docs/deployment/DEPLOYMENT_CHECKLIST_GITHUB_ACTIONS.md](docs/deployment/DEPLOYMENT_CHECKLIST_GITHUB_ACTIONS.md)** - Complete checklist
- Pre-deployment tasks
- Post-deployment validation
- Troubleshooting

### System Components:

| Component | Status | Type | Purpose |
|-----------|--------|------|---------|
| **dnd-platform-ci.yml** | ✅ Ready | Workflow | Continuous Integration (7 jobs, ~7 min) |
| **dnd-pr-review.yml** | ✅ Ready | Workflow | AI Code Review (5 jobs, ~5 min) |
| **dnd-deploy.yml** | ✅ Ready | Workflow | Production Deployment (7 jobs, ~12 min) |
| **scripts/telegram_bot.py** | ✅ Ready | Script | Telegram notifications with buttons |
| **infrastructure/scripts/setup-github-actions.ps1** | ✅ Ready | Script | Automated secret configuration |

---

**Project CORTEX now uses GitHub App JWT authentication** for production-grade security.

**What you need:**
1. ✅ **GitHub App ID**
2. ✅ **GitHub App Installation ID**
3. ✅ **GitHub App Private Key** (.pem file)

**Why GitHub App?**
- ✅ No long-lived tokens (JWT expires every 10 minutes)
- ✅ Production-ready and enterprise-grade
- ✅ Granular permissions (Copilot: Read only)
- ✅ Better audit trail and security

**Setup Instructions:**
📖 **Complete Setup Guide**: [docs/setup/GITHUB_APP_SETUP.md](docs/setup/GITHUB_APP_SETUP.md)

**Quick Summary:**
1. Create GitHub App at https://github.com/settings/apps
2. Grant **Copilot: Read** permission (critical!)
3. Install app to your account/org
4. Copy: App ID, Installation ID, Private Key
5. Update `terraform.tfvars` with credentials

**Alternative Authentication Options** (for testing):
- Option 2: OAuth token with `copilot` scope
- Option 3: OpenAI API key (no GitHub Copilot required)

See [docs/setup/COPILOT_AUTH_SETUP.md](docs/setup/COPILOT_AUTH_SETUP.md) for alternative methods.

## Directory Structure

```
Cloud Tibot/
├── 📄 README.md                              # This file
├── 📄 INDEX.md                               # Master documentation index
├── 📄 QUICK_START_30MIN.md                   # Deploy in 30 minutes
├── 📄 COMPLETE_SYSTEM_SUMMARY.md             # Complete system overview
├── 📄 GITHUB_ACTIONS_SUMMARY.md              # Quick reference
├── 📄 DEPLOYMENT_CHECKLIST_GITHUB_ACTIONS.md # Step-by-step checklist
│
├── 🔄 GitHub Actions Workflows
│   └── .github/workflows/
│       ├── dnd-platform-ci.yml               # CI validation (7 jobs)
│       ├── dnd-pr-review.yml                 # PR review with AI (5 jobs)
│       └── dnd-deploy.yml                    # Production deployment (7 jobs)
│
├── 🤖 Telegram Integration
│   └── scripts/
│       └── telegram_bot.py                   # Complete bot implementation
│
├── 🛠️ Setup Tools
│   └── setup-github-actions.ps1              # Automated secret configuration
│
├── 📚 Comprehensive Documentation
│   └── docs/
│       ├── GITHUB_ACTIONS_TELEGRAM_GUIDE.md         # Complete guide (850+ lines)
│       ├── GITHUB_COPILOT_SDK_INTEGRATION.md        # Copilot SDK guide (750+ lines)
│       ├── COPILOT_SDK_QUICK_START.md               # Quick Copilot reference
│       └── DEPLOYMENT_CHECKLIST_GITHUB_ACTIONS.md   # Detailed checklist
│
├── 🏗️ Terraform Infrastructure
│   ├── provider.tf                # AWS provider configuration
│   ├── variables.tf               # Input variable definitions
│   ├── terraform.tfvars           # Variable values
│   ├── dynamodb.tf                # DynamoDB table
│   ├── iam.tf                     # IAM roles and policies
│   ├── lambda.tf                  # Lambda functions (3 modules)
│   ├── api_gateway.tf             # HTTP API Gateway v2
│   ├── eventbridge.tf             # EventBridge rules
│   ├── outputs.tf                 # Output values
│   └── .gitignore                 # Git ignore rules
│
└── 📦 Lambda Source Code
    ├── src/module1/               # Auto-Remediator
    │   ├── lambda_function.py
    │   ├── copilot_agent.py
    │   ├── requirements.txt
    │   └── build/
    ├── src/module2/               # Git Radar
    │   ├── lambda_function.py
    │   ├── copilot_agent.py
    │   ├── requirements.txt
    │   └── build/
    ├── src/module3/               # FinOps Sentinel
    │   ├── lambda_function.py
    │   ├── copilot_agent.py
    │   ├── requirements.txt
    │   └── build/
    └── src/module4_agent/         # PR Guardian Agent
        ├── pr_guardian.py
        ├── requirements.txt
        └── build/
```

## Deployment Instructions

### 1. Configure Variables

Create a `terraform.tfvars` file from the example:

```bash
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` with your actual values:

```hcl
# Telegram Configuration
telegram_token   = "your-telegram-bot-token"
telegram_chat_id = "your-telegram-chat-id"

# GitHub App Authentication (REQUIRED)
github_app_id              = "123456"           # From GitHub App settings
github_app_installation_id = "12345678"         # From installation URL
github_app_private_key     = <<-EOT            # Entire .pem file content
-----BEGIN RSA PRIVATE KEY-----
YOUR_PRIVATE_KEY_CONTENT_HERE
-----END RSA PRIVATE KEY-----
EOT

# Repository Settings
github_repo_owner = "your-username-or-org"
github_repo_name  = "your-repo-name"

# AWS Configuration
aws_region   = "us-east-1"
project_name = "cortex"
environment  = "prod"
```

**⚠️ IMPORTANT**: Follow [docs/setup/GITHUB_APP_SETUP.md](docs/setup/GITHUB_APP_SETUP.md) to get these credentials!

**Don't have a GitHub App yet?** See the complete setup guide with screenshots:
📖 [docs/setup/GITHUB_APP_SETUP.md](docs/setup/GITHUB_APP_SETUP.md)

### 2. Prepare Lambda Source Code

Ensure your Python Lambda functions exist in the correct directories:

```
src/module1/lambda_function.py  # Auto-Remediator
src/module2/lambda_function.py  # Git Radar
src/module3/lambda_function.py  # FinOps Sentinel
```

Each should have a `lambda_handler` function:

```python
def lambda_handler(event, context):
    # Your implementation
    return {
        'statusCode': 200,
        'body': 'Success'
    }
```

### 3. Initialize Terraform

```bash
terraform init
```

### 4. Plan Infrastructure

```bash
terraform plan
```

Review the execution plan carefully.

### 5. Deploy Infrastructure

```bash
terraform apply
```

Type `yes` to confirm deployment.

### 6. Retrieve API Endpoints

```bash
terraform output
```

You'll receive:
- `api_gateway_endpoint`: Base API URL
- `github_webhook_url`: URL to configure in GitHub
- `finops_webhook_url`: URL for FinOps integrations

## Post-Deployment Configuration

### Configure GitHub Webhook

1. Go to your GitHub repository → Settings → Webhooks
2. Click "Add webhook"
3. Set Payload URL to the `github_webhook_url` output
4. Content type: `application/json`
5. Select events: `Push`, `Pull request`, etc.
6. Click "Add webhook"

### Test EventBridge Integration

The Auto-Remediator will automatically trigger when any Amplify app build fails. To test:

1. Deploy an Amplify app
2. Trigger a build failure
3. Check CloudWatch Logs for Lambda execution

## Monitoring and Logs

All Lambda functions log to CloudWatch:

```bash
# View logs for Auto-Remediator
aws logs tail /aws/lambda/cortex_auto_remediator --follow

# View logs for Git Radar
aws logs tail /aws/lambda/cortex_git_radar --follow

# View logs for FinOps Sentinel
aws logs tail /aws/lambda/cortex_finops_sentinel --follow
```

## Updating Lambda Code

After modifying Lambda source code:

```bash
terraform apply -replace="aws_lambda_function.git_radar"
```

Or apply normally (Terraform detects code changes via hash):

```bash
terraform apply
```

## Cost Optimization

This infrastructure uses:
- **Lambda**: Pay per invocation (generous free tier)
- **DynamoDB**: On-demand billing (pay per request)
- **API Gateway**: HTTP API (cheapest option)
- **EventBridge**: Free for AWS service events

**Estimated monthly cost**: $1-5 for low-volume usage

## Security Best Practices

✅ IAM roles follow least privilege principle  
✅ Secrets stored as Terraform variables (use AWS Secrets Manager in production)  
✅ API Gateway has CORS configured  
✅ DynamoDB encryption at rest enabled  
✅ CloudWatch Logs for audit trail  
✅ Point-in-time recovery enabled on DynamoDB  

**Recommendation**: Use AWS Secrets Manager for production deployments:

```hcl
data "aws_secretsmanager_secret_version" "telegram" {
  secret_id = "cortex/telegram"
}
```

## Cleanup

To destroy all resources:

```bash
terraform destroy
```

Type `yes` to confirm deletion.

## Troubleshooting

### Lambda timeout errors
Increase timeout in `variables.tf`:
```hcl
variable "lambda_timeout" {
  default = 120  # seconds
}
```

### DynamoDB permission errors
Verify the IAM policy in `iam.tf` includes the table ARN

### API Gateway 403 errors
Check Lambda permissions with `aws_lambda_permission` resources

## 🎯 Features Matrix

### Terraform Infrastructure
- ✅ Automated AWS deployment via Terraform
- ✅ 3x Lambda functions (Auto-Remediator, Git Radar, FinOps Sentinel)
- ✅ API Gateway v2 (HTTP API)
- ✅ DynamoDB for state management
- ✅ EventBridge for AWS Amplify monitoring
- ✅ IAM roles with least privilege
- ✅ CloudWatch logging

### CI/CD System
- ✅ GitHub Actions workflows
- ✅ Continuous integration validation
- ✅ AI-powered pull request reviews
- ✅ Production deployment automation
- ✅ Security scanning (Trivy, npm audit, safety)
- ✅ Infrastructure as Code validation
- ✅ Automated testing

### Telegram Integration
- ✅ Real-time notifications
- ✅ Interactive buttons (View PR, Approve, Comment)
- ✅ PR status updates
- ✅ Deployment alerts
- ✅ Error notifications
- ✅ Custom message formatting

### AI-Powered Features
- ✅ Gemini 1.5 Pro code review
- ✅ Lambda impact analysis
- ✅ Terraform plan preview
- ✅ Auto-labeling (optional Copilot SDK enhancement)
- ✅ Custom agents for specialized reviews

---

## 💡 Key Highlights

### New CI/CD System Value
- **Automation**: Remove manual code reviews, testing, deployments
- **Quality**: AI-powered analysis catches bugs before production
- **Speed**: Deploy to production in minutes, not hours
- **Transparency**: Real-time notifications keep team informed
- **Cost**: ~$3-8/month (cheaper than 1 developer-hour)
- **Professional**: Enterprise-grade automation for any team size

### Copilot SDK Enhancement (Optional)
- **Advanced AI**: Use GPT-4.1, Claude, or Gemini
- **Custom Agents**: Create specialized reviewers for different domains
- **Better Context**: Tools read/search/glob for deep code understanding
- **Session Management**: Multi-turn conversations with state
- **MCP Integration**: Connect to external APIs and services
- **Cost Optimization**: Built-in control and monitoring

---

## 📊 Deployment Options

### Option 1: Terraform Only (Existing)
Deploy the original CORTEX serverless system with 3 Lambda functions and AWS infrastructure.

```bash
terraform init
terraform plan
terraform apply
```

### Option 2: GitHub Actions CI/CD (New)
Deploy complete CI/CD system with AI reviews, Telegram notifications, and automated workflows.

Follow [docs/setup/QUICK_START_30MIN.md](docs/setup/QUICK_START_30MIN.md)

### Option 3: Full Stack
Deploy both Terraform infrastructure AND GitHub Actions CI/CD system for complete automation.

---

## Support

For issues or questions:

### Terraform Issues:
- Review CloudWatch Logs
- Check Terraform state: `terraform show`
- Validate IAM permissions: `aws iam simulate-principal-policy`

### CI/CD System Issues:
- Check GitHub Actions logs (Actions tab in your repo)
- Review [docs/GITHUB_ACTIONS_TELEGRAM_GUIDE.md](docs/GITHUB_ACTIONS_TELEGRAM_GUIDE.md) troubleshooting section
- Verify all secrets configured: Settings → Secrets → Actions
- Test Telegram bot locally: `python scripts/telegram_bot.py`

### Copilot SDK Issues:
- Review [docs/GITHUB_COPILOT_SDK_INTEGRATION.md](docs/GITHUB_COPILOT_SDK_INTEGRATION.md) best practices
- Check [docs/COPILOT_SDK_QUICK_START.md](docs/COPILOT_SDK_QUICK_START.md) troubleshooting

---

## 📖 Documentation

**Total Documentation**: 3000+ lines across 10 documents  
**Code Examples**: 15+ complete, copy-paste ready examples  
**Coverage**: Setup, deployment, usage, troubleshooting, best practices  

All documentation is in Markdown and can be read directly in VS Code or on GitHub.

---

## License

MIT License - See LICENSE file for details.

---

**Developed by**: GitHub Copilot + DevOps Engineering Team  
**Last Updated**: February 11, 2026  
**Terraform Version**: 1.5+  
**AWS Provider**: ~> 5.0  
**Node.js**: 18+ (for GitHub Actions)  
**Python**: 3.11+ (for Lambda functions)  

**Project Status**: ✅ Production Ready
