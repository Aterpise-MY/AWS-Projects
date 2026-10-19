# 🎲 DND Platform - Complete Deployment Checklist

Use this checklist to deploy the GitHub Actions workflows and Telegram bot integration to your IB-DND-5e-Platform repository.

---

## ✅ Pre-Deployment

- [ ] **Repository Access**
  - [ ] Have admin access to `Brendon20011007/IB-DND-5e-Platform`
  - [ ] GitHub CLI installed and authenticated
  - [ ] Git repository cloned locally

- [ ] **Required Tools**
  - [ ] GitHub CLI (`gh`) installed
  - [ ] Python 3.11+ installed
  - [ ] Node.js 18+ installed
  - [ ] AWS CLI configured
  - [ ] Terraform 1.6.0+ installed

- [ ] **Accounts & Access**
  - [ ] AWS account with admin access
  - [ ] Supabase project created
  - [ ] Vercel account (optional)
  - [ ] Google Gemini API key
  - [ ] Telegram account

---

## 📱 Step 1: Create Telegram Bot

- [ ] Open Telegram and find [@BotFather](https://t.me/BotFather)
- [ ] Send `/newbot` command
- [ ] Name your bot: `DND Platform Bot`
- [ ] Username: `dnd_platform_bot` (or similar)
- [ ] **Save Bot Token** securely
- [ ] Send a message to your bot
- [ ] Get Chat ID from `https://api.telegram.org/bot<TOKEN>/getUpdates`
- [ ] **Save Chat ID** securely

**Test Bot:**
```bash
curl -X POST "https://api.telegram.org/bot<TOKEN>/sendMessage" \
  -d chat_id=<CHAT_ID> \
  -d text="Test message"
```

- [ ] Received test message ✅

---

## 📂 Step 2: Copy Files to Repository

### Copy Workflow Files

```bash
# Navigate to your DND Platform repo
cd /path/to/IB-DND-5e-Platform

# Create workflows directory if it doesn't exist
mkdir -p .github/workflows

# Copy workflow files (adjust source path)
cp /path/to/Cloud-Tibot/.github/workflows/dnd-platform-ci.yml .github/workflows/
cp /path/to/Cloud-Tibot/.github/workflows/dnd-pr-review.yml .github/workflows/
cp /path/to/Cloud-Tibot/.github/workflows/dnd-deploy.yml .github/workflows/
```

- [ ] `dnd-platform-ci.yml` copied
- [ ] `dnd-pr-review.yml` copied
- [ ] `dnd-deploy.yml` copied

### Copy Supporting Files

```bash
# Create scripts directory
mkdir -p scripts

# Copy Telegram bot
cp /path/to/Cloud-Tibot/scripts/telegram_bot.py scripts/
cp /path/to/Cloud-Tibot/scripts/requirements.txt scripts/

# Copy documentation
mkdir -p docs
cp /path/to/Cloud-Tibot/docs/GITHUB_ACTIONS_TELEGRAM_GUIDE.md docs/
```

- [ ] `telegram_bot.py` copied
- [ ] `requirements.txt` copied
- [ ] Documentation copied

---

## 🔐 Step 3: Configure GitHub Secrets

### Option A: Use Setup Script

```powershell
.\setup-github-actions.ps1
```

### Option B: Manual Configuration

Go to: `https://github.com/Brendon20011007/IB-DND-5e-Platform/settings/secrets/actions`

#### AWS Credentials
- [ ] `AWS_ACCESS_KEY_ID` - AWS access key
- [ ] `AWS_SECRET_ACCESS_KEY` - AWS secret  

#### Telegram
- [ ] `TELEGRAM_BOT_TOKEN` - Bot token from @BotFather
- [ ] `TELEGRAM_CHAT_ID` - Your chat ID

#### Supabase
- [ ] `VITE_SUPABASE_URL` - Supabase project URL
- [ ] `VITE_SUPABASE_ANON_KEY` - Supabase anon key
- [ ] `SUPABASE_JWT_SECRET` - JWT secret for auth
- [ ] `SUPABASE_ACCESS_TOKEN` - Access token (optional)
- [ ] `SUPABASE_PROJECT_REF` - Project reference (optional)

#### API Keys
- [ ] `GEMINI_API_KEY` - Google Gemini API key

#### Vercel (Optional)
- [ ] `VERCEL_TOKEN` - Vercel API token
- [ ] `VERCEL_ORG_ID` - Organization ID
- [ ] `VERCEL_PROJECT_ID` - Project ID
- [ ] `VERCEL_URL` - Deployment URL

#### Infrastructure
- [ ] `VITE_AWS_API_URL` - API Gateway URL

---

## 📋 Step 4: Enable GitHub Actions

- [ ] Go to repository **Settings**
- [ ] Click **Actions** → **General**
- [ ] Select **Allow all actions and reusable workflows**
- [ ] **Save** changes

### Set Workflow Permissions

- [ ] Go to **Actions** → **General** → **Workflow permissions**
- [ ] Select **Read and write permissions**
- [ ] Check **Allow GitHub Actions to create and approve pull requests**
- [ ] **Save** changes

---

## 🚀 Step 5: Commit and Push Workflows

```bash
cd /path/to/IB-DND-5e-Platform

# Create feature branch
git checkout -b feature/github-actions-setup

# Add files
git add .github/workflows/
git add scripts/
git add docs/

# Commit
git commit -m "feat: Add GitHub Actions workflows and Telegram bot integration

- Add CI/CD pipeline with frontend, Lambda, and Terraform validation
- Add AI-powered PR review with Gemini 1.5 Pro
- Add automated deployment pipeline
- Add Telegram bot integration for real-time notifications
- Add comprehensive documentation"

# Push to GitHub
git push origin feature/github-actions-setup
```

- [ ] Branch created
- [ ] Files committed
- [ ] Pushed to GitHub

---

## 🔍 Step 6: Create Test Pull Request

```bash
# Using GitHub CLI
gh pr create \
  --title "feat: GitHub Actions and Telegram Bot Integration" \
  --body "This PR adds:
  
  - ✅ CI/CD pipeline (dnd-platform-ci.yml)
  - 🤖 AI PR review (dnd-pr-review.yml)
  - 🚀 Deployment pipeline (dnd-deploy.yml)
  - 📱 Telegram bot integration
  - 📖 Complete documentation
  
  **Testing:**
  - [ ] Workflows execute successfully
  - [ ] Telegram notifications received
  - [ ] AI review posts comments
  - [ ] All checks pass" \
  --base main
```

- [ ] PR created
- [ ] Workflows triggered
- [ ] Telegram notification received

---

## ✅ Step 7: Verify Workflows

### Check CI Pipeline

- [ ] Go to PR → **Checks** tab
- [ ] Verify all jobs pass:
  - [ ] Frontend validation ✅
  - [ ] Lambda validation ✅
  - [ ] Terraform validation ✅
  - [ ] Security scan ✅
  - [ ] Supabase validation ✅

### Check AI Review

- [ ] PR has AI-generated review comment
- [ ] Review includes:
  - [ ] Code quality feedback
  - [ ] Security suggestions
  - [ ] Performance recommendations
  - [ ] Best practices

### Check Telegram Notifications

- [ ] Received PR notification in Telegram
- [ ] Message includes:
  - [ ] PR number and title
  - [ ] Author name
  - [ ] Change statistics
  - [ ] Review link buttons

---

## 🧪 Step 8: Test Manual Deployment

**Only if you want to test deployment immediately**

```bash
# Trigger deployment workflow
gh workflow run dnd-deploy.yml \
  -f deploy_frontend=true \
  -f deploy_infrastructure=false \
  -f deploy_functions=false
```

- [ ] Workflow triggered
- [ ] Telegram notification received
- [ ] Deployment completed (if testing)

---

## 📊 Step 9: Monitor First Deployment

When you merge to `main`:

- [ ] Deployment workflow starts automatically
- [ ] Telegram sends deployment start notification
- [ ] Infrastructure deploys (if changed)
- [ ] Lambda functions update (if changed)
- [ ] Frontend deploys to Vercel
- [ ] Smoke tests execute
- [ ] Telegram sends success/failure notification

**Check Logs:**
```bash
gh run list --workflow="dnd-deploy.yml"
gh run view <run-id> --log
```

---

## 🎯 Step 10: Post-Deployment Validation

### Test API Endpoints

```bash
# Test API Gateway
curl https://<API_URL>/health

# Test Lambda functions
aws lambda invoke \
  --function-name dnd-auth_handler-production \
  --payload '{}' \
  response.json
```

- [ ] API Gateway responds
- [ ] Lambda functions execute
- [ ] Frontend loads correctly

### Test Telegram Bot Locally

```bash
cd scripts
pip install -r requirements.txt

export TELEGRAM_BOT_TOKEN="your_token"
export TELEGRAM_CHAT_ID="your_chat_id"

python telegram_bot.py
```

- [ ] Bot sends test message ✅

### Test Notifications

1. Create a test PR
2. Make a small change
3. Comment on the PR
4. Merge the PR

- [ ] PR notification received
- [ ] AI review posted
- [ ] Merge notification received
- [ ] Deployment notification received

---

## 📖 Step 11: Update Documentation

- [ ] Add workflow badges to `README.md`:

```markdown
## CI/CD Status

[![CI/CD Pipeline](https://github.com/Brendon20011007/IB-DND-5e-Platform/actions/workflows/dnd-platform-ci.yml/badge.svg)](https://github.com/Brendon20011007/IB-DND-5e-Platform/actions/workflows/dnd-platform-ci.yml)
[![PR Review](https://github.com/Brendon20011007/IB-DND-5e-Platform/actions/workflows/dnd-pr-review.yml/badge.svg)](https://github.com/Brendon20011007/IB-DND-5e-Platform/actions/workflows/dnd-pr-review.yml)
[![Deployment](https://github.com/Brendon20011007/IB-DND-5e-Platform/actions/workflows/dnd-deploy.yml/badge.svg)](https://github.com/Brendon20011007/IB-DND-5e-Platform/actions/workflows/dnd-deploy.yml)
```

- [ ] Link to documentation in `README.md`
- [ ] Commit and push updates

---

## 🎉 Completion

### Final Checks

- [ ] All workflows running successfully
- [ ] Telegram bot sending notifications
- [ ] AI reviews posting comments
- [ ] Deployments working automatically
- [ ] Team members added to Telegram group
- [ ] Documentation accessible to team

### Success Criteria

✅ **You're successfully deployed when:**
1. Pull requests trigger CI and AI review
2. Telegram notifications arrive for all events
3. Merging to main automatically deploys
4. Lambda functions update correctly
5. Frontend deploys to Vercel
6. No workflow errors in Actions tab

---

## 🐛 Troubleshooting

### Issue: Workflows Not Running

**Solution:**
- Check **Actions** → **Settings** → Enable workflows
- Verify branch protection rules aren't blocking
- Check workflow file syntax with `yamllint`

### Issue: Secrets Not Found

**Solution:**
```bash
# List secrets
gh secret list -R Brendon20011007/IB-DND-5e-Platform

# Set missing secret
gh secret set SECRET_NAME -R Brendon20011007/IB-DND-5e-Platform
```

### Issue: Telegram Not Receiving

**Solution:**
```bash
# Test bot token
curl -X GET "https://api.telegram.org/bot<TOKEN>/getMe"

# Test message
curl -X POST "https://api.telegram.org/bot<TOKEN>/sendMessage" \
  -d chat_id=<CHAT_ID> \
  -d text="Test"
```

### Issue: AI Review Not Posting

**Solution:**
- Verify `GEMINI_API_KEY` is set correctly
- Check API quota hasn't been exceeded
- Review workflow logs for errors
- Ensure GitHub token has write permissions

---

## 📞 Support

If you encounter issues:

1. Check workflow logs: `gh run view <run-id> --log`
2. Review [troubleshooting guide](docs/GITHUB_ACTIONS_TELEGRAM_GUIDE.md#troubleshooting)
3. Test components individually
4. Check GitHub Actions status page

---

## 📊 Next Steps

After successful deployment:

- [ ] Set up branch protection rules
- [ ] Configure code owners (CODEOWNERS file)
- [ ] Add team members to Telegram group
- [ ] Schedule weekly deployment reviews
- [ ] Monitor CloudWatch for Lambda errors
- [ ] Review and optimize workflow execution times

---

**Deployment Date:** ____________

**Deployed By:** ____________

**Notes:**
_____________________________________________
_____________________________________________
_____________________________________________

---

**🎉 Congratulations! Your DND Platform now has automated CI/CD with AI-powered reviews and Telegram notifications!**
