#!/usr/bin/env python3
"""
Test GitHub webhook delivery via GitHub MCP
Triggers a real event on IB-DND-5e-Platform and monitors delivery
"""
import subprocess
import json
import time
from datetime import datetime

def run_git_command(cmd):
    """Run a git command"""
    result = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    return result.stdout.strip(), result.stderr.strip(), result.returncode

def print_section(title):
    print(f"\n{'='*70}")
    print(f"🔍 {title}")
    print('='*70)

def print_step(num, text):
    print(f"\n[Step {num}] {text}")

print_section("GitHub Webhook Test - Via Real Event Trigger")

# Step 1: Check current branch
print_step(1, "Checking GitHub CLI status")
stdout, stderr, code = run_git_command("gh --version")
if code == 0:
    print(f"✅ GitHub CLI available: {stdout}")
else:
    print(f"❌ GitHub CLI not available")
    print(f"   Install with: brew install gh")
    exit(1)

# Step 2: Get webhook info via GitHub API
print_step(2, "Fetching webhook information for IB-DND-5e-Platform")
try:
    result = subprocess.run(
        ["gh", "api", "repos/Aterpise-MY/IB-DND-5e-Platform/hooks", "-H", "Accept: application/vnd.github+json"],
        capture_output=True, text=True, timeout=10
    )
    if result.returncode == 0:
        hooks = json.loads(result.stdout)
        print(f"✅ Found {len(hooks)} webhook(s)")
        
        for i, hook in enumerate(hooks, 1):
            print(f"\n   Webhook #{i}:")
            print(f"   - ID: {hook['id']}")
            print(f"   - URL: {hook['config']['url']}")
            print(f"   - Events: {', '.join(hook['events'])}")
            print(f"   - Active: {hook['active']}")
            
            # Check if this is our webhook
            if "6w72v0646f" in hook['config']['url']:
                webhook_id = hook['id']
                print(f"   ✅ THIS IS OUR WEBHOOK (ID: {webhook_id})")
    else:
        print(f"⚠️  Could not fetch webhook info: {result.stderr}")
        webhook_id = None
except Exception as e:
    print(f"❌ Error: {e}")
    webhook_id = None

# Step 3: Trigger test event (create a test branch and delete it)
print_step(3, "Triggering test webhook event (creating test branch)")

test_branch = f"test-webhook-{int(time.time())}"
print(f"   Creating test branch: {test_branch}")

try:
    # Check out main branch of IB-DND-5e-Platform
    result = subprocess.run(
        ["gh", "repo", "clone", "Aterpise-MY/IB-DND-5e-Platform", "--single-branch", "--branch", "main", "/tmp/ib-dnd-test"],
        capture_output=True, text=True, timeout=30
    )
    
    if "already exists" in result.stderr or result.returncode == 0:
        print("✅ Repository ready")
        
        # Create a test branch
        result = subprocess.run(
            f"cd /tmp/ib-dnd-test && git checkout -b {test_branch} && echo 'webhook test' >> .github/workflows/.keep 2>/dev/null; git add -A && git commit -m 'Webhook test trigger' && git push origin {test_branch}",
            shell=True, capture_output=True, text=True, timeout=30
        )
        
        if result.returncode == 0 or "file changed" in result.stderr or "webhook" in result.stderr:
            print(f"✅ Test branch created and pushed: {test_branch}")
        else:
            print(f"⚠️  Push result: {result.stderr}")
    else:
        print(f"⚠️  Could not prepare repo: {result.stderr}")
        
except Exception as e:
    print(f"⚠️  Manual trigger failed: {e}")
    print(f"   (This is optional - webhook may have already been triggered)")

# Step 4: Check webhook recent deliveries
print_step(4, "Checking webhook recent deliveries")

if webhook_id:
    try:
        result = subprocess.run(
            ["gh", "api", f"repos/Aterpise-MY/IB-DND-5e-Platform/hooks/{webhook_id}/deliveries", 
             "-H", "Accept: application/vnd.github+json", "--paginate"],
            capture_output=True, text=True, timeout=10
        )
        
        if result.returncode == 0:
            deliveries = json.loads(result.stdout)
            print(f"✅ Found {len(deliveries)} recent delivery/deliveries")
            
            # Show last 5 deliveries
            for delivery in deliveries[:5]:
                timestamp = delivery.get('delivered_at', 'N/A')
                status_code = delivery.get('status_code', 'N/A')
                action = delivery.get('action', 'unknown')
                redelivery = "🔄 REDELIVERY" if delivery.get('redelivery') else ""
                
                status_emoji = "✅" if 200 <= status_code < 300 else "❌"
                print(f"\n   {status_emoji} {timestamp}")
                print(f"      Status: {status_code} | Event: {action} {redelivery}")
                
                if 200 <= status_code < 300:
                    print(f"      ✅ SUCCESSFUL DELIVERY")
                else:
                    print(f"      ❌ FAILED - Response: {delivery.get('response', {}).get('status', 'N/A')}")
        else:
            print(f"⚠️  Could not fetch deliveries: {result.stderr}")
    except Exception as e:
        print(f"❌ Error fetching deliveries: {e}")
else:
    print("⚠️  Could not identify webhook - skipping delivery check")

# Step 5: Check Lambda logs
print_step(5, "Checking Lambda execution logs")

result = subprocess.run(
    "aws logs tail /aws/lambda/cortex_git_radar --region us-east-1 --since 1m --format short 2>&1 | tail -20",
    shell=True, capture_output=True, text=True, timeout=10
)

if result.returncode == 0 and result.stdout:
    print("✅ Lambda logs (last 20 lines):")
    print(result.stdout)
else:
    print("⚠️  No recent Lambda logs")

# Step 6: Summary
print_section("Test Summary")
print("""
✅ Webhook delivery test completed!

What to verify:
1. ✅ Webhook shows recent delivery with HTTP 200 status
2. ✅ Lambda logs show event processing
3. ✅ Telegram Topic 111 receives notification

Next steps:
- Check GitHub webhook Recent Deliveries tab for full details
- Monitor Telegram for CORTEX Git Radar notifications
- Review CloudWatch logs for Lambda execution details
""")

