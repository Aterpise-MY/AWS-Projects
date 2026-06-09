# GitHub App Setup Guide for CORTEX
## Complete Guide for Implementing GitHub App JWT Authentication

This guide walks you through setting up GitHub App authentication for Project CORTEX's GitHub Copilot SDK integration.

---

## Prerequisites

✅ Active GitHub Copilot subscription (Individual or Business)
✅ GitHub account with permissions to create Apps  
✅ AWS account with Lambda deployment access
✅ Terraform installed locally

---

## Part 1: Create GitHub App

### Step 1: Navigate to GitHub App Settings

**For Personal Account:**
- Go to https://github.com/settings/apps
- Click **"New GitHub App"**

**For Organization:**
- Go to https://github.com/organizations/YOUR-ORG/settings/apps
- Click **"New GitHub App"**

### Step 2: Configure Basic Information

Fill in the required fields:

```
GitHub App name: CORTEX-DevOps-Agent
Homepage URL: https://github.com/YOUR-USERNAME/YOUR-REPO
Webhook URL: (leave blank for now or use your API Gateway endpoint)
Webhook secret: (optional - can add later)
```

### Step 3: Set Permissions

**Critical Permissions Required:**

#### Repository Permissions:
- ✅ **Contents**: Read & write (for reading/modifying code)
- ✅ **Issues**: Read & write (for creating issues)
- ✅ **Pull requests**: Read & write (for PR reviews and creation)
- ✅ **Workflows**: Read & write (for rerunning failed workflows)

#### Account Permissions:
- ✅ **Copilot**: **Read** access (CRITICAL - this enables Copilot API access!)

### Step 4: Subscribe to Events (Optional)

If you want webhook integration:
- ✅ Push
- ✅ Pull request
- ✅ Workflow run

### Step 5: Where can this app be installed?

- Select: **"Only on this account"** (or "Any account" if sharing)

### Step 6: Create the App

Click **"Create GitHub App"**

---

## Part 2: Capture Credentials

### Step 1: Get App ID

After creation, you'll see your GitHub App settings page.

**Copy the App ID** (shown near the top):
```
App ID: 123456
```

Save this - you'll need it for `github_app_id`

### Step 2: Generate Private Key

1. Scroll down to **"Private keys"** section
2. Click **"Generate a private key"**
3. A `.pem` file will download automatically
4. **IMPORTANT**: Keep this file secure! It's your authentication key

The file contents look like:
```
-----BEGIN RSA PRIVATE KEY-----
MIIEpAIBAAKCAQEA...
...many lines of encrypted text...
...
-----END RSA PRIVATE KEY-----
```

### Step 3: Install the App

1. In the left sidebar, click **"Install App"**
2. Click **"Install"** next to your account/organization
3. Choose repository access:
   - **All repositories** (easiest), OR
   - **Only select repositories** (more secure)
4. Click **"Install"**

### Step 4: Get Installation ID

After installation, you'll be redirected to a URL like:
```
https://github.com/settings/installations/12345678
                                          ^^^^^^^^
                                          This is your Installation ID!
```

**Copy the Installation ID** (the number in the URL)

Save this - you'll need it for `github_app_installation_id`

---

## Part 3: Configure Terraform

### Step 1: Update terraform.tfvars

Open or create `terraform.tfvars` and add:

```hcl
# GitHub App Authentication
github_app_id              = "123456"  # Your App ID from Part 2, Step 1
github_app_installation_id = "12345678"  # Your Installation ID from Part 2, Step 4

# Private Key - paste the ENTIRE content of the .pem file
github_app_private_key = <<-EOT
-----BEGIN RSA PRIVATE KEY-----
MIIEpAIBAAKCAQEA...
... (paste your FULL private key here, including BEGIN/END lines)
...
-----END RSA PRIVATE KEY-----
EOT

# Repository settings
github_repo_owner = "your-username-or-org"
github_repo_name  = "your-repo-name"

# Existing settings (keep these)
aws_region       = "us-east-1"
project_name     = "cortex"
environment      = "prod"
telegram_token   = "your-telegram-token"
telegram_chat_id = "your-chat-id"
```

**⚠️ CRITICAL**: 
- Include the **entire private key** including `-----BEGIN` and `-----END` lines
- Use the `<<-EOT` heredoc syntax shown above
- Do NOT add quotes around the key content

### Step 2: Validate Configuration

```bash
terraform validate
```

Should return: `Success! The configuration is valid.`

---

## Part 4: Install Python Dependencies

The Lambda functions now require `PyJWT` and `cryptography` for JWT signing.

### Option A: Install via pip (for local testing)

```bash
cd src/module1
pip install -r requirements.txt

cd ../module2
pip install -r requirements.txt

cd ../module3
pip install -r requirements.txt
```

### Option B: Lambda Layer (Recommended for Production)

Create a Lambda Layer with dependencies:

```bash
# Create layer directory
mkdir -p lambda-layer/python

# Install dependencies
pip install PyJWT cryptography urllib3 -t lambda-layer/python/

# Create ZIP
cd lambda-layer
zip -r ../cortex-dependencies.zip python/
cd ..

# Upload to Lambda Layer (via AWS Console or CLI)
aws lambda publish-layer-version \
  --layer-name cortex-dependencies \
  --zip-file fileb://cortex-dependencies.zip \
  --compatible-runtimes python3.11
```

Then update `lambda.tf` to attach the layer:

```hcl
resource "aws_lambda_function" "git_radar" {
  # ... existing config ...
  
  layers = [
    "arn:aws:lambda:us-east-1:YOUR-ACCOUNT:layer:cortex-dependencies:1"
  ]
}
```

### Option C: Package with Lambda (Simplest)

Terraform already zips the `src/moduleX/` directories. Ensure dependencies are installed:

```bash
# For each module
cd src/module1
pip install -r requirements.txt -t .
cd ../..

cd src/module2
pip install -r requirements.txt -t .
cd ../..

cd src/module3
pip install -r requirements.txt -t .
cd ../..
```

Then deploy:

```bash
terraform apply
```

---

## Part 5: Deploy & Test

### Step 1: Initialize Terraform

```bash
terraform init
```

### Step 2: Plan Deployment

```bash
terraform plan
```

Review changes. You should see updates to:
- All 3 Lambda functions (new environment variables)
- No infrastructure deletions/recreations

### Step 3: Deploy

```bash
terraform apply
```

Type `yes` to confirm.

### Step 4: Test Authentication

Send a test event to verify GitHub App authentication works:

```bash
# Test Module 2 (Git Radar)
aws lambda invoke \
  --function-name cloud-tibot_git_radar \
  --payload file://test-github-push-event.json \
  response.json

cat response.json
```

### Step 5: Check Logs

```bash
aws logs tail /aws/lambda/cloud-tibot_git_radar --follow
```

**Success indicators:**
- ✅ No "Personal Access Token not supported" errors
- ✅ Successful JWT generation messages
- ✅ API calls returning 200 status
- ✅ AI responses being generated

**Failure indicators:**
- ❌ "Failed to generate installation token"
- ❌ HTTP 401 Unauthorized
- ❌ HTTP 403 Forbidden (check Copilot permission!)

---

## Part 6: Troubleshooting

### Error: "Failed to get installation token (HTTP 401)"

**Cause**: Invalid App ID or Private Key

**Fix**:
1. Verify App ID matches your GitHub App settings
2. Ensure private key includes BEGIN/END lines
3. Check for extra spaces or newlines in terraform.tfvars
4. Regenerate private key if corrupted

### Error: "Permission Error: GitHub App does not have Copilot access"

**Cause**: Missing Copilot permission

**Fix**:
1. Go to your GitHub App settings
2. Navigate to "Permissions & events"
3. Under "Account permissions", find "Copilot"
4. Set to **"Read"**
5. Click "Save changes"
6. Reinstall the app (may be required)

### Error: "Invalid JWT signature"

**Cause**: Malformed private key or wrong algorithm

**Fix**:
1. Download a fresh private key from GitHub
2. Ensure no extra characters in the PEM file
3. Verify the key starts with `-----BEGIN RSA PRIVATE KEY-----`

### Error: "Module not found: jwt"

**Cause**: PyJWT not installed in Lambda environment

**Fix**:
- Follow Part 4 instructions to install dependencies
- Redeploy Lambda: `terraform apply`

### Testing Token Generation Locally

Create a test script `test_jwt.py`:

```python
import jwt
import time
import os

app_id = "123456"  # Your App ID
installation_id = "12345678"  # Your Installation ID

# Read private key
with open("path/to/your-app.pem", "r") as f:
    private_key = f.read()

# Generate JWT
now = int(time.time())
payload = {
    'iat': now,
    'exp': now + 600,
    'iss': app_id
}

jwt_token = jwt.encode(payload, private_key, algorithm='RS256')
print(f"JWT Token: {jwt_token}")

# Test token generation
import urllib3
http = urllib3.PoolManager()

url = f"https://api.github.com/app/installations/{installation_id}/access_tokens"
response = http.request(
    'POST',
    url,
    headers={
        'Authorization': f'Bearer {jwt_token}',
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28'
    }
)

print(f"Status: {response.status}")
print(f"Response: {response.data.decode('utf-8')}")
```

Run: `python test_jwt.py`

Expected: HTTP 201 with access token

---

## Summary Checklist

- [ ] Created GitHub App with Copilot: Read permission
- [ ] Copied App ID
- [ ] Generated and downloaded private key (.pem)
- [ ] Installed app to account/org
- [ ] Copied Installation ID from URL
- [ ] Updated terraform.tfvars with all 3 credentials
- [ ] Installed PyJWT and cryptography dependencies
- [ ] Validated Terraform configuration
- [ ] Deployed with `terraform apply`
- [ ] Tested Lambda functions
- [ ] Verified no authentication errors in logs
- [ ] Confirmed AI responses working

---

## Production Best Practices

### 1. Secure Private Key Storage

**DON'T**: Store private key in plain text in terraform.tfvars (committed to git)

**DO**: Use AWS Secrets Manager

```hcl
data "aws_secretsmanager_secret_version" "github_app" {
  secret_id = "cortex/github-app-key"
}

locals {
  github_app_private_key = jsondecode(data.aws_secretsmanager_secret_version.github_app.secret_string)["private_key"]
}
```

### 2. Rotate Keys Regularly

- Generate new private keys every 90 days
- Keep old keys active during rotation
- Update Lambda environment variables
- Delete old keys after verification

### 3. Use Separate Apps per Environment

- Dev: `CORTEX-Dev`
- Staging: `CORTEX-Staging`
- Production: `CORTEX-Production`

### 4. Monitor Token Usage

- Set up CloudWatch alerts for auth failures
- Track token generation rate
- Log all Copilot API calls

### 5. Least Privilege

- Only grant required repository access
- Use "Only select repositories" option
- Review permissions quarterly

---

## Support & Resources

- **GitHub Apps Documentation**: https://docs.github.com/en/apps
- **JWT Authentication**: https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app
- **Copilot API**: https://docs.github.com/en/copilot
- **PyJWT Documentation**: https://pyjwt.readthedocs.io/

## Questions?

Common issues and solutions are in Part 6 (Troubleshooting).

For additional help, check CloudWatch Logs:
```bash
aws logs tail /aws/lambda/cloud-tibot_git_radar --follow
```

---

**Last Updated**: February 2026  
**Compatible With**: Project CORTEX v2.0 (GitHub App Authentication)
