# Quick Action Plan - Complete Telegram Bot Deployment

## 🎯 Current Status
✅ **ALL 6 MODULE TESTS PASSED!**  
✅ Infrastructure deployed  
✅ Test suite created  
⚠️ API Gateway needs dependency fix (Lambda packages missing PyJWT)

---

## 🚀 Complete These 3 Simple Steps

### Step 1: Build All Lambda Packages (2 minutes)
The build script is ready. Just run it sequentially for each module:

```powershell
# Clean build all modules
.\Build-LambdaPackages.ps1 -CleanBuild

# If that fails, build one at a time:
.\Build-LambdaPackages.ps1 -Module1Only -CleanBuild
.\Build-LambdaPackages.ps1 -Module2Only -CleanBuild
.\Build-LambdaPackages.ps1 -Module3Only -CleanBuild
```

**Expected Output:**
- ✓ Module1.zip (~18 MB)
- ✓ Module2.zip (~18 MB)
- ✓ Module3.zip (~18 MB)

---

### Step 2: Deploy Updated Lambda Functions (1 minute)
Once packages are built, update the Lambda functions:

```powershell
# Update all three Lambda functions with dependencies
aws lambda update-function-code `
    --function-name cloud-tibot_auto_remediator `
    --zip-file fileb://src/module1/build/module1.zip

aws lambda update-function-code `
    --function-name cloud-tibot_git_radar `
    --zip-file fileb://src/module2/build/module2.zip

aws lambda update-function-code `
    --function-name cloud-tibot_finops_sentinel `
    --zip-file fileb://src/module3/build/module3.zip
```

**Wait 30 seconds** for Lambda to update, then proceed to Step 3.

---

### Step 3: Re-run Tests to Verify (1 minute)
```powershell
.\Test-AllPipelines.ps1
```

**Expected Result:** 🎉 All tests pass including API Gateway integration!

---

## ✅ After Tests Pass

### Configure GitHub Webhook
1. Go to your GitHub repository settings
2. Navigate to **Webhooks** → **Add webhook**
3. **Payload URL:** `https://evn3cc72mb.execute-api.us-east-1.amazonaws.com/webhook/github`
4. **Content type:** `application/json`
5. **Events:** Select:
   - Push events
   - Pull requests
   - Workflow runs
6. Click **Add webhook**

### Test Real Webhook
Push a commit to your repo or create a Pull Request - you should receive a Telegram notification!

---

## 🐛 If Build Script Fails

### Alternative: Manual Packaging

For each module (replace `N` with 1, 2, or 3):

```powershell
# Navigate to module directory
cd src\moduleN

# Create build directory
mkdir -p build\package

# Install dependencies
pip install -r requirements.txt -t build\package --upgrade

# Copy Python files
Copy-Item *.py build\package\

# Create ZIP (using PowerShell or 7-Zip)
Compress-Archive -Path build\package\* -DestinationPath build\moduleN.zip -Force

cd ..\..
```

Then deploy as shown in Step 2.

---

## 📊 Verify Everything Works

### Check Logs
```powershell
# Watch logs in real-time
aws logs tail /aws/lambda/cloud-tibot_git_radar --follow
```

### Verify No Import Errors
After deploying, invoke a test:
```powershell
aws lambda invoke `
    --function-name cloud-tibot_git_radar `
    --payload file://test-payloads/test-github-push.json `
    response.json

# Check response
Get-Content response.json | ConvertFrom-Json
```

Should show **no "jwt" import errors**!

---

## 🎉 Success Criteria

You'll know everything is working when:
- ✅ `.\Test-AllPipelines.ps1` shows 6/6 tests passed
- ✅ API Gateway test passes (no 500 error)
- ✅ CloudWatch logs show no import errors
- ✅ GitHub webhook delivers successfully
- ✅ Telegram receives notifications

---

## ⏱️ Time Estimate

- **Total Time:** 5-10 minutes
  - Build packages: 2-3 minutes
  - Deploy to Lambda: 1 minute
  - Run tests: 1 minute
  - Configure webhook: 2-5 minutes

---

## 🆘 Need Help?

See `TESTING_GUIDE.md` for detailed troubleshooting or run:
```powershell
.\Test-AllPipelines.ps1 -Verbose
```

---

**You're almost there! Just build and deploy the Lambda packages with dependencies and you're done! 🚀**
