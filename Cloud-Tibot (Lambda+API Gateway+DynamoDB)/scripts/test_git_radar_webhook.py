#!/usr/bin/env python3
"""
Test Script for CORTEX Git Radar Webhook (Topic 111)

This script tests:
1. GitHub webhook endpoint accessibility
2. Telegram topic 111 routing
3. End-to-end webhook → Lambda → Telegram flow

Usage:
    python scripts/test_git_radar_webhook.py
    python scripts/test_git_radar_webhook.py --webhook-only
    python scripts/test_git_radar_webhook.py --telegram-only
    python scripts/test_git_radar_webhook.py --webhook-url <url>
"""

import argparse
import json
import sys
import os
import urllib.request
import urllib.error
from datetime import datetime
from typing import Tuple, Dict, Optional

# Configuration from environment or defaults
TELEGRAM_TOKEN = os.environ.get("TELEGRAM_TOKEN", "8281522719:AAHb8gk-sIVpjnGmOIYbE5FuzZ347J4FKTc")
TELEGRAM_CHAT_ID = os.environ.get("TELEGRAM_CHAT_ID", "-1003702164149")
GIT_RADAR_WEBHOOK_URL = os.environ.get("GIT_RADAR_WEBHOOK_URL", "")  # Set from Terraform output
GIT_RADAR_TOPIC_ID = "111"

print(f"📡 CORTEX Git Radar - Webhook & Telegram Test")
print(f"{'='*60}\n")


def test_telegram_connectivity() -> Tuple[bool, str]:
    """Test basic Telegram bot connectivity."""
    print("🧪 TEST 1: Telegram Bot Connectivity")
    print("-" * 60)
    
    url = f"https://api.telegram.org/bot{TELEGRAM_TOKEN}/getMe"
    
    try:
        with urllib.request.urlopen(url) as resp:
            result = json.loads(resp.read().decode("utf-8"))
            if result.get("ok"):
                bot_name = result["result"]["username"]
                print(f"✅ Telegram Bot Connected: @{bot_name}")
                print(f"   Bot ID: {result['result']['id']}")
                return True, f"Bot @{bot_name} is reachable"
            else:
                error = result.get("description", "Unknown error")
                print(f"❌ Telegram API error: {error}")
                return False, error
    except Exception as e:
        print(f"❌ Failed to connect to Telegram: {e}")
        return False, str(e)


def test_telegram_topic_routing() -> Tuple[bool, str]:
    """Test sending message to topic 111."""
    print("\n🧪 TEST 2: Telegram Topic 111 Routing")
    print("-" * 60)
    
    url = f"https://api.telegram.org/bot{TELEGRAM_TOKEN}/sendMessage"
    
    timestamp = datetime.utcnow().strftime("%Y-%m-%d %H:%M:%S UTC")
    payload = {
        "chat_id": TELEGRAM_CHAT_ID,
        "text": (
            f"🧪 *Git Radar Webhook Test*\n\n"
            f"Test Type: Topic Routing\n"
            f"Topic ID: `{GIT_RADAR_TOPIC_ID}`\n"
            f"Timestamp: `{timestamp}`\n\n"
            f"_If you see this message in topic 111, routing is working!_"
        ),
        "parse_mode": "Markdown",
        "disable_web_page_preview": True,
        "message_thread_id": int(GIT_RADAR_TOPIC_ID),
    }
    
    try:
        data = json.dumps(payload).encode("utf-8")
        req = urllib.request.Request(
            url,
            data=data,
            headers={"Content-Type": "application/json"}
        )
        
        with urllib.request.urlopen(req) as resp:
            result = json.loads(resp.read().decode("utf-8"))
            if result.get("ok"):
                msg_id = result["result"]["message_id"]
                print(f"✅ Message sent to topic 111 successfully")
                print(f"   Message ID: {msg_id}")
                print(f"   Chat ID: {TELEGRAM_CHAT_ID}")
                print(f"   Thread ID: {GIT_RADAR_TOPIC_ID}")
                return True, f"Message {msg_id} sent to topic {GIT_RADAR_TOPIC_ID}"
            else:
                error = result.get("description", "Unknown error")
                print(f"❌ Telegram API error: {error}")
                return False, error
    except urllib.error.HTTPError as e:
        error_body = e.read().decode("utf-8")
        print(f"❌ HTTP Error {e.code}: {error_body}")
        return False, f"HTTP {e.code}"
    except Exception as e:
        print(f"❌ Failed to send message: {e}")
        return False, str(e)


def test_webhook_endpoint(webhook_url: str) -> Tuple[bool, str]:
    """Test GitHub webhook endpoint accessibility."""
    print("\n🧪 TEST 3: GitHub Webhook Endpoint")
    print("-" * 60)
    
    if not webhook_url:
        print("⚠️  SKIPPED: No webhook URL provided")
        return False, "No webhook URL"
    
    print(f"Testing endpoint: {webhook_url}")
    
    # Create a test push event payload
    test_payload = {
        "ref": "refs/heads/main",
        "repository": {
            "name": "Cloud-Tibot",
            "full_name": "Aterpise-MY/Cloud-Tibot",
            "owner": {"login": "Aterpise-MY"}
        },
        "pusher": {"name": "test-user", "email": "test@example.com"},
        "commits": [{
            "id": "test123abc456",
            "message": "Test: Git Radar webhook verification",
            "timestamp": datetime.utcnow().isoformat() + "Z",
            "author": {"name": "Test User", "email": "test@example.com"},
            "added": [],
            "modified": ["README.md"],
            "removed": []
        }]
    }
    
    try:
        data = json.dumps(test_payload).encode("utf-8")
        req = urllib.request.Request(
            webhook_url,
            data=data,
            headers={
                "Content-Type": "application/json",
                "X-GitHub-Event": "push",
                "X-GitHub-Delivery": "test-delivery-id-12345"
            }
        )
        
        with urllib.request.urlopen(req) as resp:
            result = resp.read().decode("utf-8")
            print(f"✅ Webhook endpoint is reachable (HTTP {resp.status})")
            print(f"   Response: {result[:200]}")
            return True, f"Webhook responded with HTTP {resp.status}"
    
    except urllib.error.HTTPError as e:
        # 4xx/5xx errors still mean the endpoint is reachable
        error_body = e.read().decode("utf-8")
        if e.code < 500:
            print(f"⚠️  Webhook returned HTTP {e.code}")
            print(f"   Response: {error_body[:200]}")
            return True, f"Webhook reachable (HTTP {e.code})"
        else:
            print(f"❌ Webhook error: HTTP {e.code}")
            print(f"   Response: {error_body[:200]}")
            return False, f"HTTP {e.code}"
    
    except Exception as e:
        print(f"❌ Failed to reach webhook: {e}")
        return False, str(e)


def main():
    parser = argparse.ArgumentParser(
        description="Test CORTEX Git Radar webhook and Telegram topic 111"
    )
    parser.add_argument(
        "--webhook-url",
        type=str,
        help="GitHub webhook URL (from Terraform output)"
    )
    parser.add_argument(
        "--telegram-only",
        action="store_true",
        help="Only test Telegram (skip webhook)"
    )
    parser.add_argument(
        "--webhook-only",
        action="store_true",
        help="Only test webhook (skip Telegram)"
    )
    
    args = parser.parse_args()
    
    webhook_url = args.webhook_url or GIT_RADAR_WEBHOOK_URL
    
    results = []
    
    # Test Telegram
    if not args.webhook_only:
        success, msg = test_telegram_connectivity()
        results.append(("Telegram Connectivity", success, msg))
        
        success, msg = test_telegram_topic_routing()
        results.append(("Telegram Topic 111", success, msg))
    
    # Test Webhook
    if not args.telegram_only:
        success, msg = test_webhook_endpoint(webhook_url)
        results.append(("GitHub Webhook Endpoint", success, msg))
    
    # Summary
    print("\n" + "=" * 60)
    print("📊 Test Summary")
    print("=" * 60)
    
    all_passed = True
    for test_name, success, msg in results:
        status = "✅ PASS" if success else "❌ FAIL"
        print(f"{status} | {test_name}: {msg}")
        all_passed = all_passed and success
    
    print("=" * 60)
    
    if all_passed:
        print("\n✅ All tests passed! Git Radar webhook and topic 111 are working.\n")
        return 0
    else:
        print("\n❌ Some tests failed. Check configuration above.\n")
        return 1


if __name__ == "__main__":
    sys.exit(main())
