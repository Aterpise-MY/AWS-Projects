# 🚀 GitHub Copilot / AI Models Integration - What You Need

## ⚡ TL;DR - What To Prepare

### For GitHub Models (FREE - Recommended):
1. Generate GitHub Personal Access Token with `model` scope
2. Add token as `GITHUB_MODELS_TOKEN` secret in repository
3. Update `pr_guardian.py` to use GitHub Models API
4. Done! ✅

### For OpenAI (Current - Paid):
1. Get OpenAI API key
2. Add as `OPENAI_API_KEY` secret (already done)
3. Keep current code
4. Done! ✅

---

## 📋 Step-by-Step: Switch to GitHub Models (Free)

### What You'll Get:
- 🆓 **FREE AI analysis** (no OpenAI costs)
- 🤖 **GPT-4o, Claude 3.5, Llama 3.1** models available
- ⚡ **15 requests/min, 150/day** rate limit
- 🔒 **Same GitHub authentication** you already use

### Step 1: Generate GitHub Token

1. **Go to**: https://github.com/settings/tokens?type=beta

2. **Click**: "Generate new token" → "Generate new token (classic)"

3. **Configure**:
   ```
   Note: CORTEX Guardian - AI Models
   Expiration: 90 days (recommended)
   
   Select scopes:
   ✅ repo (full control)
   ✅ read:packages (optional)
   
   Then scroll down to:
   ✅ AI models (NEW - look for "AI" or "models" section)
   ```

4. **Copy the token** - You won't see it again!
   - Format: `github_pat_11XXXXXX...`

### Step 2: Add as GitHub Secret

1. G to your repository: `https://github.com/Brendon20011007/Cloud-Tibot`

2. Navigate: **Settings** → **Secrets and variables** → **Actions**

3. Click: **"New repository secret"**

4. Add:
   ```
   Name: GITHUB_MODELS_TOKEN
   Value: [paste your token from Step 1]
   ```

5. Click **"Add secret"**

### Step 3: Update Workflow File

Update `.github/workflows/cortex_guardian.yml`:

```yaml
- name: 🛡️ Run CORTEX Guardian Scan
  env:
    GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}  # Keep this
    GITHUB_MODELS_TOKEN: ${{ secrets.GITHUB_MODELS_TOKEN }}  # Add this
    CORTEX_RADAR_WEBHOOK: ${{ secrets.CORTEX_RADAR_WEBHOOK }}
    GITHUB_REPOSITORY: ${{ github.repository }}
    GITHUB_EVENT_PATH: ${{ github.event_path }}
    AI_MODEL: "gpt-4o-mini"  # Add this - options: gpt-4o, gpt-4o-mini, claude-3.5-sonnet
  run: |
    python src/module4_agent/pr_guardian.py
```

### Step 4: Update pr_guardian.py

I'll provide the updated code that supports **both OpenAI and GitHub Models**!

---

## 🔧 Implementation Options

### Option A: GitHub Models Only (Simple)

**Benefits:**
- No OpenAI API key needed
- Completely free
- Simpler setup

**When to use:**
- Small team (< 150 PRs/day)
- Cost-conscious
- Getting started

### Option B: Keep OpenAI (Current)

**Benefits:**
- Higher rate limits
- Already working
- Predictable costs (~$3-6/month)

**When to use:**
- High volume (> 150 PRs/day)
- Enterprise usage
- Consistent performance needed

### Option C: Hybrid (Best of Both)

**Benefits:**
- GitHub Models as primary (free)
- OpenAI as fallback (reliable)
- Automatic switching on rate limits

**When to use:**
- Want to maximize free tier
- Need reliability backup
- Growing team

---

## 📦 What I'll Provide

I can update your code to support:

### 1. **GitHub Models Only** (Recommended to start)
- Replace OpenAI with GitHub Models API
- Free, no OpenAI key needed
- Rate limits: 15/min, 150/day

### 2. **Hybrid Mode** (Best long-term)
- Try GitHub Models first (free)
- Fall back to OpenAI if limit hit
- Best of both worlds

### 3. **Keep Current** (OpenAI only)
- No changes needed
- Continue with OpenAI
- Costs: ~$3-6/month

---

## 🎯 My Recommendation

**For your setup, I recommend:**

**Phase 1: GitHub Models** (Now - Free)
- Switch to GitHub Models
- Test for 1 week
- Monitor rate limits

**Phase 2: Add Hybrid** (If needed)
- If you hit rate limits
- Add OpenAI as fallback
- Best reliability

**Why this approach:**
- Start free
- Test if GitHub Models sufficient
- Only pay for OpenAI if actually needed
- Saves ~$36-72/year if GitHub Models work

---

## 📊 Rate Limit Calculator

**GitHub Models Limits:**
- 15 requests per minute
- 150 requests per day

**Your usage estimate:**
| PRs per Day | Will GitHub Models Work? |
|-------------|--------------------------|
| < 50 PRs    | ✅ Yes, no issues |
| 50-100 PRs  | ✅ Yes, comfortable |
| 100-150 PRs | ⚠️ Near limit, monitor |
| > 150 PRs   | ❌ Need hybrid or OpenAI |

**Calculate your need:**
```
Daily PRs = [your team PRs per day]
PRs per hour average = Daily PRs / 8 hours
PRs per minute peak = PRs per hour / 4

If peak < 15/min AND daily < 150: GitHub Models sufficient
Else: Use hybrid mode
```

---

## 🔑 Important Notes

### GitHub Token Permissions

Your token needs these scopes:
- ✅ `repo` - Access repository (read PR, post comments)
- ✅ `model` or AI models - Access GitHub Models API
- ✅ `read:packages` - (Optional but recommended)

### Security Best Practices

1. **Token Expiration**: 
   - Set to 90 days
   - Add calendar reminder to renew
   - Automated renewal coming soon from GitHub

2. **Token Storage**:
   - ✅ Store in GitHub Secrets (encrypted)
   - ❌ Never commit to code
   - ❌ Never log the full token

3. **Rate Limits**:
   - Monitor in workflow logs
   - Set up alerts if approaching limits
   - Consider hybrid if hitting limits

---

## ❓ FAQ

### Q: Do I need to keep OPENAI_API_KEY secret?
**A**: Not if you switch to GitHub Models only. But keeping it allows easy fallback later.

### Q: Can I use both GitHub Models and OpenAI?
**A**: Yes! Hybrid mode uses GitHub Models first, falls back to OpenAI on rate limit.

### Q: Which model is better - GPT-4o or Claude 3.5?
**A**: 
- **GPT-4o-mini**: Fastest, good quality, recommended start
- **GPT-4o**: Best quality, slower
- **Claude 3.5 Sonnet**: Excellent reasoning, good for complex code

### Q: What about GitHub Copilot SDK in VS Code?
**A**: That's different - for VS Code extensions only, can't use in GitHub Actions.

### Q: Will this break my existing setup?
**A**: No! Changes are additive. Module 2 (Git Radar) doesn't need updates.

### Q: How do I test before committing?
**A**: Run locally with `GITHUB_MODELS_TOKEN` env var set, or test in a separate branch.

---

## 🚀 Ready to Implement?

**Tell me which option you want:**

1. **"Use GitHub Models"** - I'll update the code for free AI (recommended)
2. **"Use Hybrid"** - I'll implement GitHub Models with OpenAI fallback
3. **"Keep OpenAI"** - No changes, continue with current setup

I'll update the files immediately! 🎯
