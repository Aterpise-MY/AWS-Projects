# ✅ GitHub Copilot/AI Integration - Preparation Checklist

## What You Need to Prepare (Choose One Path)

### 🆓 Path A: GitHub Models (FREE - Recommended)

**Time**: 5 minutes

- [ ] **Step 1**: Generate GitHub Personal Access Token
  - URL: https://github.com/settings/tokens?type=beta
  - Scopes needed: `repo` + `model` (or AI models)
  - Save the token (starts with `github_pat_`)

- [ ] **Step 2**: Add GitHub Secret
  - Go to: https://github.com/Brendon20011007/Cloud-Tibot/settings/secrets/actions/new
  - Name: `GITHUB_MODELS_TOKEN`
  - Value: [your token]

- [ ] **Step 3**: Choose AI Model (optional)
  - Default: `gpt-4o-mini` (fast, free)
  - Options: `gpt-4o`, `claude-3.5-sonnet`, `llama-3.1-70b`

- [ ] **Step 4**: Tell me to implement
  - Say: **"Use GitHub Models"**
  - I'll update the code for you

**What You Get:**
- ✅ FREE AI-powered PR scanning
- ✅ No OpenAI costs ever
- ✅ 150 PR scans per day included
- ✅ GPT-4o or Claude 3.5 models

---

### 💳 Path B: OpenAI API (PAID - Current Setup)

**Time**: 2 minutes (if not already done)

- [ ] **Step 1**: Get OpenAI API Key (if you don't have)
  - URL: https://platform.openai.com/api-keys
  - Create new key
  - Save it (starts with `sk-proj-`)

- [ ] **Step 2**: Add GitHub Secret (if not already added)
  - Go to: https://github.com/Brendon20011007/Cloud-Tibot/settings/secrets/actions
  - Check if `OPENAI_API_KEY` exists
  - If not, add it with your key

- [ ] **Step 3**: No code changes needed!
  - Current implementation already uses OpenAI

**What You Get:**
- ✅ High rate limits (thousands/day)
- ✅ Proven, reliable
- ✅ GPT-4 or GPT-3.5-turbo
- ❌ Costs ~$3-6/month (~$0.05 per PR)

---

### 🔄 Path C: Hybrid (BEST - Both)

**Time**: 7 minutes

- [ ] **Do Path A** (GitHub Models setup)
- [ ] **Do Path B** (OpenAI setup)
- [ ] **Tell me**: **"Use Hybrid Mode"**
  - I'll implement smart fallback logic

**What You Get:**
- ✅ FREE for first 150 PRs/day (GitHub Models)
- ✅ Automatic fallback to OpenAI if limit hit
- ✅ Best reliability
- ✅ Cost savings (~80% reduction)

---

## Quick Commands

### Check if tokens already exist:
```powershell
# Check GitHub secret (returns 404 if doesn't exist)
gh secret list | Select-String "OPENAI_API_KEY"
gh secret list | Select-String "GITHUB_MODELS_TOKEN"
```

### Generate GitHub token (automated):
```bash
# Note: Requires `gh` CLI and manual scope selection in browser
gh auth refresh -h github.com -s model,repo
```

### Set secrets via CLI (after getting tokens):
```powershell
# Set GitHub Models token
gh secret set GITHUB_MODELS_TOKEN

# Set OpenAI key (if needed)
gh secret set OPENAI_API_KEY
```

---

## Decision Helper

Answer these questions:

**1. How many PRs does your team create per day?**
- < 50 PRs/day → Use **GitHub Models** (free)
- 50-100 PRs/day → Use **GitHub Models** (free, monitor)
- 100-150 PRs/day → Use **Hybrid** (mostly free)
- > 150 PRs/day → Use **OpenAI** (paid, reliable)

**2. Do you have budget for AI?**
- No budget → Use **GitHub Models** (free)
- Small budget → Use **Hybrid** ($1-2/month)
- Have budget → Use **OpenAI** ($3-6/month)

**3. Do you need guaranteed reliability?**
- Yes, critical → Use **Hybrid** or **OpenAI**
- No, can tolerate rate limits → Use **GitHub Models**

---

## My Recommendation for You

Based on typical usage:

**Start Here**: **GitHub Models** (FREE)
- No risk, free trial
- Test for 1 week
- See if it meets your needs

**If you hit limits**: **Upgrade to Hybrid**
- Keep GitHub Models as primary (free)
- Add OpenAI as backup (paid)

**Only if high volume**: **Pure OpenAI**
- > 150 PRs/day consistently
- Enterprise usage

---

## What Happens Next?

### Once you tell me your choice:

**If "GitHub Models":**
1. I'll update `src/module4_agent/pr_guardian.py`
2. I'll update `.github/workflows/cortex_guardian.yml`
3. I'll update `requirements.txt` (remove `openai` dependency)
4. You push changes → Done! ✅

**If "Hybrid":**
1. I'll update `pr_guardian.py` with smart fallback
2. I'll update workflow with both tokens
3. I'll add rate limit detection
4. You push changes → Done! ✅

**If "Keep OpenAI":**
1. No changes needed!
2. Current setup already works ✅

---

## Testing After Implementation

### Test GitHub Models integration:
```powershell
# Create test PR
git checkout -b test/github-models
echo "print('test')" > test_ai.py
git add test_ai.py
git commit -m "test: GitHub Models integration"
git push origin test/github-models
gh pr create --title "Test: GitHub Models" --body "Testing free AI"
```

### Check workflow execution:
```bash
# Watch workflow run
gh run watch

# Check logs
gh run view --log
```

### Verify in logs:
Look for:
```
🛡️ CORTEX-Guardian initialized
   AI Model: gpt-4o-mini
   ✅ Analysis complete
```

---

## Cost Comparison (Monthly)

| Scenario | GitHub Models | Hybrid | OpenAI Only |
|----------|---------------|--------|-------------|
| 10 PRs/day | **$0** | **$0** | **$1-3** |
| 50 PRs/day | **$0** | **$0-1** | **$5-15** |
| 150 PRs/day | **$0** | **$1-2** | **$15-45** |
| 300 PRs/day | ⚠️ Hit limit | **$8-15** | **$30-90** |

---

## 🚀 Ready? Choose Your Path!

Reply with:
- **"Use GitHub Models"** → I'll implement free AI
- **"Use Hybrid"** → I'll implement fallback system
- **"Keep OpenAI"** → No changes
- **"Show me the code first"** → I'll show you the changes before applying

I'm ready to implement immediately! 🎯
