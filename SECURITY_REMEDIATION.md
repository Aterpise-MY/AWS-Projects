# 🚨 SECURITY REMEDIATION PLAN — Exposed Secrets

**Date:** 2026-06-09  
**Severity:** 🔴 CRITICAL  
**Status:** Action Required

---

## Exposed Secrets Found

### 1. Telegram Bot Token ⚠️ CRITICAL

**Location:** `Cloud-Tibot/infrastructure/terraform/terraform.tfvars.deploy`  
**Value:** `8281522719:AAHb8gk-sIVpjnGmOIYbE5FuzZ347J4FKTc`  
**Risk:** Anyone with this token can send messages to your Telegram bot, impersonate notifications, and potentially access other integrations.

**Remediation Steps:**

```bash
# 1. Revoke the current token in Telegram
# Go to https://t.me/BotFather and use /revoke command
# Then create a new bot token

# 2. Update Secrets Manager with new token
aws secretsmanager update-secret \
  --secret-id /cortex-infra/telegram-bot-token \
  --secret-string "YOUR_NEW_TOKEN_HERE" \
  --region us-east-1

# 3. Update Lambda environment variables
aws lambda update-function-configuration \
  --function-name cortex_finops_sentinel \
  --environment Variables="{TELEGRAM_TOKEN=YOUR_NEW_TOKEN_HERE}" \
  --region us-east-1

# 4. Repeat for all other Lambda functions:
# - cortex_auto_remediator
# - cortex_git_radar
# - cortex_copilot_guardian
# - cortex-telegram-approval-handler
```

**Deadline:** ✅ **DO THIS NOW** (before this repo is accessed by anyone)

---

### 2. GitHub App Private Key ⚠️ CRITICAL

**Location:** `Cloud-Tibot/infrastructure/terraform/terraform.tfvars.deploy`  
**Value:** `IpIEa4xqv8FeigqIDPBXjuvQdHgmi8GUeb1HbZ7BfP4=` (base64 encoded)  
**Risk:** Anyone with this key can authenticate as your GitHub App and access repositories, modify code, trigger workflows, etc.

**Remediation Steps:**

```bash
# 1. Rotate the GitHub App private key
# Go to https://github.com/settings/apps/your-app-id
# Delete the old private key and generate a new one

# 2. Download the new .pem file

# 3. Encode it to base64
cat your-new-private-key.pem | base64 | tr -d '\n'

# 4. Update Secrets Manager
aws secretsmanager update-secret \
  --secret-id /cortex-infra/github-app-private-key \
  --secret-string "YOUR_NEW_BASE64_KEY" \
  --region us-east-1

# 5. Update terraform.tfvars.deploy
vim infrastructure/terraform/terraform.tfvars.deploy
# Set github_app_private_key = "YOUR_NEW_BASE64_KEY"

# 6. Redeploy infrastructure
terraform apply
```

**Deadline:** ✅ **DO THIS NOW**

---

## Cleaning Git History (Optional but Recommended)

Since secrets are already in git history, they will remain accessible even after removing them from files. Options:

### Option A: Remove from History (Requires Force Push)

```bash
# Remove the file from ALL git history
git filter-branch --tree-filter 'rm -f Cloud-Tibot/infrastructure/terraform/terraform.tfvars.deploy' -- --all

# Force push (⚠️ This rewrites history)
git push --force

# All collaborators must pull --rebase
```

**Risks:** Can break other branches/PRs. Only do if repo is small/new.

### Option B: Keep File but Update Git History (RECOMMENDED)

```bash
# 1. Remove secrets from the file
vim Cloud-Tibot/infrastructure/terraform/terraform.tfvars.deploy
# Replace actual values with placeholders:
# github_app_private_key = "REPLACE_WITH_YOUR_KEY"
# telegram_token = "REPLACE_WITH_YOUR_TOKEN"

# 2. Commit the change
git add Cloud-Tibot/infrastructure/terraform/terraform.tfvars.deploy
git commit -m "Sanitize exposed secrets in terraform.tfvars.deploy

These values were temporarily exposed in the git history.
All secrets have been rotated and updated in AWS Secrets Manager.

See SECURITY_REMEDIATION.md for details."

# 3. Push normally (no force push needed)
git push
```

**Note:** Old commits will still show the secrets in git history, but:
- ✅ New clones won't get the secrets
- ✅ File on current branch will be safe
- ✅ No history rewriting needed
- ✅ No impact on other developers

---

## Prevention: Updated .gitignore

Added to `.gitignore`:
- `terraform.tfvars` (actual vars, not example)
- `.env` and `.env.local` files
- `*_secret*`, `*_token*`, `*_key.pem` files
- `github_token.txt`, `telegram_token.txt`

These patterns will prevent future commits of secrets.

---

## Verification Checklist

After completing remediation:

- [ ] Telegram token revoked in BotFather
- [ ] New Telegram token created and stored in Secrets Manager
- [ ] GitHub App private key rotated
- [ ] New key stored in Secrets Manager
- [ ] All Lambda functions updated with new Telegram token
- [ ] terraform.tfvars.deploy sanitized (secrets replaced with placeholders)
- [ ] Commit pushed with sanitized file
- [ ] .gitignore updated and committed
- [ ] Test Lambda functions still receive Telegram notifications
- [ ] Test GitHub App still authenticates correctly

---

## References

- [GitHub: Managing secrets](https://docs.github.com/en/code-security/secret-scanning)
- [AWS: Secrets Manager rotation](https://docs.aws.amazon.com/secretsmanager/latest/userguide/rotating-secrets.html)
- [Telegram BotFather](https://t.me/BotFather)

---

**Status:** 🔴 AWAITING ACTION  
**Next Steps:** Execute remediation steps immediately

