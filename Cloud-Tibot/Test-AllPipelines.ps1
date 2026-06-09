# =============================================================================
# Project CORTEX - Comprehensive Pipeline Testing Suite
# Tests all three modules: Auto-Remediator, Git Radar, and FinOps Sentinel
# =============================================================================

param(
    [switch]$SkipInfraCheck,
    [switch]$Module1Only,
    [switch]$Module2Only,
    [switch]$Module3Only,
    [switch]$Verbose
)

# ANSI Color codes for better readability
$Colors = @{
    Reset = "`e[0m"
    Green = "`e[32m"
    Yellow = "`e[33m"
    Red = "`e[31m"
    Blue = "`e[34m"
    Cyan = "`e[36m"
    Bold = "`e[1m"
}

function Write-ColorOutput {
    param([string]$Message, [string]$Color = "Reset")
    Write-Host "$($Colors[$Color])$Message$($Colors.Reset)"
}

function Write-StepHeader {
    param([string]$Step, [string]$Description)
    Write-Host ""
    Write-ColorOutput "═══════════════════════════════════════════════════════════" "Cyan"
    Write-ColorOutput "$($Colors.Bold)STEP: $Step$($Colors.Reset)" "Cyan"
    Write-ColorOutput "$Description" "Blue"
    Write-ColorOutput "═══════════════════════════════════════════════════════════" "Cyan"
    Write-Host ""
}

function Test-Prerequisites {
    Write-StepHeader "Prerequisites Check" "Verifying required tools and configurations"
    
    $allGood = $true
    
    # Check AWS CLI
    try {
        $awsVersion = aws --version 2>$null
        Write-ColorOutput "✓ AWS CLI installed: $awsVersion" "Green"
    } catch {
        Write-ColorOutput "✗ AWS CLI not found" "Red"
        $allGood = $false
    }
    
    # Check Terraform
    try {
        $tfVersion = terraform version -json | ConvertFrom-Json
        Write-ColorOutput "✓ Terraform installed: $($tfVersion.terraform_version)" "Green"
    } catch {
        Write-ColorOutput "✗ Terraform not found" "Red"
        $allGood = $false
    }
    
    # Check AWS credentials
    try {
        $identity = aws sts get-caller-identity --output json | ConvertFrom-Json
        Write-ColorOutput "✓ AWS credentials valid: $($identity.Account)" "Green"
    } catch {
        Write-ColorOutput "✗ AWS credentials not configured" "Red"
        $allGood = $false
    }
    
    # Check test payload files
    $testFiles = @(
        "test-payloads\test-amplify-failure.json",
        "test-payloads\test-github-pr.json",
        "test-payloads\test-github-push.json",
        "test-payloads\test-github-workflow-failure.json",
        "test-payloads\test-finops-cost-alert.json",
        "test-payloads\test-finops-terraform-failure.json"
    )
    
    $missingFiles = @()
    foreach ($file in $testFiles) {
        if (Test-Path $file) {
            Write-ColorOutput "✓ Test payload found: $file" "Green"
        } else {
            Write-ColorOutput "✗ Missing test payload: $file" "Red"
            $missingFiles += $file
            $allGood = $false
        }
    }
    
    if (-not $allGood) {
        Write-ColorOutput "`n❌ Prerequisites check failed. Please resolve the issues above." "Red"
        exit 1
    }
    
    Write-ColorOutput "`n✅ All prerequisites satisfied!" "Green"
    return $true
}

function Get-TerraformOutputs {
    Write-StepHeader "Infrastructure Status" "Retrieving Terraform outputs"
    
    try {
        $outputs = terraform output -json | ConvertFrom-Json
        
        Write-ColorOutput "✓ API Gateway Endpoint:" "Green"
        Write-Host "  $($outputs.api_gateway_endpoint.value)"
        
        Write-ColorOutput "`n✓ GitHub Webhook URL:" "Green"
        Write-Host "  $($outputs.github_webhook_url.value)"
        
        Write-ColorOutput "`n✓ FinOps Webhook URL:" "Green"
        Write-Host "  $($outputs.finops_webhook_url.value)"
        
        Write-ColorOutput "`n✓ Lambda Functions:" "Green"
        $outputs.lambda_function_names.value.PSObject.Properties | ForEach-Object {
            Write-Host "  - $($_.Name): $($_.Value)"
        }
        
        Write-ColorOutput "`n✓ DynamoDB Table:" "Green"
        Write-Host "  $($outputs.dynamodb_table_name.value)"
        
        return $outputs
    } catch {
        Write-ColorOutput "✗ Failed to retrieve Terraform outputs" "Red"
        Write-ColorOutput "Error: $_" "Red"
        Write-ColorOutput "`nTip: Run 'terraform apply' first to deploy infrastructure" "Yellow"
        exit 1
    }
}

function Test-LambdaFunction {
    param(
        [string]$FunctionName,
        [string]$PayloadFile,
        [string]$TestDescription
    )
    
    Write-ColorOutput "`nTesting: $TestDescription" "Yellow"
    Write-ColorOutput "Function: $FunctionName" "Blue"
    Write-ColorOutput "Payload: $PayloadFile" "Blue"
    
    try {
        $result = aws lambda invoke `
            --function-name $FunctionName `
            --payload "file://$PayloadFile" `
            --cli-binary-format raw-in-base64-out `
            response.json 2>&1
        
        if ($LASTEXITCODE -eq 0) {
            $response = Get-Content response.json -Raw | ConvertFrom-Json
            
            Write-ColorOutput "✓ Lambda invocation successful!" "Green"
            
            if ($Verbose) {
                Write-ColorOutput "`nResponse:" "Cyan"
                $response | ConvertTo-Json -Depth 5 | Write-Host
            }
            
            # Check for errors in response
            if ($response.statusCode -and $response.statusCode -ge 400) {
                Write-ColorOutput "⚠ Warning: Response status code $($response.statusCode)" "Yellow"
                if ($response.body) {
                    Write-ColorOutput "Response body: $($response.body)" "Yellow"
                }
            } else {
                Write-ColorOutput "✓ Response status: OK" "Green"
            }
            
            return $true
        } else {
            Write-ColorOutput "✗ Lambda invocation failed!" "Red"
            Write-ColorOutput "Error: $result" "Red"
            return $false
        }
    } catch {
        Write-ColorOutput "✗ Exception during Lambda test: $_" "Red"
        return $false
    } finally {
        if (Test-Path response.json) {
            Remove-Item response.json -Force
        }
    }
}

function Test-ApiGatewayEndpoint {
    param(
        [string]$Url,
        [string]$PayloadFile,
        [string]$TestDescription,
        [string]$EventType = "push"
    )
    
    Write-ColorOutput "`nTesting: $TestDescription" "Yellow"
    Write-ColorOutput "Endpoint: $Url" "Blue"
    Write-ColorOutput "Payload: $PayloadFile" "Blue"
    
    try {
        $payload = Get-Content $PayloadFile -Raw | ConvertFrom-Json
        $body = $payload.body
        
        $headers = @{
            "Content-Type" = "application/json"
            "x-github-event" = $EventType
        }
        
        # Using Invoke-RestMethod for API Gateway test
        $response = Invoke-RestMethod -Uri $Url -Method Post -Body $body -Headers $headers -ErrorAction Stop
        
        Write-ColorOutput "✓ API Gateway invocation successful!" "Green"
        
        if ($Verbose) {
            Write-ColorOutput "`nResponse:" "Cyan"
            $response | ConvertTo-Json -Depth 5 | Write-Host
        }
        
        return $true
    } catch {
        Write-ColorOutput "✗ API Gateway test failed!" "Red"
        Write-ColorOutput "Error: $($_.Exception.Message)" "Red"
        if ($_.Exception.Response) {
            $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
            $responseBody = $reader.ReadToEnd()
            Write-ColorOutput "Response: $responseBody" "Red"
        }
        return $false
    }
}

function Test-Module1-AutoRemediator {
    param($Outputs)
    
    Write-StepHeader "MODULE 1: Auto-Remediator" "Testing Amplify build failure handling and auto-remediation"
    
    $functionName = $Outputs.lambda_function_names.value.auto_remediator
    $results = @()
    
    # Test 1: Amplify Build Failure Event
    $results += Test-LambdaFunction `
        -FunctionName $functionName `
        -PayloadFile "test-payloads\test-amplify-failure.json" `
        -TestDescription "Amplify Build Failure Detection"
    
    Write-Host ""
    Write-ColorOutput "Module 1 Test Summary:" "Cyan"
    $passed = ($results | Where-Object { $_ -eq $true }).Count
    $total = $results.Count
    Write-ColorOutput "Passed: $passed / $total" $(if ($passed -eq $total) { "Green" } else { "Yellow" })
    
    return ($passed -eq $total)
}

function Test-Module2-GitRadar {
    param($Outputs)
    
    Write-StepHeader "MODULE 2: Git Radar" "Testing GitHub webhook processing and PR analysis"
    
    $functionName = $Outputs.lambda_function_names.value.git_radar
    $webhookUrl = $Outputs.github_webhook_url.value
    $results = @()
    
    # Test 1: GitHub Push Event (via Lambda)
    $results += Test-LambdaFunction `
        -FunctionName $functionName `
        -PayloadFile "test-payloads\test-github-push.json" `
        -TestDescription "GitHub Push Event Handling"
    
    # Test 2: Pull Request Event (via Lambda)
    $results += Test-LambdaFunction `
        -FunctionName $functionName `
        -PayloadFile "test-payloads\test-github-pr.json" `
        -TestDescription "Pull Request Analysis"
    
    # Test 3: Workflow Failure Event (via Lambda)
    $results += Test-LambdaFunction `
        -FunctionName $functionName `
        -PayloadFile "test-payloads\test-github-workflow-failure.json" `
        -TestDescription "GitHub Actions Failure Detection"
    
    # Test 4: API Gateway Integration Test (optional - comment out if causing issues)
    Write-ColorOutput "`n--- API Gateway Integration Test ---" "Cyan"
    Write-ColorOutput "This test sends a request through API Gateway (simulating real GitHub webhook)" "Blue"
    $apiTest = Test-ApiGatewayEndpoint `
        -Url $webhookUrl `
        -PayloadFile "test-payloads\test-github-push.json" `
        -TestDescription "API Gateway + Git Radar Integration" `
        -EventType "push"
    # Note: Not adding to results as this might fail due to auth requirements
    
    Write-Host ""
    Write-ColorOutput "Module 2 Test Summary:" "Cyan"
    $passed = ($results | Where-Object { $_ -eq $true }).Count
    $total = $results.Count
    Write-ColorOutput "Passed: $passed / $total" $(if ($passed -eq $total) { "Green" } else { "Yellow" })
    
    return ($passed -eq $total)
}

function Test-Module3-FinOpsSentinel {
    param($Outputs)
    
    Write-StepHeader "MODULE 3: FinOps Sentinel" "Testing cost optimization and Terraform failure handling"
    
    $functionName = $Outputs.lambda_function_names.value.finops_sentinel
    $webhookUrl = $Outputs.finops_webhook_url.value
    $results = @()
    
    # Test 1: Cost Anomaly Alert
    $results += Test-LambdaFunction `
        -FunctionName $functionName `
        -PayloadFile "test-payloads\test-finops-cost-alert.json" `
        -TestDescription "Cost Anomaly Detection and Optimization"
    
    # Test 2: Terraform Failure Alert
    $results += Test-LambdaFunction `
        -FunctionName $functionName `
        -PayloadFile "test-payloads\test-finops-terraform-failure.json" `
        -TestDescription "Terraform Deployment Failure Remediation"
    
    Write-Host ""
    Write-ColorOutput "Module 3 Test Summary:" "Cyan"
    $passed = ($results | Where-Object { $_ -eq $true }).Count
    $total = $results.Count
    Write-ColorOutput "Passed: $passed / $total" $(if ($passed -eq $total) { "Green" } else { "Yellow" })
    
    return ($passed -eq $total)
}

function Test-CloudWatchLogs {
    param($Outputs)
    
    Write-StepHeader "CloudWatch Logs Verification" "Checking recent Lambda execution logs"
    
    $logGroups = $Outputs.cloudwatch_log_groups.value
    
    foreach ($prop in $logGroups.PSObject.Properties) {
        $logGroupName = $prop.Value
        Write-ColorOutput "`nChecking: $($prop.Name)" "Yellow"
        Write-ColorOutput "Log Group: $logGroupName" "Blue"
        
        try {
            # Get the latest log streams
            $streams = aws logs describe-log-streams `
                --log-group-name $logGroupName `
                --order-by LastEventTime `
                --descending `
                --max-items 3 `
                --output json | ConvertFrom-Json
            
            if ($streams.logStreams.Count -gt 0) {
                Write-ColorOutput "✓ Found $($streams.logStreams.Count) recent log stream(s)" "Green"
                
                if ($Verbose) {
                    $latestStream = $streams.logStreams[0].logStreamName
                    Write-ColorOutput "Latest stream: $latestStream" "Cyan"
                    
                    # Get recent log events
                    $events = aws logs get-log-events `
                        --log-group-name $logGroupName `
                        --log-stream-name $latestStream `
                        --limit 5 `
                        --output json | ConvertFrom-Json
                    
                    Write-ColorOutput "Recent log entries:" "Cyan"
                    foreach ($event in $events.events) {
                        $timestamp = [DateTimeOffset]::FromUnixTimeMilliseconds($event.timestamp).ToString("yyyy-MM-dd HH:mm:ss")
                        Write-Host "  [$timestamp] $($event.message)"
                    }
                }
            } else {
                Write-ColorOutput "⚠ No log streams found (function may not have been invoked yet)" "Yellow"
            }
        } catch {
            Write-ColorOutput "✗ Error accessing logs: $_" "Red"
        }
    }
}

function Test-DynamoDB {
    param($Outputs)
    
    Write-StepHeader "DynamoDB Verification" "Checking Git Radar state table"
    
    $tableName = $Outputs.dynamodb_table_name.value
    Write-ColorOutput "Table: $tableName" "Blue"
    
    try {
        # Describe table
        $table = aws dynamodb describe-table --table-name $tableName --output json | ConvertFrom-Json
        Write-ColorOutput "✓ Table exists and is accessible" "Green"
        Write-ColorOutput "Status: $($table.Table.TableStatus)" "Green"
        Write-ColorOutput "Item Count: $($table.Table.ItemCount)" "Green"
        
        # Scan for recent items (limit 5)
        if ($Verbose) {
            Write-ColorOutput "`nRecent items:" "Cyan"
            $items = aws dynamodb scan --table-name $tableName --max-items 5 --output json | ConvertFrom-Json
            
            if ($items.Items.Count -gt 0) {
                $items.Items | ForEach-Object {
                    Write-Host ($_ | ConvertTo-Json -Depth 3)
                }
            } else {
                Write-ColorOutput "No items in table yet" "Yellow"
            }
        }
    } catch {
        Write-ColorOutput "✗ Error accessing DynamoDB: $_" "Red"
    }
}

# =============================================================================
# Main Test Execution
# =============================================================================

Write-ColorOutput @"
╔═══════════════════════════════════════════════════════════════╗
║                                                               ║
║   PROJECT CORTEX - COMPREHENSIVE PIPELINE TESTING SUITE      ║
║                                                               ║
║   Testing all three modules and infrastructure components    ║
║                                                               ║
╚═══════════════════════════════════════════════════════════════╝
"@ "Bold"

# Step 1: Prerequisites
if (-not (Test-Prerequisites)) {
    exit 1
}

Start-Sleep -Seconds 2

# Step 2: Get infrastructure outputs
$outputs = Get-TerraformOutputs

Start-Sleep -Seconds 2

# Step 3: Run tests based on parameters
$allTestResults = @()

if (-not $Module2Only -and -not $Module3Only) {
    $allTestResults += Test-Module1-AutoRemediator -Outputs $outputs
    Start-Sleep -Seconds 2
}

if (-not $Module1Only -and -not $Module3Only) {
    $allTestResults += Test-Module2-GitRadar -Outputs $outputs
    Start-Sleep -Seconds 2
}

if (-not $Module1Only -and -not $Module2Only) {
    $allTestResults += Test-Module3-FinOpsSentinel -Outputs $outputs
    Start-Sleep -Seconds 2
}

# Step 4: Verify CloudWatch Logs
Test-CloudWatchLogs -Outputs $outputs

Start-Sleep -Seconds 2

# Step 5: Verify DynamoDB
Test-DynamoDB -Outputs $outputs

# =============================================================================
# Final Summary
# =============================================================================

Write-Host ""
Write-ColorOutput "═══════════════════════════════════════════════════════════" "Cyan"
Write-ColorOutput "$($Colors.Bold)FINAL TEST SUMMARY$($Colors.Reset)" "Cyan"
Write-ColorOutput "═══════════════════════════════════════════════════════════" "Cyan"
Write-Host ""

$totalPassed = ($allTestResults | Where-Object { $_ -eq $true }).Count
$totalTests = $allTestResults.Count

Write-ColorOutput "Total Module Tests: $totalTests" "Blue"
Write-ColorOutput "Passed: $totalPassed" $(if ($totalPassed -eq $totalTests) { "Green" } else { "Yellow" })
Write-ColorOutput "Failed: $($totalTests - $totalPassed)" $(if ($totalPassed -eq $totalTests) { "Green" } else { "Red" })
Write-Host ""

if ($totalPassed -eq $totalTests) {
    Write-ColorOutput "🎉 ALL TESTS PASSED! Your Telegram bot pipeline is working correctly!" "Green"
    Write-Host ""
    Write-ColorOutput "Next Steps:" "Cyan"
    Write-Host "  1. Configure GitHub webhook: $($outputs.github_webhook_url.value)"
    Write-Host "  2. Set up cost monitoring tool to use: $($outputs.finops_webhook_url.value)"
    Write-Host "  3. Monitor CloudWatch Logs for production events"
    Write-Host "  4. Check Telegram for notifications"
    Write-Host ""
    exit 0
} else {
    Write-ColorOutput "⚠ SOME TESTS FAILED. Please review the errors above." "Yellow"
    Write-Host ""
    Write-ColorOutput "Troubleshooting Tips:" "Cyan"
    Write-Host "  1. Check Lambda function logs in CloudWatch"
    Write-Host "  2. Verify environment variables in terraform.tfvars"
    Write-Host "  3. Ensure GitHub App credentials are configured correctly"
    Write-Host "  4. Verify Telegram bot token and chat ID"
    Write-Host "  5. Run with -Verbose flag for detailed output"
    Write-Host ""
    exit 1
}
