# 🤖 DND Platform - GitHub Actions & Telegram Bot Integration

Complete CI/CD pipeline with AI-powered PR reviews and Telegram notifications for the IB-DND-5e-Platform project.

## 📋 Table of Contents

1. [Overview](#overview)
2. [Workflows](#workflows)
3. [Telegram Bot Setup](#telegram-bot-setup)
4. [GitHub Secrets Configuration](#github-secrets-configuration)
5. [Lambda Integration](#lambda-integration)
6. [Usage Guide](#usage-guide)
7. [Troubleshooting](#troubleshooting)

---

## 🎯 Overview

This integration provides:

- ✅ **Automated CI/CD Pipeline** - Build, test, and deploy on every push
- 🤖 **AI-Powered Code Reviews** - Gemini 1.5 Pro reviews every PR
- 📱 **Real-time Telegram Notifications** - Get instant updates on PR, deployments, and errors
- ⚡ **Lambda Function Testing** - Automated validation of all 6 Lambda functions
- 🏗️ **Infrastructure as Code** - Terraform validation and planning
- 🔒 **Security Scanning** - Dependency and vulnerability checks

---

## 🔄 Workflows

### 1. **CI/CD Pipeline** (`dnd-platform-ci.yml`)

**Triggers:** Push to `main`/`develop`, Pull Requests

**Jobs:**
- 🎨 Frontend validation (TypeScript, build)
- ⚡ Lambda functions syntax check (6 functions)
- 🏗️ Terraform infrastructure validation
- 🔒 Security scanning (Trivy, npm audit)
- 🔷 Supabase edge functions check
- 🧪 Integration tests
- 📢 Telegram notification

**Example Output:**
```
✅ Frontend: passed
✅ Lambda Functions: passed
✅ Infrastructure: passed
✅ Security: passed
📱 Telegram: Notification sent
```

### 2. **PR Review** (`dnd-pr-review.yml`)

**Triggers:** PR opened, synchronized, or commented

**Jobs:**
- 🧠 AI code review using Gemini 1.5 Pro
- ⚡ Lambda impact analysis
- 📋 Terraform plan preview
- 📱 Telegram PR notification
- 🏷️ Auto-labeling based on changed files

**AI Review Features:**
- Line-by-line code analysis
- Security vulnerability detection
- Performance optimization suggestions
- Best practices enforcement
- Missing test detection

### 3. **Deployment Pipeline** (`dnd-deploy.yml`)

**Triggers:** Push to `main`, Manual workflow dispatch

**Jobs:**
1. ✅ Pre-deployment validation
2. 🏗️ Deploy AWS infrastructure (Terraform)
3. ⚡ Deploy all 6 Lambda functions
4. 🔷 Deploy Supabase edge functions
5. 🎨 Deploy frontend to Vercel
6. 🧪 Post-deployment smoke tests
7. 📢 Deployment notification to Telegram

**Deployment Flow:**
```
Change Detection → Infrastructure → Lambda → Supabase → Frontend → Tests → Notify
```

---

## 📱 Telegram Bot Setup

### Step 1: Create Telegram Bot

1. Open Telegram and search for [@BotFather](https://t.me/BotFather)
2. Send `/newbot` and follow the prompts
3. Choose a name: `DND Platform Bot`
4. Choose a username: `dnd_platform_bot` (must end with `_bot`)
5. Save the **Bot Token** (looks like `123456:ABC-DEF1234ghIkl-zyx57W2v1u123ew11`)

### Step 2: Get Chat ID

1. Send a message to your bot
2. Visit: `https://api.telegram.org/bot<YOUR_BOT_TOKEN>/getUpdates`
3. Find the `"chat":{"id":123456789}` in the response
4. Save the **Chat ID**

### Step 3: Configure Bot Commands

Send these to @BotFather:

```
/setcommands

status - Get CI/CD pipeline status
deploy - Trigger manual deployment
rollback - Rollback last deployment
health - Check Lambda functions health
stats - View daily statistics
help - Show available commands
```

### Step 4: Test Bot Locally

```bash
cd scripts
pip install -r requirements.txt

# Set environment variables
export TELEGRAM_BOT_TOKEN="your_bot_token"
export TELEGRAM_CHAT_ID="your_chat_id"

# Test bot
python telegram_bot.py
```

---

## 🔐 GitHub Secrets Configuration

Add these secrets to your GitHub repository:

### Required Secrets

#### AWS Credentials
```
AWS_ACCESS_KEY_ID=AKIA...
AWS_SECRET_ACCESS_KEY=...
```

#### Telegram
```
TELEGRAM_BOT_TOKEN=123456:ABC-DEF...
TELEGRAM_CHAT_ID=123456789
```

#### Supabase
```
VITE_SUPABASE_URL=https://xxxxx.supabase.co
VITE_SUPABASE_ANON_KEY=eyJhbGc...
SUPABASE_JWT_SECRET=your-jwt-secret
SUPABASE_ACCESS_TOKEN=sbp_...
SUPABASE_PROJECT_REF=xxxxxxxxxxxxx
```

#### API Keys
```
GEMINI_API_KEY=AIzaSy...
```

#### Vercel (for frontend deployment)
```
VERCEL_TOKEN=...
VERCEL_ORG_ID=...
VERCEL_PROJECT_ID=...
VERCEL_URL=dnd-platform.vercel.app
```

#### Infrastructure
```
VITE_AWS_API_URL=https://xxx.execute-api.us-east-1.amazonaws.com/dev
```

### How to Add Secrets

1. Go to your repo: `https://github.com/Brendon20011007/IB-DND-5e-Platform`
2. Click **Settings** → **Secrets and variables** → **Actions**
3. Click **New repository secret**
4. Add each secret one by one

---

## ⚡ Lambda Integration

### Lambda Functions

The system monitors these 6 Lambda functions:

1. **auth_handler** - JWT authentication
2. **upload_signer** - S3 pre-signed URLs
3. **pdf_processor** - Gemini AI character parsing
4. **get_characters** - Retrieve characters from DynamoDB
5. **save_character** - Save character data
6. **delete_character** - Delete character records

### Telegram Notifications for Lambda

The bot sends notifications for:

- ✅ Lambda deployment success
- ❌ Lambda function errors
- ⚠️ High execution time
- 💰 Cost alerts (when invocations spike)

### Example Notification

```
⚠️ Lambda Function Error

⚡ Function: pdf_processor
🐛 Error: Timeout after 30 seconds

🔗 CloudWatch Logs
🔍 Check logs for stack trace
```

---

## 📖 Usage Guide

### 1. Creating a Pull Request

When you open a PR:

1. **GitHub Actions** automatically runs CI/CD checks
2. **AI Review Bot** analyzes your code within 2-3 minutes
3. **Telegram** sends you a notification with PR details
4. Review the AI feedback and make changes if needed

### 2. Merging to Main

When you merge to `main`:

1. **Deployment** automatically starts
2. **Telegram** notifies you of deployment progress
3. **Smoke tests** verify the deployment
4. **Final notification** confirms success or failure

### 3. Manual Deployment

Trigger deployment manually:

1. Go to **Actions** → **DND Platform Deployment**
2. Click **Run workflow**
3. Choose what to deploy:
   - ☑️ Infrastructure
   - ☑️ Lambda Functions
   - ☑️ Frontend

### 4. Monitoring

#### Check CI/CD Status
```bash
gh run list --workflow="dnd-platform-ci.yml"
```

#### View Logs
```bash
gh run view <run-id> --log
```

#### Test Telegram Bot
```bash
cd scripts
python telegram_bot.py
```

---

## 🔍 Troubleshooting

### Issue: Workflows Not Running

**Solution:**
- Check if workflows are enabled: Repo → Settings → Actions → Allow all actions
- Verify GitHub token permissions

### Issue: Telegram Notifications Not Received

**Solution:**
```bash
# Test bot token
curl -X POST "https://api.telegram.org/bot<TOKEN>/getMe"

# Test send message
curl -X POST "https://api.telegram.org/bot<TOKEN>/sendMessage" \
  -d chat_id=<CHAT_ID> \
  -d text="Test"
```

### Issue: Lambda Deployment Fails

**Solution:**
- Verify AWS credentials are correct
- Check Lambda function names match pattern: `dnd-{function}-{environment}`
- Ensure IAM permissions allow `lambda:UpdateFunctionCode`

### Issue: Terraform Validation Fails

**Solution:**
```bash
cd infrastructure
terraform fmt
terraform validate
terraform plan
```

### Issue: AI Review Not Posting

**Solution:**
- Check Gemini API key is valid
- Verify GitHub token has `pull_requests: write` permission
- Check PR doesn't have too many files (limit is 10)

---

## 📊 Notification Examples

### PR Opened
```
🎲 DND Platform - New Pull Request

PR #42: Add character inventory system
👤 Author: @Brendon20011007

Changes:
➕ 234 additions
➖ 56 deletions
📁 8 files changed

⏳ Waiting for CI/CD checks...

[View PR] [Approve] [Comment]
```

### Deployment Success
```
✅ Deployment Successful!

📍 Environment: production
⏱️ Duration: 4m 32s

Endpoints:
🔗 API: https://xxx.execute-api.us-east-1.amazonaws.com/dev
🌐 Frontend: https://dnd-platform.vercel.app

🧪 Running smoke tests...
```

### Lambda Error
```
⚠️ Lambda Function Error

⚡ Function: pdf_processor
🐛 Error: Gemini API rate limit exceeded

🔗 CloudWatch Logs
🔍 Check logs for stack trace
```

---

## 🎯 Best Practices

1. **Always test locally** before pushing
2. **Write descriptive commit messages**
3. **Keep PRs small and focused** (< 500 lines)
4. **Review AI feedback** before dismissing
5. **Monitor Telegram for deployment status**
6. **Check CloudWatch logs** for Lambda errors
7. **Use manual deployment** for urgent fixes

---

## 📚 Additional Resources

- [GitHub Actions Documentation](https://docs.github.com/en/actions)
- [Telegram Bot API](https://core.telegram.org/bots/api)
- [AWS Lambda Best Practices](https://docs.aws.amazon.com/lambda/latest/dg/best-practices.html)
- [Terraform AWS Provider](https://registry.terraform.io/providers/hashicorp/aws/latest/docs)
- [Gemini API Documentation](https://ai.google.dev/docs)

---

## 🤝 Support

For issues or questions:

1. Check [Troubleshooting](#troubleshooting) section
2. Review workflow logs in GitHub Actions
3. Ask in Telegram group

---

**Built with ❤️ for the DND Platform**
