#!/usr/bin/env python3
"""
Diagnostic Script for GitHub Webhook Configuration

This script helps diagnose and setup GitHub webhooks for CORTEX Git Radar.

Usage:
    # Check current webhook status (requires GitHub token)
    python scripts/check_github_webhooks.py
    
    # Setup webhook manually (requires GitHub CLI)
    python scripts/check_github_webhooks.py --setup-manual
    
Environment variables required:
    GITHUB_TOKEN: Personal access token with repo:hooks scope
    GITHUB_REPO: Repository in format owner/repo
"""

import os
import json
import sys
import subprocess
from typing import Optional, List, Dict


class GitHubWebhookDiagnostic:
    def __init__(self):
        self.github_token = os.environ.get("GITHUB_TOKEN", "")
        self.github_repo = os.environ.get("GITHUB_REPO", "Aterpise-MY/Cloud-Tibot")
        self.webhook_url = os.environ.get("GIT_RADAR_WEBHOOK_URL", "")
        
    def print_header(self, title: str):
        print(f"\n{'='*70}")
        print(f"  {title}")
        print(f"{'='*70}\n")
    
    def check_prerequisites(self) -> bool:
        """Check if we have the necessary tools and credentials."""
        self.print_header("1️⃣ Checking Prerequisites")
        
        issues = []
        
        # Check GitHub CLI
        result = subprocess.run(["which", "gh"], capture_output=True)
        if result.returncode != 0:
            issues.append("❌ GitHub CLI (gh) not found. Install from: https://cli.github.com/")
        else:
            print("✅ GitHub CLI (gh) is installed")
        
        # Check GitHub token
        if not self.github_token:
            issues.append("❌ GITHUB_TOKEN environment variable not set")
        else:
            print(f"✅ GITHUB_TOKEN is set (first 10 chars: {self.github_token[:10]}...)")
        
        # Check webhook URL
        if not self.webhook_url:
            print(f"⚠️ GIT_RADAR_WEBHOOK_URL not set")
            print(f"   (Run: terraform output -raw github_webhook_url)")
        else:
            print(f"✅ GIT_RADAR_WEBHOOK_URL is set: {self.webhook_url}")
        
        if issues:
            print("\n".join(issues))
            return False
        
        return True
    
    def list_webhooks(self) -> List[Dict]:
        """List all webhooks for the repository."""
        self.print_header("2️⃣ Listing Current Webhooks")
        
        try:
            result = subprocess.run(
                ["gh", "repo", "webhook", "list", "--repo", self.github_repo, "--json", "id,url,active,events"],
                capture_output=True,
                text=True,
                env={**os.environ, "GH_TOKEN": self.github_token}
            )
            
            if result.returncode != 0:
                print(f"❌ Failed to list webhooks: {result.stderr}")
                return []
            
            webhooks = json.loads(result.stdout) if result.stdout else []
            
            if not webhooks:
                print("ℹ️  No webhooks found for this repository")
            else:
                print(f"Found {len(webhooks)} webhook(s):\n")
                for i, webhook in enumerate(webhooks, 1):
                    status = "✅ ACTIVE" if webhook.get("active", False) else "❌ INACTIVE"
                    print(f"{i}. {status}")
                    print(f"   ID: {webhook.get('id')}")
                    print(f"   URL: {webhook.get('url')}")
                    print(f"   Events: {', '.join(webhook.get('events', []))[:60]}")
                    
                    # Check if this is our webhook
                    if webhook.get("url") and self.webhook_url and self.webhook_url in webhook.get("url", ""):
                        print(f"   ⭐ This appears to be the Git Radar webhook")
                    print()
            
            return webhooks
        
        except Exception as e:
            print(f"❌ Error listing webhooks: {e}")
            return []
    
    def check_github_webhook(self, webhooks: List[Dict]) -> bool:
        """Check if Git Radar webhook is properly configured."""
        self.print_header("3️⃣ Checking Git Radar Webhook Configuration")
        
        if not self.webhook_url:
            print("⚠️  Cannot check webhook - GIT_RADAR_WEBHOOK_URL not set")
            return False
        
        # Find webhook that matches our URL
        git_radar_webhook = None
        for webhook in webhooks:
            if self.webhook_url in webhook.get("url", ""):
                git_radar_webhook = webhook
                break
        
        if not git_radar_webhook:
            print(f"❌ Git Radar webhook not found!")
            print(f"   Looking for URL containing: {self.webhook_url}")
            print(f"\n   To setup the webhook manually, see instructions below.")
            return False
        
        print("✅ Git Radar webhook found!")
        print(f"   Webhook URL: {git_radar_webhook.get('url')}")
        print(f"   Status: {'🟢 ACTIVE' if git_radar_webhook.get('active') else '🔴 INACTIVE'}")
        
        # Check required events
        required_events = ["push", "pull_request", "workflow_run"]
        current_events = git_radar_webhook.get("events", [])
        
        print(f"\n   Events configured:")
        for event in required_events:
            status = "✅" if event in current_events else "⚠️"
            print(f"   {status} {event}")
        
        return git_radar_webhook.get("active", False)
    
    def print_setup_instructions(self):
        """Print manual setup instructions."""
        self.print_header("4️⃣ Manual Webhook Setup Instructions")
        
        if not self.webhook_url:
            print("⚠️  Cannot provide setup instructions - GIT_RADAR_WEBHOOK_URL not set")
            print("\n   First, get the webhook URL:")
            print("   $ cd infrastructure/terraform")
            print("   $ terraform output -raw github_webhook_url")
            return
        
        print("To setup the GitHub webhook manually:\n")
        print("1. Go to GitHub Repository Settings:")
        print(f"   https://github.com/{self.github_repo}/settings/hooks\n")
        
        print("2. Click 'Add webhook'\n")
        
        print("3. Configure the webhook:")
        print(f"   • Payload URL: {self.webhook_url}")
        print(f"   • Content type: application/json")
        print(f"   • Events:")
        print(f"     ✓ Push events")
        print(f"     ✓ Pull requests")
        print(f"     ✓ Workflow runs")
        print(f"     ✓ Create (for branches/tags)\n")
        
        print("4. Click 'Add webhook'\n")
        
        print("5. Verify by checking 'Recent Deliveries' tab:")
        print("   • Look for 'ping' event (initial test)")
        print("   • Status should show 200 OK\n")
        
        print("Alternative (via GitHub CLI):")
        print(f"   $ gh repo webhook create \\")
        print(f"     --repo {self.github_repo} \\")
        print(f"     --url {self.webhook_url} \\")
        print(f"     --events push,pull_request,workflow_run,create \\")
        print(f"     --active\n")
    
    def run_diagnostics(self):
        """Run all diagnostic checks."""
        print("\n🔍 CORTEX Git Radar - GitHub Webhook Diagnostic Tool")
        print("="*70)
        
        if not self.check_prerequisites():
            print("\n⚠️  Prerequisites check failed. Please install missing tools.")
            return False
        
        webhooks = self.list_webhooks()
        
        is_configured = self.check_github_webhook(webhooks)
        
        if is_configured:
            print("\n✅ GitHub webhook is properly configured and active!")
        else:
            print("\n❌ GitHub webhook is not properly configured.")
            self.print_setup_instructions()
        
        return is_configured


def main():
    import argparse
    
    parser = argparse.ArgumentParser(description="Diagnose GitHub webhook configuration")
    parser.add_argument("--repo", help="GitHub repository (owner/repo)")
    parser.add_argument("--webhook-url", help="Git Radar webhook URL")
    
    args = parser.parse_args()
    
    if args.repo:
        os.environ["GITHUB_REPO"] = args.repo
    if args.webhook_url:
        os.environ["GIT_RADAR_WEBHOOK_URL"] = args.webhook_url
    
    diagnostic = GitHubWebhookDiagnostic()
    success = diagnostic.run_diagnostics()
    
    return 0 if success else 1


if __name__ == "__main__":
    sys.exit(main())
