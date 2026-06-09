# 🛡️ CORTEX Guardian Implementation Summary

## ✅ Implementation Complete!

All components of the **CORTEX Guardian** PR security scanner have been successfully created and integrated with the existing CORTEX infrastructure.

---

## 📋 What Was Created

### 1. **Module 4: PR Guardian Agent** 
   - **File**: `src/module4_agent/pr_guardian.py`
   - **Description**: AI-powered PR security scanner using OpenAI GPT-4
   - **Features**:
     - Fetches PR diffs using PyGithub
     - Analyzes code for security, bugs, and performance issues
     - Posts comments on Pull Requests
     - Sends webhook to Module 2 (Git Radar)
   - **Dependencies**: PyGithub 2.1.1+, openai 1.12.0+, requests 2.31.0+

### 2. **GitHub Actions Workflow**
   - **File**: `.github/workflows/cortex_guardian.yml`
   - **Triggers**: PR opened, synchronized, or reopened
   - **Actions**:
     - Checks out code
     - Sets up Python 3.11
     - Installs dependencies
     - Runs pr_guardian.py
     - Uploads logs as artifacts

### 3. **Module 2 (Git Radar) Updates**
   - **File**: `src/module2/lambda_function.py` (MODIFIED)
   - **New Handler**: `handle_agent_scan_event()`
   - **Features**:
     - Detects custom "agent_scan" events from Module 4
     - Formats special Telegram message for scanner results
     - Logs to DynamoDB
     - Does NOT break existing GitHub webhook handling

### 4. **Documentation**
   - **File**: `CORTEX_GUARDIAN_README.md`
   - **Contents**: Complete setup guide, troubleshooting, cost estimates, examples

---

## 🔄 Architecture Flow

```
GitHub PR Created/Updated
         │
         ▼
GitHub Actions Workflow Triggers
         │
         ▼
Module 4 (pr_guardian.py) Runs
   ├─ Fetches PR diff
   ├─ Analyzes with OpenAI GPT-4
   ├─ Posts comment on PR
   └─ Sends webhook to Module 2
         │
         ▼
Module 2 (Git Radar Lambda) Receives Webhook
   ├─ Detects "agent_scan" event
   ├─ Formats Telegram message
   └─ Sends notification
         │
         ▼
Telegram Dashboard Updated
```

---

## 🚀 Next Steps: Deployment

### Step 1: Deploy Module 2 Updates (Required)

Module 2 now includes the `agent_scan` event handler. Deploy the updated code:

```powershell
# Option A: Using Terraform (Recommended)
terraform plan -out=tfplan-guardian
terraform apply tfplan-guardian

# Option B: Manual AWS CLI (Faster)
aws lambda update-function-code `
  --function-name cloud-tibot_git_radar `
  --zip-file fileb://src/module2/build/module2.zip
```

**Verification:**
```powershell
# Check deployment
aws lambda get-function --function-name cloud-tibot_git_radar `
  --query 'Configuration.[LastModified,CodeSize]'
```

### Step 2: Configure GitHub Secrets (Required)

Add these secrets to your GitHub repository:

1. **Go to**: Repository → Settings → Secrets and variables → Actions → New repository secret

2. **Add**:
   - **Name**: `OPENAI_API_KEY`
     - **Value**: Your OpenAI API key (get from https://platform.openai.com/api-keys)
   
   - **Name**: `CORTEX_RADAR_WEBHOOK`
     - **Value**: Your Module 2 webhook URL
     - **Get it**: Run `terraform output github_webhook_url`
     - **Example**: `https://evn3cc72mb.execute-api.us-east-1.amazonaws.com/webhook/github`

### Step 3: Commit and Push to GitHub

```bash
git add .
git commit -m "feat: Add CORTEX Guardian PR security scanner (Module 4)"
git push origin main
```

### Step 4: Test with a Pull Request

```bash
# Create test branch
git checkout -b test/cortex-guardian

# Make a change
echo "print('Testing CORTEX Guardian')" > test_scanner.py
git add test_scanner.py
git commit -m "test: Trigger CORTEX Guardian scan"
git push origin test/cortex-guardian

# Create PR
gh pr create --title "Test: CORTEX Guardian Scanner" --body "Testing the new PR security scanner"
```

**Expected Results:**
1. ✅ GitHub Actions workflow runs automatically
2. ✅ PR comment appears with security analysis
3. ✅ Telegram notification arrives with scan results

---

## 🧪 Manual Testing

### Test 1: Verify Module 2 Can Receive agent_scan Events

```powershell
# Create test payload
$webhook_url = terraform output -raw github_webhook_url
$test_payload = @{
    event = "agent_scan"
    pr = 999
    status = "🟢 Clean"
    risk_level = "✅ CLEAN"
    summary = "Manual test - all systems operational"
    repository = "test-org/test-repo"
    scanner = "CORTEX-Guardian"
    timestamp = (Get-Date).ToUniversalTime().ToString("o")
} | ConvertTo-Json

# Send webhook
Invoke-RestMethod -Uri $webhook_url -Method Post `
  -Body $test_payload -ContentType "application/json"
```

**Expected Output:**
- Status: `200 OK`
- Telegram message appears with "🛡️ **[CORTEX GUARDIAN]**"

### Test 2: Check CloudWatch Logs

```powershell
# Monitor Module 2 logs
aws logs tail /aws/lambda/cloud-tibot_git_radar --follow

# Look for:
# [GIT RADAR] Detected CORTEX Guardian agent_scan event
# [GIT RADAR] PR #999 | Status: 🟢 Clean | Risk: ✅ CLEAN
# [GIT RADAR] Agent scan notification sent to Telegram
```

### Test 3: Verify GitHub Actions Workflow

```bash
# List workflows
gh workflow list

# Check last run
gh run list --workflow="cortex_guardian.yml"

# View logs
gh run view --log
```

---

## 📊 File Changes Summary

```
Modified Files:
  M src/module2/lambda_function.py          (+95 lines: agent_scan handler)

New Files:
  + .github/workflows/cortex_guardian.yml   (GitHub Actions workflow)
  + src/module4_agent/pr_guardian.py        (Main scanner script, 300+ lines)
  + src/module4_agent/requirements.txt      (Dependencies)
  + CORTEX_GUARDIAN_README.md               (Documentation)
  + CORTEX_GUARDIAN_IMPLEMENTATION.md       (This file)
```

---

## 🔒 Security Notes

1. **NEVER commit secrets** to git:
   - `OPENAI_API_KEY` ❌ Don't commit
   - Private keys ❌ Don't commit
   - Use GitHub Secrets ✅

2. **OpenAI API Key Security**:
   - Rotate keys regularly
   - Use project-specific keys
   - Monitor usage at https://platform.openai.com/usage

3. **Webhook Security** (Optional Enhancement):
   - Consider adding HMAC signature verification
   - IP allowlist for webhook endpoint
   - Rate limiting on API Gateway

---

## 💰 Cost Estimates

### Per PR Analysis:
- **Small PR** (< 500 lines): ~$0.05
- **Medium PR** (500-2000 lines): ~$0.15  
- **Large PR** (> 2000 lines): ~$0.30

### Monthly (assuming 20 PRs):
- **GPT-4**: ~$3 - $6/month
- **Lambda (Module 2)**: < $0.01/month (negligible)
- **API Gateway**: Included in free tier

**Total**: ~$3 - $6/month for typical usage

---

## 🐛 Troubleshooting

### Issue: Workflow doesn't trigger

**Check:**
1. Workflow file committed to `.github/workflows/`
2. Repository has Actions enabled (Settings → Actions → Allow all actions)
3. PR is not from a fork (forks need approval for first-time contributors)

**Fix:**
```bash
# Verify workflow exists
git ls-files .github/workflows/

# Re-commit if needed
git add .github/workflows/cortex_guardian.yml
git commit --amend --no-edit
git push -f
```

### Issue: "Missing required environment variables: OPENAI_API_KEY"

**Check:**
1. Secret name is EXACTLY `OPENAI_API_KEY` (case-sensitive)
2. Secret is set in correct repository
3. Re-run workflow after adding secret

**Fix:**
Settings → Secrets → Actions → Verify secret exists

### Issue: "Webhook not reaching Module 2"

**Check:**
1. Lambda deployed: `aws lambda list-functions --query 'Functions[?FunctionName==\`cloud-tibot_git_radar\`]'`
2. API Gateway URL correct: `terraform output github_webhook_url`
3. Lambda timeout sufficient (should be 300s)

**Fix:**
```powershell
# Deploy Module 2
terraform apply -target=aws_lambda_function.git_radar

# Check logs
aws logs tail /aws/lambda/cloud-tibot_git_radar --follow
```

---

## 📚 Additional Resources

- **OpenAI API Docs**: https://platform.openai.com/docs
- **PyGithub Docs**: https://pygithub.readthedocs.io/
- **GitHub Actions Docs**: https://docs.github.com/en/actions
- **AWS Lambda Docs**: https://docs.aws.amazon.com/lambda/

---

## ✅ Deployment Checklist

- [ ] Module 2 deployed via Terraform or AWS CLI
- [ ] GitHub secret `OPENAI_API_KEY` configured
- [ ] GitHub secret `CORTEX_RADAR_WEBHOOK` configured  
- [ ] Code pushed to GitHub (including workflow file)
- [ ] Test PR created
- [ ] Workflow executes successfully
- [ ] PR comment appears
- [ ] Telegram notification received
- [ ] CloudWatch logs show agent_scan event processing

---

## 🎉 You're All Set!

CORTEX Guardian is now protecting your code! Every Pull Request will be automatically scanned for security vulnerabilities, bugs, and performance issues.

**Monitor your PR scans:**
- GitHub Actions: https://github.com/Brendon20011007/Cloud-Tibot/actions
- CloudWatch Logs: `aws logs tail /aws/lambda/cloud-tibot_git_radar --follow`
- Telegram Dashboard: Check your configured chat

---

**Need Help?**
- Check `CORTEX_GUARDIAN_README.md` for detailed documentation
- Review CloudWatch logs for errors
- Verify GitHub Actions workflow logs

**Happy Securing! 🛡️**
