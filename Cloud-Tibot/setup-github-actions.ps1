#!/usr/bin/env pwsh
<#
.SYNOPSIS
    CORTEX Guardian - Automated GitHub Actions Setup Script

.DESCRIPTION
    This script automates the setup of CORTEX Guardian (Module 4) as a GitHub Actions workflow.
    It helps configure secrets, verify infrastructure, and validate the integration.

.PARAMETER Mode
    Setup mode: "github-models" (free, recommended) or "openai" (paid, higher limits)

.PARAMETER SkipSecrets
    Skip GitHub Secrets configuration (if already configured)

.PARAMETER SkipValidation
    Skip final validation tests

.EXAMPLE
    .\setup-github-actions.ps1 -Mode github-models
    
.EXAMPLE
    .\setup-github-actions.ps1 -Mode openai -SkipValidation

.NOTES
    Author: Project CORTEX Team
    Version: 2.0.0
    Requires: PowerShell 7+, GitHub CLI (optional), Terraform (for webhook URL)
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [ValidateSet("github-models", "openai", "hybrid")]
    [string]$Mode = "github-models",
    
    [Parameter(Mandatory=$false)]
    [switch]$SkipSecrets = $false,
    
    [Parameter(Mandatory=$false)]
    [switch]$SkipValidation = $false,
    
    [Parameter(Mandatory=$false)]
    [string]$GithubToken = "",
    
    [Parameter(Mandatory=$false)]
    [string]$OpenAiApiKey = "",
    
    [Parameter(Mandatory=$false)]
    [string]$Repository = ""
)

# ============================================================================
# Configuration & Constants
# ============================================================================

$ErrorActionPreference = "Stop"
$Script:WorkflowPath = ".github/workflows/cortex_guardian.yml"
$Script:Pr_GuardianPath = "src/module4_agent/pr_guardian.py"
$Script:RequirementsPath = "src/module4_agent/requirements.txt"

# Colors for output
function Write-Header { param([string]$Message) Write-Host "`n$('='*70)" -ForegroundColor Cyan; Write-Host $Message -ForegroundColor Cyan; Write-Host "$('='*70)" -ForegroundColor Cyan }
function Write-Success { param([string]$Message) Write-Host "✅ $Message" -ForegroundColor Green }
function Write-Warning { param([string]$Message) Write-Host "⚠️  $Message" -ForegroundColor Yellow }
function Write-Error { param([string]$Message) Write-Host "❌ $Message" -ForegroundColor Red }
function Write-Info { param([string]$Message) Write-Host "ℹ️  $Message" -ForegroundColor Blue }
function Write-Step { param([string]$Message) Write-Host "`n▶️  $Message" -ForegroundColor Magenta }

# ============================================================================
# Step 0: Display Welcome & Configuration
# ============================================================================

Write-Header "🛡️  CORTEX GUARDIAN - GitHub Actions Setup"
Write-Info "Mode: $Mode"
Write-Info "Repository: $(if ($Repository) { $Repository } else { 'Will auto-detect' })"
Write-Info "Skip Secrets: $SkipSecrets"
Write-Info "Skip Validation: $SkipValidation"

# Display mode-specific information
switch ($Mode) {
    "github-models" {
        Write-Host "`n📋 GitHub Models Mode (Recommended):" -ForegroundColor Cyan
        Write-Host "   • Cost: 🆓 FREE!" -ForegroundColor Green
        Write-Host "   • Rate Limits: 15 req/min, 150 req/day" -ForegroundColor Yellow
        Write-Host "   • Models: GPT-4o, GPT-4o-mini, Claude 3.5, Llama 3.1" -ForegroundColor White
        Write-Host "   • Authentication: GitHub Token (personal access token)" -ForegroundColor White
    }
    "openai" {
        Write-Host "`n📋 OpenAI Mode:" -ForegroundColor Cyan
        Write-Host "   • Cost: ~$0.05 per PR (~$3-6/month)" -ForegroundColor Yellow
        Write-Host "   • Rate Limits: High (paid tier)" -ForegroundColor Green
        Write-Host "   • Models: GPT-4, GPT-4-turbo, GPT-3.5-turbo" -ForegroundColor White
        Write-Host "   • Authentication: OpenAI API Key" -ForegroundColor White
    }
    "hybrid" {
        Write-Host "`n📋 Hybrid Mode (Best Reliability):" -ForegroundColor Cyan
        Write-Host "   • Primary: GitHub Models (free)" -ForegroundColor Green
        Write-Host "   • Fallback: OpenAI API (paid)" -ForegroundColor Yellow
        Write-Host "   • Best of both worlds: Free + Reliable" -ForegroundColor White
    }
}

Write-Host ""
Read-Host "Press Enter to continue or Ctrl+C to abort"

# ============================================================================
# Step 1: Prerequisites Check
# ============================================================================

Write-Step "Checking Prerequisites..."

# Check PowerShell version
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Warning "PowerShell 7+ recommended. Current version: $($PSVersionTable.PSVersion)"
}

# Check if we're in the right directory
if (-not (Test-Path "terraform.tfvars") -and -not (Test-Path "provider.tf")) {
    Write-Error "Not in CORTEX project root directory!"
    Write-Host "Please run this script from the root of your CORTEX repository."
    exit 1
}
Write-Success "Running from CORTEX project root"

# Check for GitHub CLI (optional but helpful)
$HasGhCli = $null -ne (Get-Command "gh" -ErrorAction SilentlyContinue)
if ($HasGhCli) {
    Write-Success "GitHub CLI detected (gh)"
    $GhVersion = gh --version | Select-Object -First 1
    Write-Info "  $GhVersion"
} else {
    Write-Warning "GitHub CLI (gh) not found - will provide manual instructions"
    Write-Info "  Install from: https://cli.github.com/"
}

# Check for Terraform
$HasTerraform = $null -ne (Get-Command "terraform" -ErrorAction SilentlyContinue)
if ($HasTerraform) {
    Write-Success "Terraform detected"
    $TfVersion = terraform version | Select-Object -First 1
    Write-Info "  $TfVersion"
} else {
    Write-Warning "Terraform not found - webhook URL retrieval may fail"
}

# Check if GitHub Actions workflow exists
if (Test-Path $Script:WorkflowPath) {
    Write-Success "GitHub Actions workflow found: $Script:WorkflowPath"
} else {
    Write-Warning "GitHub Actions workflow not found: $Script:WorkflowPath"
    Write-Info "Will create workflow file..."
}

# Check if PR Guardian exists
if (Test-Path $Script:Pr_GuardianPath) {
    Write-Success "PR Guardian script found: $Script:Pr_GuardianPath"
} else {
    Write-Error "PR Guardian script not found: $Script:Pr_GuardianPath"
    Write-Host "Please ensure Module 4 is properly set up."
    exit 1
}

Write-Success "Prerequisites check complete!"

# ============================================================================
# Step 2: Auto-detect Repository
# ============================================================================

Write-Step "Detecting Repository Information..."

if (-not $Repository) {
    if ($HasGhCli) {
        try {
            $RepoInfo = gh repo view --json owner,name | ConvertFrom-Json
            $Repository = "$($RepoInfo.owner.login)/$($RepoInfo.name)"
            Write-Success "Auto-detected repository: $Repository"
        } catch {
            Write-Warning "Could not auto-detect repository with gh CLI"
        }
    }
    
    if (-not $Repository) {
        # Try to extract from git remote
        try {
            $GitRemote = git remote get-url origin 2>$null
            if ($GitRemote -match "github\.com[:/]([^/]+)/([^/.]+)") {
                $Repository = "$($matches[1])/$($matches[2])"
                Write-Success "Detected from git remote: $Repository"
            }
        } catch {
            Write-Warning "Could not extract repository from git remote"
        }
    }
    
    if (-not $Repository) {
        Write-Host ""
        $Repository = Read-Host "Enter your GitHub repository (format: owner/repo)"
        if (-not $Repository -or $Repository -notmatch "^[^/]+/[^/]+$") {
            Write-Error "Invalid repository format. Expected: owner/repo"
            exit 1
        }
    }
}

Write-Success "Repository: $Repository"

# ============================================================================
# Step 3: Get CORTEX Radar Webhook URL
# ============================================================================

Write-Step "Retrieving CORTEX Radar Webhook URL..."

$WebhookUrl = ""

if ($HasTerraform) {
    try {
        # Check if terraform state exists
        if (Test-Path "terraform.tfstate") {
            $TfOutput = terraform output -json 2>$null | ConvertFrom-Json
            if ($TfOutput.github_webhook_url) {
                $WebhookUrl = $TfOutput.github_webhook_url.value
                Write-Success "Retrieved webhook URL from Terraform:"
                Write-Info "  $WebhookUrl"
            } else {
                Write-Warning "Terraform output 'github_webhook_url' not found"
            }
        } else {
            Write-Warning "Terraform state file not found (not deployed yet?)"
        }
    } catch {
        Write-Warning "Could not retrieve Terraform output: $_"
    }
} else {
    Write-Warning "Terraform not available - cannot auto-retrieve webhook URL"
}

if (-not $WebhookUrl) {
    Write-Host ""
    Write-Info "To get the webhook URL, run: terraform output github_webhook_url"
    Write-Host ""
    $WebhookUrl = Read-Host "Enter CORTEX Radar Webhook URL (or leave blank to configure later)"
}

# ============================================================================
# Step 4: Configure GitHub Secrets
# ============================================================================

if (-not $SkipSecrets) {
    Write-Step "Configuring GitHub Secrets..."
    
    Write-Host ""
    Write-Info "GitHub Actions requires the following secrets to be configured:"
    
    # Required secrets based on mode
    $SecretsToCreate = @()
    
    switch ($Mode) {
        "github-models" {
            Write-Host ""
            Write-Host "📋 Required Secrets for GitHub Models Mode:" -ForegroundColor Cyan
            Write-Host "   1. GITHUB_TOKEN - Auto-provided by GitHub Actions (no action needed)" -ForegroundColor Green
            Write-Host "   2. CORTEX_RADAR_WEBHOOK - Module 2 webhook URL" -ForegroundColor Yellow
            Write-Host ""
            Write-Info "Note: GITHUB_TOKEN is automatically provided by GitHub Actions"
            Write-Info "      But you need a personal access token with 'model' scope for AI access"
            Write-Host ""
            
            $SecretsToCreate += @{
                Name = "GITHUB_MODELS_TOKEN"
                Description = "GitHub Personal Access Token with 'repo' and 'model' scopes"
                Required = $true
                Instructions = @"
To create this token:
1. Go to: https://github.com/settings/tokens?type=beta
2. Click 'Generate new token' → 'Generate new token (classic)'
3. Set note: 'CORTEX Guardian - GitHub Models'
4. Select scopes: 'repo' (full) and 'model' (for AI access)
5. Click 'Generate token' and copy it
"@
            }
        }
        "openai" {
            Write-Host ""
            Write-Host "📋 Required Secrets for OpenAI Mode:" -ForegroundColor Cyan
            Write-Host "   1. GITHUB_TOKEN - Auto-provided by GitHub Actions (no action needed)" -ForegroundColor Green
            Write-Host "   2. OPENAI_API_KEY - Your OpenAI API key" -ForegroundColor Yellow
            Write-Host "   3. CORTEX_RADAR_WEBHOOK - Module 2 webhook URL" -ForegroundColor Yellow
            Write-Host ""
            
            $SecretsToCreate += @{
                Name = "OPENAI_API_KEY"
                Description = "OpenAI API Key for GPT-4/GPT-3.5 access"
                Required = $true
                Instructions = @"
To create this key:
1. Go to: https://platform.openai.com/api-keys
2. Click 'Create new secret key'
3. Set name: 'CORTEX Guardian'
4. Copy the key (you won't see it again!)
"@
            }
        }
        "hybrid" {
            Write-Host ""
            Write-Host "📋 Required Secrets for Hybrid Mode:" -ForegroundColor Cyan
            Write-Host "   1. GITHUB_TOKEN - Auto-provided by GitHub Actions" -ForegroundColor Green
            Write-Host "   2. GITHUB_MODELS_TOKEN - Personal access token with model scope" -ForegroundColor Yellow
            Write-Host "   3. OPENAI_API_KEY - Your OpenAI API key (fallback)" -ForegroundColor Yellow
            Write-Host "   4. CORTEX_RADAR_WEBHOOK - Module 2 webhook URL" -ForegroundColor Yellow
            Write-Host ""
            
            $SecretsToCreate += @{
                Name = "GITHUB_MODELS_TOKEN"
                Description = "GitHub PAT with 'repo' and 'model' scopes (primary)"
                Required = $true
                Instructions = "See GitHub Models instructions above"
            }
            
            $SecretsToCreate += @{
                Name = "OPENAI_API_KEY"
                Description = "OpenAI API Key (fallback when rate limited)"
                Required = $true
                Instructions = "See OpenAI instructions above"
            }
        }
    }
    
    # Add CORTEX_RADAR_WEBHOOK for all modes
    $SecretsToCreate += @{
        Name = "CORTEX_RADAR_WEBHOOK"
        Description = "Module 2 Git Radar webhook URL"
        Required = $false
        Value = $WebhookUrl
        Instructions = "Run: terraform output github_webhook_url"
    }
    
    # Configure secrets
    Write-Host ""
    if ($HasGhCli) {
        Write-Info "Using GitHub CLI to set secrets..."
        Write-Host ""
        
        foreach ($Secret in $SecretsToCreate) {
            Write-Host "━" * 70 -ForegroundColor DarkGray
            Write-Host "🔑 Secret: $($Secret.Name)" -ForegroundColor Cyan
            Write-Host "   $($Secret.Description)" -ForegroundColor White
            
            if ($Secret.Instructions) {
                Write-Host ""
                Write-Host $Secret.Instructions -ForegroundColor DarkGray
                Write-Host ""
            }
            
            $SecretValue = ""
            
            # Check if we have a pre-provided value
            if ($Secret.Name -eq "GITHUB_MODELS_TOKEN" -and $GithubToken) {
                $SecretValue = $GithubToken
                Write-Info "Using provided GitHub token"
            } elseif ($Secret.Name -eq "OPENAI_API_KEY" -and $OpenAiApiKey) {
                $SecretValue = $OpenAiApiKey
                Write-Info "Using provided OpenAI API key"
            } elseif ($Secret.Value) {
                $SecretValue = $Secret.Value
                Write-Info "Using detected value"
            }
            
            # If no value, prompt user
            if (-not $SecretValue) {
                if ($Secret.Required) {
                    $SecretValue = Read-Host "Enter value for $($Secret.Name)" -AsSecureString
                    $SecretValue = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecretValue))
                } else {
                    $Response = Read-Host "Enter value for $($Secret.Name) (or press Enter to skip)"
                    if ($Response) {
                        $SecretValue = $Response
                    }
                }
            }
            
            if ($SecretValue) {
                try {
                    # Set secret using gh CLI
                    $SecretValue | gh secret set $($Secret.Name) --repo $Repository
                    Write-Success "Secret '$($Secret.Name)' configured successfully"
                } catch {
                    Write-Error "Failed to set secret '$($Secret.Name)': $_"
                }
            } else {
                Write-Warning "Skipped secret '$($Secret.Name)'"
            }
        }
        
        Write-Host ""
        Write-Success "GitHub Secrets configuration complete!"
        
    } else {
        # Manual instructions if gh CLI not available
        Write-Warning "GitHub CLI not available - providing manual instructions..."
        Write-Host ""
        Write-Host "To configure secrets manually:" -ForegroundColor Cyan
        Write-Host "1. Go to: https://github.com/$Repository/settings/secrets/actions" -ForegroundColor White
        Write-Host "2. Click 'New repository secret'" -ForegroundColor White
        Write-Host "3. Add each of the following secrets:" -ForegroundColor White
        Write-Host ""
        
        foreach ($Secret in $SecretsToCreate) {
            Write-Host "   🔑 $($Secret.Name)" -ForegroundColor Yellow
            Write-Host "      $($Secret.Description)" -ForegroundColor DarkGray
            if ($Secret.Value) {
                Write-Host "      Value: $($Secret.Value)" -ForegroundColor Green
            }
            Write-Host ""
        }
        
        Write-Host ""
        Read-Host "Press Enter after configuring secrets on GitHub"
    }
    
} else {
    Write-Info "Skipping GitHub Secrets configuration (--SkipSecrets flag)"
}

# ============================================================================
# Step 5: Verify/Create GitHub Actions Workflow
# ============================================================================

Write-Step "Verifying GitHub Actions Workflow..."

if (Test-Path $Script:WorkflowPath) {
    Write-Success "Workflow file exists: $Script:WorkflowPath"
    
    # Check if workflow is configured for the right mode
    $WorkflowContent = Get-Content $Script:WorkflowPath -Raw
    
    $HasCorrectMode = switch ($Mode) {
        "github-models" { $WorkflowContent -match "GITHUB_MODELS_TOKEN|GITHUB_TOKEN.*model" }
        "openai" { $WorkflowContent -match "OPENAI_API_KEY" }
        "hybrid" { ($WorkflowContent -match "GITHUB_MODELS_TOKEN") -and ($WorkflowContent -match "OPENAI_API_KEY") }
    }
    
    if (-not $HasCorrectMode) {
        Write-Warning "Workflow may not be configured for $Mode mode"
        Write-Info "Please review $Script:WorkflowPath and ensure correct environment variables"
    }
    
} else {
    Write-Warning "Workflow file not found - creating default workflow..."
    
    # Create .github/workflows directory if needed
    $WorkflowDir = Split-Path $Script:WorkflowPath -Parent
    if (-not (Test-Path $WorkflowDir)) {
        New-Item -ItemType Directory -Path $WorkflowDir -Force | Out-Null
        Write-Success "Created directory: $WorkflowDir"
    }
    
    # Create default workflow based on mode
    $WorkflowTemplate = switch ($Mode) {
        "github-models" { @"
name: 🛡️ CORTEX Guardian - PR Security Scanner (GitHub Models)

on:
  pull_request:
    types: [opened, synchronize, reopened]

concurrency:
  group: cortex-guardian-`${{ github.event.pull_request.number }}
  cancel-in-progress: true

jobs:
  pr-security-scan:
    name: AI Code Review & Security Analysis
    runs-on: ubuntu-latest
    
    permissions:
      contents: read
      pull-requests: write
      issues: write
    
    steps:
      - name: 📥 Checkout Repository
        uses: actions/checkout@v4
        with:
          fetch-depth: 0
      
      - name: 🐍 Set up Python 3.11
        uses: actions/setup-python@v5
        with:
          python-version: '3.11'
          cache: 'pip'
      
      - name: 📦 Install Dependencies
        run: |
          pip install --upgrade pip
          pip install -r src/module4_agent/requirements.txt
      
      - name: 🛡️ Run CORTEX Guardian Scan
        env:
          GITHUB_TOKEN: `${{ secrets.GITHUB_MODELS_TOKEN || secrets.GITHUB_TOKEN }}
          CORTEX_RADAR_WEBHOOK: `${{ secrets.CORTEX_RADAR_WEBHOOK }}
          GITHUB_REPOSITORY: `${{ github.repository }}
          GITHUB_EVENT_PATH: `${{ github.event_path }}
          USE_GITHUB_MODELS: "true"
        run: |
          echo "🛡️ CORTEX-GUARDIAN | GitHub Models Mode"
          echo "Repository: `$GITHUB_REPOSITORY"
          echo "PR: #`${{ github.event.pull_request.number }}"
          python src/module4_agent/pr_guardian.py
        continue-on-error: true
      
      - name: 📊 Upload Logs
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: cortex-guardian-logs
          path: "*.log"
          retention-days: 7
"@ }
        "openai" { Get-Content $Script:WorkflowPath -Raw -ErrorAction SilentlyContinue }
        "hybrid" { @"
name: 🛡️ CORTEX Guardian - PR Security Scanner (Hybrid)

on:
  pull_request:
    types: [opened, synchronize, reopened]

concurrency:
  group: cortex-guardian-`${{ github.event.pull_request.number }}
  cancel-in-progress: true

jobs:
  pr-security-scan:
    name: AI Code Review & Security Analysis
    runs-on: ubuntu-latest
    
    permissions:
      contents: read
      pull-requests: write
      issues: write
    
    steps:
      - name: 📥 Checkout Repository
        uses: actions/checkout@v4
        with:
          fetch-depth: 0
      
      - name: 🐍 Set up Python 3.11
        uses: actions/setup-python@v5
        with:
          python-version: '3.11'
          cache: 'pip'
      
      - name: 📦 Install Dependencies
        run: |
          pip install --upgrade pip
          pip install -r src/module4_agent/requirements.txt
      
      - name: 🛡️ Run CORTEX Guardian Scan (Hybrid Mode)
        env:
          GITHUB_TOKEN: `${{ secrets.GITHUB_MODELS_TOKEN || secrets.GITHUB_TOKEN }}
          OPENAI_API_KEY: `${{ secrets.OPENAI_API_KEY }}
          CORTEX_RADAR_WEBHOOK: `${{ secrets.CORTEX_RADAR_WEBHOOK }}
          GITHUB_REPOSITORY: `${{ github.repository }}
          GITHUB_EVENT_PATH: `${{ github.event_path }}
          USE_HYBRID_MODE: "true"
        run: |
          echo "🛡️ CORTEX-GUARDIAN | Hybrid Mode (GitHub Models + OpenAI)"
          echo "Repository: `$GITHUB_REPOSITORY"
          echo "PR: #`${{ github.event.pull_request.number }}"
          python src/module4_agent/pr_guardian.py
        continue-on-error: true
      
      - name: 📊 Upload Logs
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: cortex-guardian-logs
          path: "*.log"
          retention-days: 7
"@ }
    }
    
    if ($WorkflowTemplate) {
        Set-Content -Path $Script:WorkflowPath -Value $WorkflowTemplate -Encoding UTF8
        Write-Success "Created workflow file: $Script:WorkflowPath"
    }
}

# ============================================================================
# Step 6: Verify Dependencies
# ============================================================================

Write-Step "Verifying Python Dependencies..."

if (Test-Path $Script:RequirementsPath) {
    Write-Success "Requirements file found: $Script:RequirementsPath"
    
    $RequiredPackages = @("PyGithub", "requests", "urllib3")
    $Requirements = Get-Content $Script:RequirementsPath
    
    foreach ($Package in $RequiredPackages) {
        if ($Requirements -match $Package) {
            Write-Success "  ✓ $Package"
        } else {
            Write-Warning "  ✗ $Package - may need to add to requirements.txt"
        }
    }
} else {
    Write-Warning "Requirements file not found: $Script:RequirementsPath"
}

# ============================================================================
# Step 7: Commit & Push Workflow (if new)
# ============================================================================

Write-Step "Committing Changes (if any)..."

$HasGit = $null -ne (Get-Command "git" -ErrorAction SilentlyContinue)

if ($HasGit) {
    # Check for uncommitted workflow
    $GitStatus = git status --porcelain $Script:WorkflowPath 2>$null
    
    if ($GitStatus) {
        Write-Info "Workflow file has uncommitted changes"
        Write-Host ""
        $ShouldCommit = Read-Host "Commit and push workflow file? (y/n)"
        
        if ($ShouldCommit -eq "y" -or $ShouldCommit -eq "Y") {
            try {
                git add $Script:WorkflowPath
                git commit -m "🛡️ Add CORTEX Guardian GitHub Actions workflow ($Mode mode)"
                git push
                Write-Success "Workflow committed and pushed!"
            } catch {
                Write-Warning "Could not commit/push: $_"
                Write-Info "Please commit manually: git add $Script:WorkflowPath && git commit && git push"
            }
        }
    } else {
        Write-Success "No uncommitted changes"
    }
} else {
    Write-Warning "Git not available - cannot auto-commit"
}

# ============================================================================
# Step 8: Validation & Testing
# ============================================================================

if (-not $SkipValidation) {
    Write-Step "Running Validation Tests..."
    
    # Test 1: Check if secrets are accessible (using gh CLI)
    if ($HasGhCli) {
        Write-Host ""
        Write-Info "Testing GitHub Secrets access..."
        try {
            $Secrets = gh secret list --repo $Repository 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Success "Successfully accessed repository secrets:"
                $Secrets | ForEach-Object { Write-Host "   • $_" -ForegroundColor DarkGray }
            } else {
                Write-Warning "Could not list secrets: $Secrets"
            }
        } catch {
            Write-Warning "Secret validation failed: $_"
        }
    }
    
    # Test 2: Check workflow syntax
    Write-Host ""
    Write-Info "Validating workflow syntax..."
    if (Test-Path $Script:WorkflowPath) {
        try {
            $WorkflowYaml = Get-Content $Script:WorkflowPath -Raw
            # Basic YAML validation
            if ($WorkflowYaml -match "name:" -and $WorkflowYaml -match "on:" -and $WorkflowYaml -match "jobs:") {
                Write-Success "Workflow syntax appears valid"
            } else {
                Write-Warning "Workflow may have syntax issues"
            }
        } catch {
            Write-Warning "Could not validate workflow: $_"
        }
    }
    
    # Test 3: Verify webhook URL is accessible (optional)
    if ($WebhookUrl -and $WebhookUrl -match "^https?://") {
        Write-Host ""
        Write-Info "Testing webhook URL connectivity..."
        try {
            $Response = Invoke-WebRequest -Uri $WebhookUrl -Method HEAD -TimeoutSec 5 -ErrorAction Stop
            Write-Success "Webhook URL is accessible (HTTP $($Response.StatusCode))"
        } catch {
            Write-Warning "Webhook URL test failed: $_"
            Write-Info "This is normal if Lambda requires authentication"
        }
    }
    
    Write-Host ""
    Write-Success "Validation complete!"
    
} else {
    Write-Info "Skipping validation (--SkipValidation flag)"
}

# ============================================================================
# Step 9: Final Summary & Next Steps
# ============================================================================

Write-Header "✅ CORTEX Guardian GitHub Actions Setup Complete!"

Write-Host ""
Write-Host "📋 Configuration Summary:" -ForegroundColor Cyan
Write-Host "   • Mode: $Mode" -ForegroundColor White
Write-Host "   • Repository: $Repository" -ForegroundColor White
Write-Host "   • Workflow: $Script:WorkflowPath" -ForegroundColor White
if ($WebhookUrl) {
    Write-Host "   • Webhook: $WebhookUrl" -ForegroundColor White
}

Write-Host ""
Write-Host "🎯 Next Steps:" -ForegroundColor Cyan
Write-Host ""
Write-Host "1️⃣  Create a test Pull Request to trigger CORTEX Guardian:" -ForegroundColor Yellow
Write-Host "   git checkout -b test/cortex-guardian" -ForegroundColor White
Write-Host "   echo '# Test' >> test.md" -ForegroundColor White
Write-Host "   git add test.md && git commit -m 'test: CORTEX Guardian'" -ForegroundColor White
Write-Host "   git push -u origin test/cortex-guardian" -ForegroundColor White
Write-Host "   gh pr create --title 'Test: CORTEX Guardian' --body 'Testing AI security scan'" -ForegroundColor White
Write-Host ""
Write-Host "2️⃣  Monitor the GitHub Actions run:" -ForegroundColor Yellow
Write-Host "   https://github.com/$Repository/actions" -ForegroundColor White
Write-Host ""
Write-Host "3️⃣  Check for PR comment from CORTEX Guardian:" -ForegroundColor Yellow
Write-Host "   The bot will post security analysis as a comment on your PR" -ForegroundColor White
Write-Host ""
Write-Host "4️⃣  View logs and artifacts:" -ForegroundColor Yellow
Write-Host "   Check 'cortex-guardian-logs' artifact in the Actions run" -ForegroundColor White
Write-Host ""

if ($Mode -eq "github-models") {
    Write-Host "💡 GitHub Models Usage:" -ForegroundColor Cyan
    Write-Host "   • Rate Limits: 15 requests/min, 150 requests/day" -ForegroundColor Yellow
    Write-Host "   • If you hit limits, consider upgrading to Hybrid mode" -ForegroundColor Yellow
    Write-Host "   • Run: .\setup-github-actions.ps1 -Mode hybrid" -ForegroundColor White
    Write-Host ""
}

Write-Host "📚 Documentation:" -ForegroundColor Cyan
Write-Host "   • GITHUB_COPILOT_INTEGRATION.md - Mode comparison & setup" -ForegroundColor White
Write-Host "   • GITHUB_APP_SETUP.md - GitHub App authentication" -ForegroundColor White
Write-Host "   • README.md - Full CORTEX documentation" -ForegroundColor White
Write-Host ""

Write-Host "🆘 Troubleshooting:" -ForegroundColor Cyan
Write-Host "   • Check secrets: gh secret list --repo $Repository" -ForegroundColor White
Write-Host "   • View workflow: cat $Script:WorkflowPath" -ForegroundColor White
Write-Host "   • Check logs: gh run list --repo $Repository" -ForegroundColor White
Write-Host "   • Test locally: python $Script:Pr_GuardianPath" -ForegroundColor White
Write-Host ""

Write-Success "Setup complete! 🎉"
Write-Host ""
