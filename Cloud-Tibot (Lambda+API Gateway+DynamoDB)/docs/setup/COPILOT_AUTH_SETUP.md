# GitHub Copilot API Authentication Setup Guide

## ✅ Current Implementation Status

**Project CORTEX now uses Solution 2: GitHub App Authentication (IMPLEMENTED)**

This is the production-ready authentication method that provides:
- ✅ No long-lived tokens (JWT expires every 10 minutes)
- ✅ Enterprise-grade security
- ✅ Granular permissions (Copilot: Read only)
- ✅ Better audit trail

**For complete setup instructions, see:** [GITHUB_APP_SETUP.md](GITHUB_APP_SETUP.md)

---

## ⚠️ IMPORTANT: Authentication Requirements

The GitHub Copilot API (`https://api.githubcopilot.com`) requires **special authentication** that is different from standard GitHub operations.

### What DOESN'T Work ❌
- **Personal Access Tokens (PAT)** - Standard GitHub PATs do NOT work with the Copilot API
- Classic tokens with `copilot` scope - Not supported for this endpoint

### What DOES Work ✅
1. ✅ **GitHub App installation token** with Copilot access **(CURRENTLY IMPLEMENTED)**
2. **GitHub OAuth token** with `copilot` scope (Alternative)
3. **OpenAI API** as a direct replacement (Testing alternative)

---

## Solution 2: GitHub App Authentication (✅ PRODUCTION - IMPLEMENTED)

**This is the current implementation used by Project CORTEX.**

All Lambda functions now use GitHub App JWT authentication for secure API access.

### What's Already Implemented

✅ JWT token generation using PyJWT  
✅ Installation token exchange with GitHub API  
✅ Fresh token per Lambda invocation  
✅ All 3 modules (Auto-Remediator, Git Radar, FinOps Sentinel) updated  
✅ Terraform variables configured for GitHub App credentials  
✅ Python dependencies (PyJWT, cryptography) added

### How It Works

1. **JWT Creation**: Lambda generates a JWT signed with your GitHub App's private key
2. **Token Exchange**: JWT is exchanged for an installation access token
3. **API Access**: Installation token is used to call GitHub Copilot API
4. **Token Refresh**: Fresh tokens generated per request (expires in 10 minutes)

### Architecture

```
┌─────────────────┐
│  Lambda Start   │
└────────┬────────┘
         │
         ▼
┌─────────────────────────┐
│  Read Environment Vars  │
│  - App ID              │
│  - Installation ID     │
│  - Private Key         │
└────────┬────────────────┘
         │
         ▼
┌─────────────────────────┐
│  Generate JWT Token     │
│  - Sign with RS256     │
│  - Expires in 10 min   │
└────────┬────────────────┘
         │
         ▼
┌─────────────────────────┐
│  Exchange for           │
│  Installation Token     │
│  POST /access_tokens    │
└────────┬────────────────┘
         │
         ▼
┌─────────────────────────┐
│  Call Copilot API       │
│  Bearer <token>         │
│  Process AI Response    │
└─────────────────────────┘
```

### Setup Instructions

**📖 See the complete guide:** [GITHUB_APP_SETUP.md](GITHUB_APP_SETUP.md)

**Quick checklist:**
1. Create GitHub App with Copilot: Read permission
2. Install app to your account/organization
3. Download private key (.pem file)
4. Update `terraform.tfvars` with:
   - `github_app_id`
   - `github_app_installation_id`
   - `github_app_private_key`
5. Deploy with `terraform apply`

### Code Implementation

The implementation is already complete in all modules. Here's what was added:

**copilot_agent.py** (all 3 modules):
```python
import jwt
import time
import json
import urllib3

def get_installation_token(app_id, installation_id, private_key):
    """Generate JWT and exchange for installation token"""
    now = int(time.time())
    payload = {
        'iat': now,
        'exp': now + 600,  # 10 minutes
        'iss': app_id
    }
    
    jwt_token = jwt.encode(payload, private_key, algorithm='RS256')
    
    http = urllib3.PoolManager()
    response = http.request(
        'POST',
        f'https://api.github.com/app/installations/{installation_id}/access_tokens',
        headers={
            'Authorization': f'Bearer {jwt_token}',
            'Accept': 'application/vnd.github+json',
            'X-GitHub-Api-Version': '2022-11-28'
        }
    )
    
    if response.status == 201:
        return json.loads(response.data.decode('utf-8'))['token']
    else:
        raise Exception(f"Failed to get installation token: {response.status}")
```

**lambda_function.py** (all 3 modules):
```python
# Read GitHub App credentials from environment
app_id = os.environ['GITHUB_APP_ID']
installation_id = os.environ['GITHUB_APP_INSTALLATION_ID']
private_key = os.environ['GITHUB_APP_PRIVATE_KEY']

# Generate installation token
github_token = get_installation_token(app_id, installation_id, private_key)

# Initialize Copilot agent with token
agent = CopilotAgent(github_token)
```

**Documentation**: https://docs.github.com/en/apps/creating-github-apps

---

## Solution 1: GitHub OAuth App (Alternative - Not Implemented)

### Step 1: Create OAuth Application
1. Go to https://github.com/settings/developers
2. Click "New OAuth App"
3. Fill in the details:
   - **Application name**: `CORTEX DevOps Agent` (or your preferred name)
   - **Homepage URL**: Your homepage or `http://localhost:3000`
   - **Authorization callback URL**: `http://localhost:3000/callback` (or your callback URL)
4. Click "Register application"
5. Note your **Client ID**
6. Generate a **Client Secret** and save it securely

### Step 2: Implement OAuth Flow
You'll need to implement an OAuth flow to get the user token. Here's a quick Python example:

```python
import requests
from urllib.parse import urlencode

# Step 1: Redirect user to GitHub authorization page
def get_authorization_url(client_id, redirect_uri):
    params = {
        'client_id': client_id,
        'redirect_uri': redirect_uri,
        'scope': 'copilot',  # Critical scope!
        'state': 'random_state_string'  # For CSRF protection
    }
    return f"https://github.com/login/oauth/authorize?{urlencode(params)}"

# Step 2: Exchange code for access token (after user authorizes)
def get_access_token(client_id, client_secret, code):
    response = requests.post(
        'https://github.com/login/oauth/access_token',
        data={
            'client_id': client_id,
            'client_secret': client_secret,
            'code': code
        },
        headers={'Accept': 'application/json'}
    )
    return response.json()['access_token']
```

### Step 3: Use the Token
```python
# This token can now be used with the Copilot API
copilot_token = get_access_token(client_id, client_secret, code)
```

**Documentation**: https://docs.github.com/en/apps/oauth-apps/building-oauth-apps

---

## Solution 3: Use OpenAI API Directly (Testing Alternative - Not Implemented)

**Note**: This is an alternative for testing without GitHub Copilot subscription. The production system uses GitHub App authentication (Solution 2 above).

If you want to test with OpenAI instead of GitHub Copilot:

### Step 1: Get OpenAI API Key
1. Sign up at https://platform.openai.com
2. Go to API keys section: https://platform.openai.com/api-keys
3. Click "Create new secret key"
4. Copy and save the key securely

### Step 2: Modify the Code
In each `copilot_agent.py` file, change:

```python
# Change this:
COPILOT_API_URL = "https://api.githubcopilot.com/chat/completions"

# To this:
COPILOT_API_URL = "https://api.openai.com/v1/chat/completions"
```

### Step 3: Update Lambda Environment Variables
```bash
# Remove the Authorization header modification or use OpenAI format
# In the chat() method, the Authorization header should be:
"Authorization": f"Bearer {self.github_pat}"  # This works for both!
```

### Step 4: Set Environment Variable
```bash
# Use OPENAI_API_KEY instead of GITHUB_PAT
export OPENAI_API_KEY="sk-..."
```

---

## Quick Setup for Testing (OpenAI - Recommended)

For immediate testing, use OpenAI API:

1. **Get API Key**: https://platform.openai.com/api-keys

2. **Update Terraform**:
```hcl
# In terraform.tfvars
github_pat = "sk-proj-..."  # Your OpenAI API key
```

3. **Modify each copilot_agent.py**:
```python
COPILOT_API_URL = "https://api.openai.com/v1/chat/completions"
COPILOT_MODEL = "gpt-4o"  # or "gpt-4-turbo", "gpt-3.5-turbo"
```

4. **Deploy**:
```bash
terraform apply
```

---

## Current Issue Summary

**Error Observed**: 
```
Copilot API error (400): bad request: Personal Access Tokens are not supported for this endpoint
```

**Root Cause**: 
The code currently uses a GitHub Personal Access Token (PAT), but the GitHub Copilot API endpoint (`api.githubcopilot.com`) requires:
- OAuth tokens with `copilot` scope, OR
- GitHub App installation tokens

**Quick Fix Options**:
1. ✅ **Easiest**: Switch to OpenAI API (see Solution 3 above)
2. ⚙️ **Full GitHub Integration**: Implement OAuth flow (Solution 1)
3. 🏢 **Enterprise**: Use GitHub App (Solution 2)

---

## Environment Variables Update

After choosing your authentication method, update:

### For OpenAI API:
```bash
# Lambda environment variable
GITHUB_PAT -> Rename to OPENAI_API_KEY or keep as GITHUB_PAT but use OpenAI key
```

### For GitHub OAuth/App:
```bash
# Lambda environment variable  
GITHUB_PAT -> Keep name but use OAuth token or App installation token
```

---

## Testing Authentication

Test your token with this curl command:

```bash
# Test GitHub Copilot API
curl -X POST https://api.githubcopilot.com/chat/completions \
  -H "Authorization: Bearer YOUR_TOKEN" \
  -H "Content-Type: application/json" \
  -H "Copilot-Integration-Id: test" \
  -d '{
    "model": "gpt-4o",
    "messages": [{"role": "user", "content": "Hello!"}]
  }'

# Test OpenAI API
curl -X POST https://api.openai.com/v1/chat/completions \
  -H "Authorization: Bearer YOUR_OPENAI_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gpt-4o",
    "messages": [{"role": "user", "content": "Hello!"}]
  }'
```

Success = HTTP 200 with response containing "choices"
Failure = HTTP 400/401 with error message

---

## Need Help?

- **GitHub OAuth**: https://docs.github.com/en/apps/oauth-apps
- **GitHub Apps**: https://docs.github.com/en/apps/creating-github-apps  
- **OpenAI API**: https://platform.openai.com/docs
- **Copilot API**: https://docs.github.com/en/copilot

## Support

If you encounter issues:
1. Check CloudWatch logs: `aws logs tail /aws/lambda/cloud-tibot_git_radar --follow`
2. Look for authentication error messages
3. Verify your token is valid and has correct permissions
4. Ensure you have an active Copilot subscription (for GitHub Copilot API)
