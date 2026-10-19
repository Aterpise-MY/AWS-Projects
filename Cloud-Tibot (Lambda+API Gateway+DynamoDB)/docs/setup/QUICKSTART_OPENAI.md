# Quick Start: Using OpenAI API (Easiest Solution)

If you want to get CORTEX working immediately without dealing with GitHub OAuth complexity, use OpenAI API instead.

## 5-Minute Setup

### Step 1: Get OpenAI API Key (2 minutes)
1. Visit https://platform.openai.com/api-keys
2. Sign up or log in
3. Click "Create new secret key"
4. Copy the key (starts with `sk-proj-...` or `sk-...`)
5. **Save it securely** - you won't see it again!

### Step 2: Update Code (2 minutes)

Edit these three files and change ONE line in each:

**File 1**: `src/module1/copilot_agent.py` (around line 13)
```python
# Change this line:
COPILOT_API_URL = "https://api.githubcopilot.com/chat/completions"

# To this:
COPILOT_API_URL = "https://api.openai.com/v1/chat/completions"
```

**File 2**: `src/module2/copilot_agent.py` (around line 13)
```python
# Change this line:
COPILOT_API_URL = "https://api.githubcopilot.com/chat/completions"

# To this:
COPILOT_API_URL = "https://api.openai.com/v1/chat/completions"
```

**File 3**: `src/module3/copilot_agent.py` (around line 13)
```python
# Change this line:
COPILOT_API_URL = "https://api.githubcopilot.com/chat/completions"

# To this:
COPILOT_API_URL = "https://api.openai.com/v1/chat/completions"
```

### Step 3: Configure Terraform (1 minute)

Edit `terraform.tfvars`:
```hcl
# Replace with your OpenAI API key
github_pat = "sk-proj-YOUR_OPENAI_KEY_HERE"
```

### Step 4: Deploy

```bash
terraform init
terraform plan
terraform apply
```

## Done! 🎉

Your CORTEX system is now using OpenAI's GPT-4 for AI-powered operations.

## Cost Estimate

OpenAI API pricing (as of 2026):
- GPT-4o: ~$2-5/million tokens
- GPT-4-turbo: ~$1-3/million tokens  
- GPT-3.5-turbo: ~$0.50/million tokens

For typical CORTEX usage (10-100 AI operations/day):
- **Expected monthly cost**: $5-20

## Alternative Models

You can also use cheaper models by changing `COPILOT_MODEL` in the files:

```python
COPILOT_MODEL = "gpt-4o"           # Best quality, highest cost
COPILOT_MODEL = "gpt-4-turbo"      # Good balance
COPILOT_MODEL = "gpt-3.5-turbo"    # Fastest, cheapest
```

## Testing Your Setup

After deployment, test with a simple push event:

```bash
# Send test event to Lambda
aws lambda invoke \
  --function-name cloud-tibot_git_radar \
  --payload file://test-github-push-event.json \
  response.json

cat response.json
```

Check CloudWatch logs:
```bash
aws logs tail /aws/lambda/cloud-tibot_git_radar --follow
```

You should see successful API calls, NOT authentication errors!

## Troubleshooting

### Error: "Invalid API key"
- Go back to OpenAI platform and generate a new key
- Make sure you copied the entire key
- Check for extra spaces in terraform.tfvars

### Error: "Model not found"
- Check your OpenAI account has access to the model
- Try using "gpt-3.5-turbo" instead
- Ensure you have credits in your OpenAI account

### Still getting "Personal Access Tokens are not supported"?
- You forgot to update the `COPILOT_API_URL` in one of the files
- Re-run `terraform apply` to deploy the updated code

## Need More Help?

See the full authentication guide: [COPILOT_AUTH_SETUP.md](COPILOT_AUTH_SETUP.md)
