#!/usr/bin/env python3
"""
CORTEX Git Radar — Topic Routing Validation Script

Sends a test message to the configured Telegram forum topic
to verify message_thread_id routing works before Lambda deploy.

Usage:
    python scripts/test_topic_routing.py
    python scripts/test_topic_routing.py --topic 111   # override topic ID
    python scripts/test_topic_routing.py --all          # test ALL 5 topics
"""

import argparse
import json
import urllib.request
from datetime import datetime

# ── Configuration ──────────────────────────────────────────────────────────
TELEGRAM_TOKEN = "8281522719:AAHb8gk-sIVpjnGmOIYbE5FuzZ347J4FKTc"
TELEGRAM_CHAT_ID = "-1003702164149"

TOPICS = {
    "git_radar":        {"id": 111, "label": "📡 Cortex Git Radar"},
    "auto_remediator":  {"id": 114, "label": "🔧 Auto-Remediator"},
    "pr_guardian":      {"id": 118, "label": "🛡️ PR Guardian"},
    "guardian_alert":   {"id": 121, "label": "🚨 Guardian Alert"},
    "finops_sentinel":  {"id": 134, "label": "💰 FinOps Sentinel"},
}

DEFAULT_TOPIC = "git_radar"


def send_test_message(topic_id: int, label: str) -> bool:
    """Send a test message to a specific Telegram forum topic."""
    url = f"https://api.telegram.org/bot{TELEGRAM_TOKEN}/sendMessage"
    now = datetime.utcnow().strftime("%Y-%m-%d %H:%M:%S UTC")

    payload = {
        "chat_id": TELEGRAM_CHAT_ID,
        "text": (
            f"🧪 *Topic Routing Test*\n\n"
            f"Target: *{label}*\n"
            f"Topic ID: `{topic_id}`\n"
            f"Timestamp: `{now}`\n\n"
            f"_If you see this in the correct topic, routing is working._"
        ),
        "parse_mode": "Markdown",
        "disable_web_page_preview": True,
    }

    if topic_id:
        payload["message_thread_id"] = topic_id

    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        url, data=data, headers={"Content-Type": "application/json"}
    )

    try:
        with urllib.request.urlopen(req) as resp:
            body = json.loads(resp.read().decode("utf-8"))
            if body.get("ok"):
                msg_id = body["result"]["message_id"]
                print(f"  ✅ {label} (topic_id={topic_id}) — message_id={msg_id}")
                return True
            else:
                print(f"  ❌ {label} — API returned ok=false: {body}")
                return False
    except Exception as e:
        print(f"  ❌ {label} — Error: {e}")
        return False


def main():
    parser = argparse.ArgumentParser(description="Test Telegram topic routing")
    parser.add_argument(
        "--topic", type=int, default=None,
        help="Send to a specific topic ID (e.g. 111)"
    )
    parser.add_argument(
        "--all", action="store_true",
        help="Test ALL 5 configured topics"
    )
    parser.add_argument(
        "--name", type=str, default=None, choices=list(TOPICS.keys()),
        help="Send to a topic by name (e.g. git_radar)"
    )
    args = parser.parse_args()

    print("=" * 55)
    print("  CORTEX — Telegram Topic Routing Test")
    print("=" * 55)

    success = 0
    total = 0

    if args.all:
        # Test every topic
        for name, info in TOPICS.items():
            total += 1
            if send_test_message(info["id"], info["label"]):
                success += 1
    elif args.topic:
        # Send to a raw topic ID
        total = 1
        if send_test_message(args.topic, f"Custom (topic_id={args.topic})"):
            success = 1
    elif args.name:
        # Send by name
        info = TOPICS[args.name]
        total = 1
        if send_test_message(info["id"], info["label"]):
            success = 1
    else:
        # Default: send to Git Radar
        info = TOPICS[DEFAULT_TOPIC]
        total = 1
        print(f"\nDefault target: {info['label']} (topic_id={info['id']})\n")
        if send_test_message(info["id"], info["label"]):
            success = 1

    print(f"\nResult: {success}/{total} messages delivered successfully.")
    if success == total:
        print("🟢 All topic routing verified!\n")
    else:
        print("🔴 Some messages failed — check topic IDs and bot permissions.\n")


if __name__ == "__main__":
    main()
