#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Diagnose why Amplify build notifications aren't reaching Telegram
    
.DESCRIPTION
    This script checks all components of the Amplify notification pipeline:
    - EventBridge rule status
    - Lambda function configuration
    - Environment variables
    - IAM permissions
    - CloudWatch logs
    - Telegram bot connectivity
    
.PARAMETER ProjectName
    The project name used in resource naming (default: CORTEX)
    
.PARAMETER Region
    AWS region (default: us-east-1)
    
.EXAMPLE
    .\diagnose-amplify-notifications.ps1 -ProjectName CORTEX -Region us-east-1
#>

param(
    [string]$ProjectName = "CORTEX",
    [string]$Region = "us-east-1"
)

$ErrorActionPreference = "Continue"
$FunctionName = "${ProjectName}_auto_remediator"
$RuleName = "${ProjectName}_amplify_build_status"

Write-Host "🔍 Diagnosing Amplify Notification Pipeline..." -ForegroundColor Cyan
Write-Host "================================================" -ForegroundColor Cyan
Write-Host ""

# 1. Check EventBridge Rule
Write-Host "1️⃣  Checking EventBridge Rule..." -ForegroundColor Yellow
try {
    $rule = aws events describe-rule --name $RuleName --region $Region | ConvertFrom-Json
    if ($rule.State -eq "ENABLED") {
        Write-Host "   ✅ EventBridge rule is ENABLED" -ForegroundColor Green
        Write-Host "      Rule: $($rule.Name)" -ForegroundColor Gray
        Write-Host "      ARN: $($rule.Arn)" -ForegroundColor Gray
    } else {
        Write-Host "   ❌ EventBridge rule is DISABLED!" -ForegroundColor Red
        Write-Host "      Fix: Enable the rule with: aws events enable-rule --name $RuleName" -ForegroundColor Yellow
    }
} catch {
    Write-Host "   ❌ EventBridge rule not found!" -ForegroundColor Red
    Write-Host "      Error: $_" -ForegroundColor Red
}
Write-Host ""

# 2. Check EventBridge Targets
Write-Host "2️⃣  Checking EventBridge Targets..." -ForegroundColor Yellow
try {
    $targets = aws events list-targets-by-rule --rule $RuleName --region $Region | ConvertFrom-Json
    if ($targets.Targets.Count -gt 0) {
        Write-Host "   ✅ Found $($targets.Targets.Count) target(s)" -ForegroundColor Green
        foreach ($target in $targets.Targets) {
            Write-Host "      Target ID: $($target.Id)" -ForegroundColor Gray
            Write-Host "      ARN: $($target.Arn)" -ForegroundColor Gray
        }
    } else {
        Write-Host "   ❌ No targets configured!" -ForegroundColor Red
    }
} catch {
    Write-Host "   ❌ Failed to list targets!" -ForegroundColor Red
    Write-Host "      Error: $_" -ForegroundColor Red
}
Write-Host ""

# 3. Check Lambda Function
Write-Host "3️⃣  Checking Lambda Function..." -ForegroundColor Yellow
try {
    $lambda = aws lambda get-function --function-name $FunctionName --region $Region | ConvertFrom-Json
    Write-Host "   ✅ Lambda function exists" -ForegroundColor Green
    Write-Host "      Function: $($lambda.Configuration.FunctionName)" -ForegroundColor Gray
    Write-Host "      Runtime: $($lambda.Configuration.Runtime)" -ForegroundColor Gray
    Write-Host "      Last Modified: $($lambda.Configuration.LastModified)" -ForegroundColor Gray
    Write-Host "      State: $($lambda.Configuration.State)" -ForegroundColor Gray
} catch {
    Write-Host "   ❌ Lambda function not found!" -ForegroundColor Red
    Write-Host "      Error: $_" -ForegroundColor Red
}
Write-Host ""

# 4. Check Environment Variables
Write-Host "4️⃣  Checking Lambda Environment Variables..." -ForegroundColor Yellow
try {
    $config = aws lambda get-function-configuration --function-name $FunctionName --region $Region | ConvertFrom-Json
    $env = $config.Environment.Variables
    
    $required = @("TELEGRAM_TOKEN", "TELEGRAM_CHAT_ID", "PROJECT_NAME")
    foreach ($var in $required) {
        if ($env.$var) {
            $maskedValue = if ($var -eq "TELEGRAM_TOKEN") {
                $token = $env.$var
                "***" + $token.Substring([Math]::Max(0, $token.Length - 4))
            } else {
                $env.$var
            }
            Write-Host "   ✅ $var = $maskedValue" -ForegroundColor Green
        } else {
            Write-Host "   ❌ $var is NOT SET!" -ForegroundColor Red
        }
    }
} catch {
    Write-Host "   ❌ Failed to get environment variables!" -ForegroundColor Red
    Write-Host "      Error: $_" -ForegroundColor Red
}
Write-Host ""

# 5. Check Lambda Permissions
Write-Host "5️⃣  Checking Lambda Permissions..." -ForegroundColor Yellow
try {
    $policy = aws lambda get-policy --function-name $FunctionName --region $Region | ConvertFrom-Json
    $policyDoc = $policy.Policy | ConvertFrom-Json
    
    $hasEventBridgePermission = $false
    foreach ($statement in $policyDoc.Statement) {
        if ($statement.Principal.Service -eq "events.amazonaws.com") {
            $hasEventBridgePermission = $true
            Write-Host "   ✅ EventBridge has permission to invoke Lambda" -ForegroundColor Green
            Write-Host "      Statement ID: $($statement.Sid)" -ForegroundColor Gray
        }
    }
    
    if (-not $hasEventBridgePermission) {
        Write-Host "   ❌ EventBridge does NOT have permission to invoke Lambda!" -ForegroundColor Red
        Write-Host "      Fix: Run terraform apply to add permission" -ForegroundColor Yellow
    }
} catch {
    Write-Host "   ⚠️  Could not retrieve Lambda policy" -ForegroundColor Yellow
    Write-Host "      Error: $_" -ForegroundColor Gray
}
Write-Host ""

# 6. Check Recent CloudWatch Logs
Write-Host "6️⃣  Checking Recent CloudWatch Logs..." -ForegroundColor Yellow
try {
    $logGroup = "/aws/lambda/$FunctionName"
    $since = [DateTimeOffset]::UtcNow.AddHours(-1).ToUnixTimeMilliseconds()
    
    Write-Host "   📋 Recent logs (last 1 hour):" -ForegroundColor Cyan
    $logs = aws logs tail $logGroup --since 1h --region $Region 2>&1
    
    if ($LASTEXITCODE -eq 0) {
        if ($logs) {
            $logs | Select-Object -First 20 | ForEach-Object {
                Write-Host "      $_" -ForegroundColor Gray
            }
            Write-Host ""
            Write-Host "   💡 Check full logs with: aws logs tail $logGroup --follow" -ForegroundColor Cyan
        } else {
            Write-Host "   ⚠️  No logs in the last hour" -ForegroundColor Yellow
            Write-Host "      This might mean the function hasn't been invoked" -ForegroundColor Gray
        }
    } else {
        Write-Host "   ❌ Log group not found or no access" -ForegroundColor Red
    }
} catch {
    Write-Host "   ⚠️  Could not retrieve logs" -ForegroundColor Yellow
    Write-Host "      Error: $_" -ForegroundColor Gray
}
Write-Host ""

# 7. Test Telegram Bot
Write-Host "7️⃣  Testing Telegram Bot Connectivity..." -ForegroundColor Yellow
try {
    $config = aws lambda get-function-configuration --function-name $FunctionName --region $Region | ConvertFrom-Json
    $token = $config.Environment.Variables.TELEGRAM_TOKEN
    
    if ($token) {
        $response = Invoke-RestMethod -Uri "https://api.telegram.org/bot$token/getMe" -Method Get -ErrorAction Stop
        
        if ($response.ok) {
            Write-Host "   ✅ Telegram bot is active and reachable" -ForegroundColor Green
            Write-Host "      Bot Username: @$($response.result.username)" -ForegroundColor Gray
            Write-Host "      Bot ID: $($response.result.id)" -ForegroundColor Gray
            Write-Host "      Bot Name: $($response.result.first_name)" -ForegroundColor Gray
        } else {
            Write-Host "   ❌ Telegram bot token is invalid!" -ForegroundColor Red
        }
    } else {
        Write-Host "   ❌ TELEGRAM_TOKEN not found in environment variables" -ForegroundColor Red
    }
} catch {
    Write-Host "   ❌ Failed to connect to Telegram API!" -ForegroundColor Red
    Write-Host "      Error: $($_.Exception.Message)" -ForegroundColor Red
}
Write-Host ""

# 8. Check IAM Role Permissions
Write-Host "8️⃣  Checking Lambda IAM Role..." -ForegroundColor Yellow
try {
    $lambda = aws lambda get-function --function-name $FunctionName --region $Region | ConvertFrom-Json
    $roleArn = $lambda.Configuration.Role
    $roleName = $roleArn.Split('/')[-1]
    
    Write-Host "   📋 Role: $roleName" -ForegroundColor Cyan
    
    # List attached policies
    $policies = aws iam list-attached-role-policies --role-name $roleName | ConvertFrom-Json
    Write-Host "   📝 Attached Policies:" -ForegroundColor Cyan
    foreach ($policy in $policies.AttachedPolicies) {
        Write-Host "      - $($policy.PolicyName)" -ForegroundColor Gray
    }
    
    # Check inline policies
    $inlinePolicies = aws iam list-role-policies --role-name $roleName | ConvertFrom-Json
    if ($inlinePolicies.PolicyNames.Count -gt 0) {
        Write-Host "   📝 Inline Policies:" -ForegroundColor Cyan
        foreach ($policyName in $inlinePolicies.PolicyNames) {
            Write-Host "      - $policyName" -ForegroundColor Gray
        }
    }
} catch {
    Write-Host "   ⚠️  Could not retrieve IAM role details" -ForegroundColor Yellow
    Write-Host "      Error: $_" -ForegroundColor Gray
}
Write-Host ""

# 9. Suggest Next Steps
Write-Host "🔧 Recommended Next Steps:" -ForegroundColor Cyan
Write-Host "================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "1. If NO logs appeared in step 6:" -ForegroundColor Yellow
Write-Host "   → The Lambda function is not being invoked by EventBridge" -ForegroundColor White
Write-Host "   → Check EventBridge rule is ENABLED" -ForegroundColor White
Write-Host "   → Verify EventBridge has permission to invoke Lambda" -ForegroundColor White
Write-Host "   → Test with: aws events put-events --entries file://test-payloads/test-amplify-success.json" -ForegroundColor Cyan
Write-Host ""

Write-Host "2. If logs show 'Received event' but no Telegram message:" -ForegroundColor Yellow
Write-Host "   → Check for errors in CloudWatch logs" -ForegroundColor White
Write-Host "   → Verify TELEGRAM_TOKEN and TELEGRAM_CHAT_ID are correct" -ForegroundColor White
Write-Host "   → Test Telegram bot manually with curl/Invoke-RestMethod" -ForegroundColor White
Write-Host ""

Write-Host "3. To manually test the function:" -ForegroundColor Yellow
Write-Host "   → Create test event: test-payloads/test-amplify-success.json" -ForegroundColor Cyan
Write-Host "   → Invoke: aws lambda invoke --function-name $FunctionName --payload file://test-payloads/test-amplify-success.json response.json" -ForegroundColor Cyan
Write-Host ""

Write-Host "4. To watch logs in real-time:" -ForegroundColor Yellow
Write-Host "   → aws logs tail /aws/lambda/$FunctionName --follow --region $Region" -ForegroundColor Cyan
Write-Host ""

Write-Host "5. To trigger a real Amplify build:" -ForegroundColor Yellow
Write-Host "   → Go to Amplify Console → Select App → Redeploy this version" -ForegroundColor White
Write-Host "   → Or push a commit to trigger automatic build" -ForegroundColor White
Write-Host ""

Write-Host "✅ Diagnosis Complete!" -ForegroundColor Green
Write-Host ""
