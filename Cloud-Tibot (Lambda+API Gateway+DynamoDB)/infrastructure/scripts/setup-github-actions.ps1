#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Quick setup script for DND Platform GitHub Actions and Telegram Bot

.DESCRIPTION
    This script helps you configure GitHub Secrets and test the Telegram bot
    for the IB-DND-5e-Platform repository

.EXAMPLE
    .\setup-github-actions.ps1
#>

$ErrorActionPreference = "Stop"

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "🎲 DND Platform - GitHub Actions Setup" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Check if GitHub CLI is installed
$ghInstalled = Get-Command gh -ErrorAction SilentlyContinue
if (-not $ghInstalled) {
    Write-Host "❌ GitHub CLI (gh) is not installed!" -ForegroundColor Red
    Write-Host "Install it from: https://cli.github.com/" -ForegroundColor Yellow
    exit 1
}

# Check if logged into GitHub
$ghAuth = gh auth status 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "❌ Not logged into GitHub CLI!" -ForegroundColor Red
    Write-Host "Run: gh auth login" -ForegroundColor Yellow
    exit 1
}

Write-Host "✅ GitHub CLI is ready!" -ForegroundColor Green
Write-Host ""

# Repository information
$repo = "Brendon20011007/IB-DND-5e-Platform"
Write-Host "📦 Repository: $repo" -ForegroundColor Cyan
Write-Host ""

# Function to set secret
function Set-GitHubSecret {
    param(
        [string]$Name,
        [string]$Description,
        [bool]$Required = $true
    )
    
    Write-Host "🔐 Setting secret: $Name" -ForegroundColor Yellow
    Write-Host "   Description: $Description" -ForegroundColor Gray
    
    $value = Read-Host "   Enter value (or press Enter to skip)"
    
    if ([string]::IsNullOrWhiteSpace($value)) {
        if ($Required) {
            Write-Host "   ⚠️  Skipped (REQUIRED)" -ForegroundColor Yellow
        } else {
            Write-Host "   ⏭️  Skipped (Optional)" -ForegroundColor Gray
        }
        return $false
    }
    
    try {
        $value | gh secret set $Name -R $repo
        Write-Host "   ✅ Secret set successfully!" -ForegroundColor Green
        return $true
    } catch {
        Write-Host "   ❌ Failed to set secret: $_" -ForegroundColor Red
        return $false
    }
}

Write-Host "===========================================" -ForegroundColor Cyan
Write-Host "📝 GitHub Secrets Configuration" -ForegroundColor Cyan
Write-Host "===========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "We'll now configure the required secrets." -ForegroundColor White
Write-Host "Press Enter to skip any optional secrets." -ForegroundColor Gray
Write-Host ""

# AWS Credentials
Write-Host "--- AWS Credentials ---" -ForegroundColor Magenta
Set-GitHubSecret -Name "AWS_ACCESS_KEY_ID" -Description "AWS Access Key ID" -Required $true
Set-GitHubSecret -Name "AWS_SECRET_ACCESS_KEY" -Description "AWS Secret Access Key" -Required $true
Write-Host ""

# Telegram
Write-Host "--- Telegram Bot ---" -ForegroundColor Magenta
Set-GitHubSecret -Name "TELEGRAM_BOT_TOKEN" -Description "Telegram Bot Token from @BotFather" -Required $true
Set-GitHubSecret -Name "TELEGRAM_CHAT_ID" -Description "Your Telegram Chat ID" -Required $true
Write-Host ""

# Supabase
Write-Host "--- Supabase Configuration ---" -ForegroundColor Magenta
Set-GitHubSecret -Name "VITE_SUPABASE_URL" -Description "Supabase Project URL" -Required $true
Set-GitHubSecret -Name "VITE_SUPABASE_ANON_KEY" -Description "Supabase Anon Key" -Required $true
Set-GitHubSecret -Name "SUPABASE_JWT_SECRET" -Description "Supabase JWT Secret" -Required $true
Set-GitHubSecret -Name "SUPABASE_ACCESS_TOKEN" -Description "Supabase Access Token" -Required $false
Set-GitHubSecret -Name "SUPABASE_PROJECT_REF" -Description "Supabase Project Reference" -Required $false
Write-Host ""

# API Keys
Write-Host "--- API Keys ---" -ForegroundColor Magenta
Set-GitHubSecret -Name "GEMINI_API_KEY" -Description "Google Gemini API Key" -Required $true
Write-Host ""

# Vercel
Write-Host "--- Vercel Deployment (Optional) ---" -ForegroundColor Magenta
Set-GitHubSecret -Name "VERCEL_TOKEN" -Description "Vercel API Token" -Required $false
Set-GitHubSecret -Name "VERCEL_ORG_ID" -Description "Vercel Organization ID" -Required $false
Set-GitHubSecret -Name "VERCEL_PROJECT_ID" -Description "Vercel Project ID" -Required $false
Set-GitHubSecret -Name "VERCEL_URL" -Description "Vercel Deployment URL" -Required $false
Write-Host ""

# Infrastructure
Write-Host "--- Infrastructure ---" -ForegroundColor Magenta
Set-GitHubSecret -Name "VITE_AWS_API_URL" -Description "AWS API Gateway URL" -Required $false
Write-Host ""

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "✅ Secret Configuration Complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Test Telegram Bot
Write-Host "🧪 Testing Telegram Bot..." -ForegroundColor Yellow
Write-Host ""

$testBot = Read-Host "Do you want to test the Telegram bot now? (y/n)"

if ($testBot -eq 'y') {
    Write-Host "Testing bot with Python script..." -ForegroundColor Cyan
    
    Push-Location scripts
    
    # Check if Python is installed
    $pythonInstalled = Get-Command python -ErrorAction SilentlyContinue
    if (-not $pythonInstalled) {
        Write-Host "❌ Python is not installed!" -ForegroundColor Red
        Write-Host "Install Python from: https://www.python.org/" -ForegroundColor Yellow
        Pop-Location
    } else {
        # Install dependencies
        Write-Host "📦 Installing dependencies..." -ForegroundColor Cyan
        python -m pip install -r requirements.txt --quiet
        
        # Run test
        Write-Host "🤖 Running bot test..." -ForegroundColor Cyan
        python telegram_bot.py
        
        Pop-Location
    }
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "🎉 Setup Complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Next Steps:" -ForegroundColor Cyan
Write-Host "1. ✅ Copy the workflow files to your repository" -ForegroundColor White
Write-Host "2. ✅ Push the workflows to GitHub" -ForegroundColor White
Write-Host "3. ✅ Create a Pull Request to test the workflows" -ForegroundColor White
Write-Host "4. ✅ Check Telegram for notifications" -ForegroundColor White
Write-Host ""
Write-Host "📖 Full documentation: docs/GITHUB_ACTIONS_TELEGRAM_GUIDE.md" -ForegroundColor Cyan
Write-Host ""
Write-Host "🔗 GitHub Actions: https://github.com/$repo/actions" -ForegroundColor Blue
Write-Host ""
