# 🛡️ CORTEX Guardian - PR Security Scanner

## Overview

**CORTEX Guardian** (Module 4) is an AI-powered Pull Request security and code quality scanner that runs automatically in GitHub Actions. It analyzes code diffs using OpenAI's GPT-4 to detect:

- 🔐 **Security vulnerabilities** (SQL injection, XSS, secrets exposure, etc.)
- 🐛 **Potential bugs** and logic errors
- ⚡ **Performance issues** and anti-patterns
- 📐 **Code quality concerns** (complexity, maintainability)

Analysis results are:
1. Posted as comments on the Pull Request
2. Sent to **CORTEX Git Radar** (Module 2) via webhook
3. Displayed on your Telegram dashboard

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  GitHub Pull Request Created/Updated                        │
└────────────────┬────────────────────────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────────────────────────┐
│  GitHub Actions Workflow (.github/workflows/cortex_guardian.yml) │
│  • Triggers on PR events (opened, synchronize, reopened)   │
│  • Runs: src/module4_agent/pr_guardian.py                  │
└────────────────┬────────────────────────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────────────────────────┐
│  CORTEX Guardian Agent (pr_guardian.py)                     │
│  1. Fetches PR diff using PyGithub                          │
│  2. Analyzes with OpenAI GPT-4                              │
│  3. Posts comment on PR                                     │
│  4. Sends webhook to Module 2 (Git Radar)                   │
└────────────────┬────────────────────────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────────────────────────┐
│  CORTEX Git Radar (Module 2 Lambda)                         │
│  • Receives agent_scan webhook                              │
│  • Formats special message                                  │
│  • Sends to Telegram dashboard                              │
│  • Logs to DynamoDB                                         │
└─────────────────────────────────────────────────────────────┘
```

---

## Setup Instructions

### 1. Configure GitHub Secrets

Add the following secrets to your GitHub repository:

**Settings → Secrets and variables → Actions → New repository secret**

| Secret Name | Value | How to Get |
|-------------|-------|------------|
| `OPENAI_API_KEY` | Your OpenAI API key | [Get from OpenAI Dashboard](https://platform.openai.com/api-keys) |
| `CORTEX_RADAR_WEBHOOK` | Module 2 webhook URL | Run `terraform output github_webhook_url` |

**Example values:**
```bash
OPENAI_API_KEY=sk-proj-xxxxxxxxxxxxxxxxxxxxxxxxxxxx
CORTEX_RADAR_WEBHOOK=https://evn3cc72mb.execute-api.us-east-1.amazonaws.com/webhook/github
```

### 2. Get CORTEX_RADAR_WEBHOOK URL

```bash
# From your Terraform workspace directory
cd "c:\Users\BrendonAng\Cloud Tibot"
terraform output github_webhook_url
```

Copy the output (e.g., `https://xxx.execute-api.us-east-1.amazonaws.com/webhook/github`)

### 3. Deploy Module 2 Updates

The updated Module 2 Lambda code includes the new `agent_scan` event handler.

```powershell
# Rebuild Lambda packages
.\Build-LambdaPackages.ps1 -CleanBuild

# Deploy via Terraform
terraform plan -out=tfplan-guardian
terraform apply tfplan-guardian
```

### 4. Test the Integration

#### Test 1: Create a Test Pull Request

```bash
# Create a new branch
git checkout -b test/cortex-guardian

# Make a code change (e.g., add a test file)
echo "print('Hello CORTEX')" > test_file.py
git add test_file.py
git commit -m "Test CORTEX Guardian"
git push origin test/cortex-guardian

# Create PR via GitHub UI or CLI
gh pr create --title "Test: CORTEX Guardian" --body "Testing PR security scanner"
```

#### Expected Results:

1. **GitHub Actions**: Workflow runs automatically
   - Check: `Actions` tab → `🛡️ CORTEX Guardian - PR Security Scanner`
   - Look for green checkmark ✅

2. **PR Comment**: Guardian posts analysis
   - Comment appears with "🛡️ CORTEX-Guardian PR Analysis"
   - Shows risk level and findings

3. **Telegram Notification**: Message arrives in dashboard
   - Format: "🛡️ **[CORTEX GUARDIAN]**"
   - Shows PR number, status, and summary

#### Test 2: Verify Webhook Manually

```powershell
# Send test webhook to Module 2
$webhook_url = "YOUR_CORTEX_RADAR_WEBHOOK_URL"
$test_payload = @{
    event = "agent_scan"
    pr = 123
    status = "🟢 Clean"
    risk_level = "✅ CLEAN"
    summary = "Test scan - all checks passed"
    repository = "owner/repo"
    scanner = "CORTEX-Guardian"
    timestamp = (Get-Date).ToUniversalTime().ToString("o")
} | ConvertTo-Json

Invoke-RestMethod -Uri $webhook_url -Method Post -Body $test_payload -ContentType "application/json"
```

Check Telegram for the notification.

---

## Configuration Options

### Adjust AI Model

Edit `src/module4_agent/pr_guardian.py`:

```python
# Line ~94: Change model
response = self.openai.chat.completions.create(
    model="gpt-4",  # Options: "gpt-4", "gpt-3.5-turbo", "gpt-4-turbo"
    # ...
)
```

**Recommendations:**
- `gpt-4`: Best accuracy, slower, $0.03/1K tokens
- `gpt-4-turbo`: Faster, same quality, $0.01/1K tokens
- `gpt-3.5-turbo`: Fastest, lower cost, good for basic checks

### Customize System Prompt

Edit the analysis focus in `src/module4_agent/pr_guardian.py` (line ~22):

```python
SYSTEM_PROMPT = """You are CORTEX-Guardian, an elite code security and quality analyst.

Your mission: Analyze Pull Request code diffs for:
1. 🔐 Security vulnerabilities (SQL injection, XSS, secrets exposure, etc.)
2. 🐛 Potential bugs and logic errors
3. ⚡ Performance issues and anti-patterns
4. 📐 Code quality concerns (complexity, maintainability)

# Add your custom rules here:
5. Terraform best practices
6. AWS security compliance (IAM, S3 policies, etc.)
"""
```

### Block PR Merge on Critical Issues

Edit `src/module4_agent/pr_guardian.py` (line ~289):

```python
# Exit with non-zero if critical issues found (blocks merge)
if "CRITICAL" in result['risk_level']:
    print("\n⚠️  CRITICAL issues detected - review required!")
    sys.exit(1)  # Uncomment to block PR merge
```

Enable GitHub branch protection:
- **Settings → Branches → Add rule**
- Pattern: `main`
- ✅ **Require status checks to pass before merging**
- Select: `🛡️ CORTEX Guardian - PR Security Scanner`

---

## Troubleshooting

### Issue: "Missing required environment variables"

**Cause**: GitHub secrets not configured.

**Fix**:
1. Check secret names match exactly (case-sensitive)
2. Verify secrets are set in correct repository
3. Re-run workflow after adding secrets

### Issue: "OpenAI API rate limit exceeded"

**Cause**: Too many PR scans in short time.

**Fix**:
1. Wait for rate limit reset (usually 1 minute)
2. Consider upgrading OpenAI plan
3. Switch to `gpt-3.5-turbo` for higher rate limits

### Issue: "Webhook not reaching Module 2"

**Cause**: Incorrect webhook URL or Lambda not responding.

**Fix**:
1. Verify URL: `terraform output github_webhook_url`
2. Check Lambda logs: `aws logs tail /aws/lambda/cloud-tibot_git_radar --follow`
3. Test manually with `Invoke-RestMethod` (see Test 2 above)

### Issue: "No Telegram notification received"

**Cause**: Module 2 not updated or Telegram credentials missing.

**Fix**:
1. Verify Module 2 deployment: `terraform apply`
2. Check Lambda environment variables have `TELEGRAM_TOKEN` and `TELEGRAM_CHAT_ID`
3. Test Lambda directly: `aws lambda invoke --function-name cloud-tibot_git_radar ...`

---

## Cost Estimates

### OpenAI API Costs (GPT-4)

- **Small PR** (< 500 lines): ~$0.05 per scan
- **Medium PR** (500-2000 lines): ~$0.15 per scan
- **Large PR** (> 2000 lines): ~$0.30 per scan

### Monthly Estimates

| PRs per Month | Cost (GPT-4) | Cost (GPT-3.5-turbo) |
|---------------|--------------|----------------------|
| 10 PRs        | $1 - $3      | $0.20 - $0.50        |
| 50 PRs        | $5 - $15     | $1 - $2.50           |
| 200 PRs       | $20 - $60    | $4 - $10             |

### AWS Lambda Costs

**Module 2 updates**: Negligible (< $0.01/month)
- Webhook processing is very fast (< 100ms)
- Free tier covers most usage

---

## Advanced Features

### Exclude Files from Scanning

Modify `.github/workflows/cortex_guardian.yml`:

```yaml
- name: 🛡️ Run CORTEX Guardian Scan
  env:
    EXCLUDE_PATTERNS: "*.lock,package-lock.json,yarn.lock,*.min.js"
  run: |
    python src/module4_agent/pr_guardian.py
```

Update `pr_guardian.py` to filter files based on `EXCLUDE_PATTERNS`.

### Multi-Repository Setup

Use GitHub Actions **Organization Secrets** to share configuration across all repos:
- `OPENAI_API_KEY` (organization-wide)
- `CORTEX_RADAR_WEBHOOK` (organization-wide)

Copy workflow file to each repository or use a reusable workflow.

### Integration with Other Tools

Module 4 can be extended to integrate with:
- **SonarQube**: Send results to SonarQube dashboard
- **Slack**: Duplicate notifications to Slack channels
- **Jira**: Auto-create security tickets for critical findings
- **GitHub Issues**: Create tracking issues for recurring problems

---

## Files Created

| Path | Purpose |
|------|---------|
| `src/module4_agent/pr_guardian.py` | Main agent script (Python) |
| `src/module4_agent/requirements.txt` | Python dependencies |
| `.github/workflows/cortex_guardian.yml` | GitHub Actions workflow |
| `src/module2/lambda_function.py` | Modified to handle `agent_scan` events |
| `CORTEX_GUARDIAN_README.md` | This documentation |

---

## Support & Maintenance

### Version History

- **v1.0** (2026-02-10): Initial release
  - OpenAI GPT-4 integration
  - GitHub Actions workflow
  - Module 2 webhook integration
  - Telegram notifications

### Future Enhancements

- [ ] Support for incremental diff analysis (only changed lines)
- [ ] Custom rule engine (YAML-based security policies)
- [ ] Multi-language LLM support (Claude, Gemini, etc.)
- [ ] Integration with GitHub Security Advisories
- [ ] Automated fix suggestions (PR comments with code snippets)
- [ ] Dashboard analytics (track security trends over time)

---

## License & Credits

Part of **Project CORTEX** - Serverless ChatOps Intelligence System

Built with:
- 🐍 Python 3.11
- 🤖 OpenAI GPT-4
- ☁️ AWS Lambda + API Gateway
- 📱 Telegram Bot API
- 🐙 GitHub Actions + PyGithub

---

## Quick Reference

### Commands

```powershell
# Deploy Module 2 updates
.\Build-LambdaPackages.ps1 -CleanBuild
terraform apply

# Check workflow status
gh run list --workflow="cortex_guardian.yml"

# View live logs
gh run view --log

# Get webhook URL
terraform output github_webhook_url

# Test webhook manually
Invoke-RestMethod -Uri $webhook_url -Method Post -Body $test_payload -ContentType "application/json"
```

### Environment Variables

| Variable | Set In | Purpose |
|----------|--------|---------|
| `GITHUB_TOKEN` | Auto (GitHub Actions) | PR access |
| `OPENAI_API_KEY` | GitHub Secrets | AI analysis |
| `CORTEX_RADAR_WEBHOOK` | GitHub Secrets | Module 2 URL |
| `TELEGRAM_TOKEN` | Lambda env vars | Telegram bot |
| `TELEGRAM_CHAT_ID` | Lambda env vars | Chat ID |

---

**🎉 CORTEX Guardian is now active and protecting your code!**

For issues or questions, check CloudWatch logs:
```bash
aws logs tail /aws/lambda/cloud-tibot_git_radar --follow
```
