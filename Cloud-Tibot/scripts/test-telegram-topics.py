#!/usr/bin/env python3
"""
Test Telegram Forum Topics Routing for Cloud-Tibot

Sends a test message to each module's forum topic to verify
that message_thread_id routing is working correctly.

Usage:
    python test-telegram-topics.py

Required: Set environment variables before running:
    $env:TELEGRAM_TOKEN = "your-bot-token"
    $env:TELEGRAM_CHAT_ID = "-100xxxxxxxxxx"
    $env:TOPIC_AUTO_REMEDIATOR = "114"
    $env:TOPIC_GIT_RADAR = "111"
    $env:TOPIC_FINOPS_SENTINEL = "your-finops-topic-id"
    $env:TOPIC_GUARDIAN_ALERT = "121"
    $env:TOPIC_PR_GUARDIAN = "118"

How to find your Topic IDs:
    1. Open Telegram Web (web.telegram.org)
    2. Click on each topic in your group
    3. Look at the URL: web.telegram.org/a/#-1003702164149_111
       The number after the underscore (111) is the topic/thread ID
"""

import os
import sys
import json
import urllib.request
from datetime import datetime


def send_telegram_message(token: str, chat_id: str, message: str, topic_id: str = "") -> dict:
    """Send a message to Telegram, optionally targeting a specific forum topic."""
    url = f"https://api.telegram.org/bot{token}/sendMessage"
    payload = {
        "chat_id": chat_id,
        "text": message,
        "parse_mode": "Markdown",
        "disable_web_page_preview": True,
    }
    if topic_id:
        payload["message_thread_id"] = int(topic_id)

    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})

    try:
        with urllib.request.urlopen(req) as resp:
            result = json.loads(resp.read().decode("utf-8"))
            return {"ok": True, "message_id": result.get("result", {}).get("message_id")}
    except urllib.error.HTTPError as e:
        error_body = e.read().decode("utf-8")
        return {"ok": False, "error": f"HTTP {e.code}: {error_body}"}
    except Exception as e:
        return {"ok": False, "error": str(e)}


def main():
    print("\n" + "=" * 60)
    print("🧪 Cloud-Tibot — Telegram Topics Routing Test")
    print("=" * 60 + "\n")

    # Load credentials
    token = os.environ.get("TELEGRAM_TOKEN", "")
    chat_id = os.environ.get("TELEGRAM_CHAT_ID", "")

    if not token or not chat_id:
        print("❌ Missing TELEGRAM_TOKEN or TELEGRAM_CHAT_ID environment variables!")
        print("\nSet them first:")
        print('  $env:TELEGRAM_TOKEN = "your-bot-token"')
        print('  $env:TELEGRAM_CHAT_ID = "-100xxxxxxxxxx"')
        sys.exit(1)

    # Define topics to test — map each module to its topic ID
    topics = {
        "CORTEX Git Radar (Module 2)": {
            "env_var": "TOPIC_GIT_RADAR",
            "emoji": "📡",
            "default": "",
        },
        "Auto-Remediator (Module 1)": {
            "env_var": "TOPIC_AUTO_REMEDIATOR",
            "emoji": "💻",
            "default": "",
        },
        "FinOps Sentinel (Module 3)": {
            "env_var": "TOPIC_FINOPS_SENTINEL",
            "emoji": "💰",
            "default": "",
        },
        "CORTEX Guardian Alert (Module 4)": {
            "env_var": "TOPIC_GUARDIAN_ALERT",
            "emoji": "💡",
            "default": "",
        },
        "PR Guardian Agent (Module 4)": {
            "env_var": "TOPIC_PR_GUARDIAN",
            "emoji": "🤖",
            "default": "",
        },
    }

    timestamp = datetime.utcnow().strftime("%Y-%m-%d %H:%M:%S UTC")
    results = []

    # First, verify bot is alive
    print("1️⃣  Verifying bot connectivity...")
    verify_url = f"https://api.telegram.org/bot{token}/getMe"
    try:
        req = urllib.request.Request(verify_url)
        with urllib.request.urlopen(req) as resp:
            bot_info = json.loads(resp.read().decode("utf-8"))
            bot_name = bot_info.get("result", {}).get("username", "unknown")
            print(f"   ✅ Bot is active: @{bot_name}\n")
    except Exception as e:
        print(f"   ❌ Bot verification failed: {e}")
        sys.exit(1)

    # Test each topic
    print("2️⃣  Sending test messages to each topic...\n")

    for module_name, config in topics.items():
        topic_id = os.environ.get(config["env_var"], config["default"])

        if not topic_id:
            print(f"   ⏭️  {module_name}: SKIPPED (no {config['env_var']} set)")
            results.append((module_name, "SKIPPED", ""))
            continue

        message = (
            f"{config['emoji']} *Topic Routing Test*\n"
            f"━━━━━━━━━━━━━━━━━━━━━━\n\n"
            f"*Module:* `{module_name}`\n"
            f"*Topic ID:* `{topic_id}`\n"
            f"*Timestamp:* `{timestamp}`\n\n"
            f"✅ This message was correctly routed to the\n"
            f"*{module_name}* forum topic.\n\n"
            f"_🧪 Test by Cloud-Tibot diagnostic script_"
        )

        result = send_telegram_message(token, chat_id, message, topic_id)

        if result["ok"]:
            print(f"   ✅ {module_name}: SENT (topic_id={topic_id}, msg_id={result['message_id']})")
            results.append((module_name, "OK", topic_id))
        else:
            print(f"   ❌ {module_name}: FAILED — {result['error']}")
            results.append((module_name, "FAILED", topic_id))

    # Also test sending to General (no topic) for comparison
    print(f"\n   📨 Testing General topic (no message_thread_id)...")
    general_msg = (
        f"📋 *Topic Routing Test — General*\n"
        f"━━━━━━━━━━━━━━━━━━━━━━\n\n"
        f"*Timestamp:* `{timestamp}`\n"
        f"This message has NO `message_thread_id`.\n"
        f"It should appear in the *General* topic.\n\n"
        f"_🧪 Test by Cloud-Tibot diagnostic script_"
    )
    general_result = send_telegram_message(token, chat_id, general_msg, "")
    if general_result["ok"]:
        print(f"   ✅ General: SENT (msg_id={general_result['message_id']})")
    else:
        print(f"   ❌ General: FAILED — {general_result['error']}")

    # Summary
    print("\n" + "=" * 60)
    print("📊 Results Summary")
    print("=" * 60)
    print(f"\n{'Module':<40} {'Status':<10} {'Topic ID'}")
    print("-" * 60)
    for name, status, tid in results:
        icon = "✅" if status == "OK" else "⏭️" if status == "SKIPPED" else "❌"
        print(f"{icon} {name:<38} {status:<10} {tid}")

    failed = [r for r in results if r[1] == "FAILED"]
    skipped = [r for r in results if r[1] == "SKIPPED"]

    print()
    if failed:
        print(f"⚠️  {len(failed)} topic(s) FAILED — check topic IDs and bot permissions")
    if skipped:
        print(f"ℹ️  {len(skipped)} topic(s) SKIPPED — set environment variables to test")
    if not failed and not skipped:
        print("🎉 All topics routed successfully!")

    print("\n💡 Tip: Check your Telegram group to verify each message")
    print("   appeared in the correct forum topic.\n")


if __name__ == "__main__":
    main()
