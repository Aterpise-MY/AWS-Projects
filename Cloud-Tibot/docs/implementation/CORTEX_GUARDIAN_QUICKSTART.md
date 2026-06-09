# ⚡ CORTEX Guardian - Quick Start

## 🚀 Deploy in 3 Steps

### 1️⃣ Deploy Module 2
```powershell
terraform apply
```

### 2️⃣ Add GitHub Secrets
```
Repository Settings → Secrets → Actions → New secret

Add:
- OPENAI_API_KEY = sk-proj-xxxxx...
- CORTEX_RADAR_WEBHOOK = (run: terraform output github_webhook_url)
```

### 3️⃣ Test
```bash
# Push code to trigger workflow
git add .
git commit -m "feat: Add CORTEX Guardian"
git push

# Create test PR
git checkout -b test/guardian
echo "print('test')" > test.py
git add test.py
git commit -m "test: Guardian scan"
git push origin test/guardian
gh pr create --title "Test Guardian" --body "Testing"
```

## 📊 What Happens

```
PR Created → GitHub Actions → AI Analysis → PR Comment + Telegram
```

## 🔍 Monitor

```powershell
# Check workflow
gh run list --workflow="cortex_guardian.yml"

# Watch logs
aws logs tail /aws/lambda/cloud-tibot_git_radar --follow
```

## 🧪 Manual Test

```powershell
$url = terraform output -raw github_webhook_url
$payload = @{event="agent_scan";pr=999;status="🟢 Clean";risk_level="✅ CLEAN";summary="Test";repository="test/repo";scanner="CORTEX-Guardian";timestamp=(Get-Date).ToUniversalTime().ToString("o")} | ConvertTo-Json
Invoke-RestMethod -Uri $url -Method Post -Body $payload -ContentType "application/json"
```

Expected: Telegram message with "🛡️ **[CORTEX GUARDIAN]**"

## 💰 Cost
~$0.05 per PR scan (GPT-4)  
~$3-6/month for 20 PRs

## 📁 Files
- `src/module4_agent/pr_guardian.py` - Scanner
- `.github/workflows/cortex_guardian.yml` - Workflow  
- `src/module2/lambda_function.py` - Updated handler
- `CORTEX_GUARDIAN_README.md` - Full docs
- `CORTEX_GUARDIAN_IMPLEMENTATION.md` - Deployment guide

## ⚠️ Troubleshooting
| Issue | Fix |
|-------|-----|
| Workflow not running | Check `.github/workflows/` committed, Actions enabled |
| Missing env vars | Add secrets: OPENAI_API_KEY, CORTEX_RADAR_WEBHOOK |
| No Telegram msg | Deploy Module 2: `terraform apply` |
| Webhook failed | Check Lambda logs, verify URL correct |

## 📚 Docs
- **Full Setup**: `CORTEX_GUARDIAN_README.md`
- **Implementation**: `CORTEX_GUARDIAN_IMPLEMENTATION.md`
