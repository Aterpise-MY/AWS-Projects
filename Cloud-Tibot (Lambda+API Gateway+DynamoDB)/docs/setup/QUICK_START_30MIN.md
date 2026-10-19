# ⚡ Quick Action Checklist - Deploy in 30 Minutes

## 🎯 Goal
Deploy your complete CI/CD system with AI-powered reviews and Telegram notifications to IB-DND-5e-Platform.

---

## ✅ Phase 1: Preparation (5 minutes)

### Step 1: Create Telegram Bot
```
1. Open Telegram app
2. Search for: @BotFather
3. Send: /newbot
4. Bot Name: "DND Platform CI/CD Bot"
5. Bot Username: "dnd_platform_cicd_bot" (or available name)
6. 📝 Copy the token (looks like: 123456789:ABCdefGHIjklMNOpqrsTUVwxyz)
```

### Step 2: Get Telegram Chat ID
```
1. Start conversation with your new bot
2. Send any message (e.g., "Hello")
3. Open: https://api.telegram.org/bot<YOUR_TOKEN>/getUpdates
   Replace <YOUR_TOKEN> with your bot token
4. Look for "chat":{"id":YOUR_CHAT_ID}
5. 📝 Copy the chat ID (looks like: 123456789)
```

**✅ You should now have:**
- Telegram Bot Token: `123456789:ABCdefGHI...`
- Telegram Chat ID: `123456789`

---

## ✅ Phase 2: Copy Files (5 minutes)

### Open PowerShell and run:

```powershell
# Set paths (CHANGE THESE to your actual paths)
$cloudTibot = "C:\Users\BrendonAng\Cloud Tibot"
$dndPlatform = "C:\Path\To\IB-DND-5e-Platform"

# Create directories if they don't exist
New-Item -ItemType Directory -Force -Path "$dndPlatform\.github\workflows"
New-Item -ItemType Directory -Force -Path "$dndPlatform\scripts"  
New-Item -ItemType Directory -Force -Path "$dndPlatform\docs\integration"
New-Item -ItemType Directory -Force -Path "$dndPlatform\docs\deployment"

# Copy workflows
Copy-Item "$cloudTibot\.github\workflows\dnd-*.yml" "$dndPlatform\.github\workflows\" -Force

# Copy scripts
Copy-Item "$cloudTibot\scripts\telegram_bot.py" "$dndPlatform\scripts\" -Force
Copy-Item "$cloudTibot\setup-github-actions.ps1" "$dndPlatform\" -Force

# Copy documentation - GitHub Actions & Copilot integration guides
Copy-Item "$cloudTibot\docs\integration\GITHUB_*.md" "$dndPlatform\docs\integration\" -Force
Copy-Item "$cloudTibot\docs\integration\COPILOT_*.md" "$dndPlatform\docs\integration\" -Force

# Copy deployment checklists
Copy-Item "$cloudTibot\docs\deployment\DEPLOYMENT_CHECKLIST_GITHUB_ACTIONS.md" "$dndPlatform\docs\deployment\" -Force
Copy-Item "$cloudTibot\docs\deployment\DEPLOYMENT_CHECKLIST.md" "$dndPlatform\docs\deployment\" -Force

# Copy summary documents
Copy-Item "$cloudTibot\docs\integration\GITHUB_ACTIONS_SUMMARY.md" "$dndPlatform\docs\integration\" -Force

Write-Host "✅ Files copied successfully!" -ForegroundColor Green
```

**✅ Verify files copied:**
```powershell
cd $dndPlatform
ls .github\workflows\dnd-*.yml
ls scripts\telegram_bot.py
ls docs\integration\GITHUB_*.md
ls docs\deployment\DEPLOYMENT_CHECKLIST*.md
```

---

## ✅ Phase 3: Configure Secrets (10 minutes)

### Run setup script:

```powershell
cd $dndPlatform
.\setup-github-actions.ps1
```

**The script will prompt for 15 secrets:**

### 1. AWS Secrets (3)
```
AWS_ACCESS_KEY_ID:     AKIA...
AWS_SECRET_ACCESS_KEY: wJalr...
AWS_REGION:            us-east-1
```
**Get from:** AWS IAM Console → Your User → Security Credentials

### 2. Telegram Secrets (2)
```
TELEGRAM_BOT_TOKEN: 123456789:ABCdefGHI... (from Step 1)
TELEGRAM_CHAT_ID:   123456789 (from Step 2)
```

### 3. Supabase Secrets (2)
```
SUPABASE_SERVICE_ROLE_KEY: eyJhbGc...
SUPABASE_URL:              https://xxx.supabase.co
```
**Get from:** Supabase Dashboard → Project Settings → API

### 4. Gemini API (1)
```
GEMINI_API_KEY: AIzaSy...
```
**Get from:** https://aistudio.google.com/app/apikey

### 5. Vercel Secrets (3)
```
VERCEL_TOKEN:      xxx...
VERCEL_ORG_ID:     team_xxx...
VERCEL_PROJECT_ID: prj_xxx...
```
**Get from:** Vercel Dashboard → Settings → Tokens

### 6. DynamoDB (1)
```
DYNAMODB_TABLE_NAME: DndCharacters
```
**Your table name from AWS**

### 7. API Gateway (1)
```
API_GATEWAY_URL: https://xxx.execute-api.us-east-1.amazonaws.com/prod
```
**Your API Gateway URL from AWS**

### 8. GitHub Token (1)
```
PAT_TOKEN: ghp_xxx...
```
**Get from:** GitHub → Settings → Developer Settings → Personal Access Tokens → Generate New Token
**Scopes needed:** `repo`, `workflow`

### 9. GitHub Token (Already exists)
```
GITHUB_TOKEN: (Automatically provided by GitHub Actions)
```
**No action needed** - GitHub provides this automatically

**✅ All secrets configured!**

---

## ✅ Phase 4: Enable & Test (10 minutes)

### Step 1: Enable GitHub Actions

1. Open browser: `https://github.com/Brendon20011007/IB-DND-5e-Platform`
2. Go to: Settings → Actions → General
3. Select: "Allow all actions and reusable workflows"
4. Click: Save

### Step 2: Commit & Push Files

```powershell
cd $dndPlatform

# Check what's new
git status

# Add files
git add .github/
git add scripts/
git add docs/
git add setup-github-actions.ps1
git add COMPLETE_SYSTEM_SUMMARY.md

# Commit
git commit -m "feat: Add CI/CD workflows with AI review and Telegram integration

- Add dnd-platform-ci.yml for continuous integration
- Add dnd-pr-review.yml for AI-powered PR reviews  
- Add dnd-deploy.yml for production deployment
- Add Telegram bot integration
- Add comprehensive documentation"

# Push to main
git push origin main
```

### Step 3: Create Test PR

```powershell
# Create test branch
git checkout -b test/ci-cd-system

# Make a small change
echo "`n# CI/CD System Active" >> README.md

# Commit and push
git add README.md
git commit -m "test: Verify CI/CD system"
git push origin test/ci-cd-system
```

### Step 4: Create PR on GitHub

1. Open: `https://github.com/Brendon20011007/IB-DND-5e-Platform`
2. Click: "Compare & pull request" (yellow banner)
3. Title: "Test: CI/CD System Verification"
4. Click: "Create pull request"

### Step 5: Watch the Magic! ✨

**Within 30 seconds:**
- ✅ CI workflow starts (frontend, lambda, terraform validation)
- ✅ PR review workflow starts (AI analysis)

**Within 5 minutes:**
- ✅ Telegram notification arrives with PR details
- ✅ AI code review comment posted on PR
- ✅ Auto-labels applied (e.g., "documentation")
- ✅ Terraform plan posted (if infra changed)

**Check:**
1. GitHub Actions tab: `https://github.com/Brendon20011007/IB-DND-5e-Platform/actions`
2. PR Comments: Should see AI review
3. Telegram: Should see notification with buttons

---

## ✅ Phase 5: Deploy to Production (Optional)

### If everything looks good:

```powershell
# Merge the PR on GitHub
# Then pull latest main
git checkout main
git pull origin main
```

**Watch deployment:**
- ✅ Deploy workflow starts automatically
- ✅ Terraform applies infrastructure
- ✅ Lambda functions deployed (6x)
- ✅ Supabase edge functions deployed
- ✅ Frontend deployed to Vercel
- ✅ Smoke tests run
- ✅ Telegram success notification

**Check:**
- GitHub Actions → dnd-deploy workflow
- Telegram → Deployment success message
- Your site: Should be live

---

## 🎉 Success Criteria

### ✅ You know it's working when:

1. **CI Workflow** ✅
   - Runs on every push
   - Takes ~7 minutes
   - All checks pass (green)

2. **PR Review** ✅
   - AI comment appears on PR
   - Auto-labels applied
   - Telegram notification received
   - Takes ~5 minutes

3. **Deployment** ✅
   - Runs on main branch merge
   - All resources deployed
   - Smoke tests pass
   - Telegram success message
   - Takes ~12 minutes

4. **Telegram Bot** ✅
   - Receives notifications
   - Buttons work (View PR, Approve)
   - Messages formatted correctly

---

## 🐛 Troubleshooting

### Problem: "Workflow not running"

**Solution:**
```powershell
# Check workflow files exist
ls .github\workflows\dnd-*.yml

# Check GitHub Actions enabled
# Visit: Settings → Actions → General
```

### Problem: "Secrets not found"

**Solution:**
```powershell
# Re-run setup
.\setup-github-actions.ps1

# Or manually check:
# Visit: Settings → Secrets and variables → Actions
```

### Problem: "Telegram not working"

**Solution:**
```powershell
# Test bot locally
python scripts/telegram_bot.py

# Verify token and chat ID correct
# Visit: Settings → Secrets → TELEGRAM_BOT_TOKEN
```

### Problem: "AI review not posting"

**Solution:**
```
Check GitHub Actions logs:
1. Go to Actions tab
2. Click on failed workflow
3. Click on "ai-code-review" job
4. Look for error messages

Common issue: GEMINI_API_KEY not set or invalid
```

---

## 📊 Timeline Summary

| Phase | Time | Status |
|-------|------|--------|
| Create Telegram Bot | 5 min | ⏳ Not Started |
| Copy Files | 5 min | ⏳ Not Started |
| Configure Secrets | 10 min | ⏳ Not Started |
| Enable & Test | 10 min | ⏳ Not Started |
| **Total** | **30 min** | **Ready to Start** |

---

## 🚀 Next Actions

### Right Now:
1. ⏳ Create Telegram bot (scroll to top)
2. ⏳ Copy files with PowerShell commands
3. ⏳ Run setup script
4. ⏳ Create test PR

### This Week:
5. ⏳ Monitor first few PRs
6. ⏳ Review AI feedback quality
7. ⏳ Adjust Telegram notification preferences
8. ⏳ Train team on new workflows

### Next Week (Optional):
9. ⏳ Consider Copilot SDK enhancement
10. ⏳ Install Copilot SDK dependencies
11. ⏳ Test enhanced AI reviews
12. ⏳ Optimize costs and performance

---

## 📞 Help

**If stuck:**
1. Read [COMPLETE_SYSTEM_SUMMARY.md](./COMPLETE_SYSTEM_SUMMARY.md)
2. Check [DEPLOYMENT_CHECKLIST_GITHUB_ACTIONS.md](./docs/DEPLOYMENT_CHECKLIST_GITHUB_ACTIONS.md)
3. Review workflow logs in GitHub Actions tab

**Everything you need is documented!**

---

## 🎯 Start Now!

**Your 30-minute countdown starts... NOW! ⏱️**

**Step 1: Open Telegram and search for @BotFather** 👆

```
Time Budget:
- Telegram Bot: 5 min ⏱️
- Copy Files: 5 min ⏱️  
- Configure Secrets: 10 min ⏱️
- Test: 10 min ⏱️
-------------------
Total: 30 min ⏱️

Ready? GO! 🚀
```
