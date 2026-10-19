#!/usr/bin/env python3
"""
💰 CORTEX — Daily FinOps Digest
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Reports Yesterday's finalized cost (no AWS billing lag) and
the Month-to-Date running total.

Query strategy — two CE calls:
  Call 1 │ Yesterday service breakdown  (DAILY, GroupBy SERVICE)
  Call 2 │ MTD total                    (MONTHLY, no grouping)

Sends a clean digest to the FinOps Sentinel Telegram topic.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Date note: AWS Cost Explorer TimePeriod.End is *exclusive*.
  Yesterday window : Start=yesterday, End=today
  MTD window       : Start=first-of-month, End=today
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
"""

import os
import sys
import json
import boto3
import requests
from datetime import date, timedelta


# ─── Constants ────────────────────────────────────────────────────────────────

TELEGRAM_BOT_TOKEN = os.environ.get("TELEGRAM_BOT_TOKEN", "")
TELEGRAM_CHAT_ID   = os.environ.get("TELEGRAM_CHAT_ID", "")
TELEGRAM_TOPIC_ID  = os.environ.get("TELEGRAM_TOPIC_FINOPS", "")

TOP_SERVICES_SHOWN = 5      # Max top spenders displayed
MIN_COST_THRESHOLD = 0.01   # Ignore services below this (dollars)


# ─── Service emoji map ────────────────────────────────────────────────────────

_SERVICE_EMOJIS = {
    "amazon ec2":          "☁️",
    "ec2":                 "☁️",
    "aws lambda":          "⚡",
    "lambda":              "⚡",
    "amazon s3":           "🪣",
    "s3":                  "🪣",
    "amazon dynamodb":     "🗄️",
    "dynamodb":            "🗄️",
    "amazon rds":          "🐬",
    "rds":                 "🐬",
    "amazon cloudfront":   "🌐",
    "cloudfront":          "🌐",
    "amazon api gateway":  "🚪",
    "api gateway":         "🚪",
    "aws cloudtrail":      "📋",
    "cloudtrail":          "📋",
    "amazon cloudwatch":   "📊",
    "cloudwatch":          "📊",
    "amazon route 53":     "🔌",
    "route 53":            "🔌",
    "amazon sns":          "📣",
    "amazon sqs":          "📬",
    "amazon ecr":          "📦",
    "amazon ecs":          "🐳",
    "amazon eks":          "☸️",
    "amazon vpc":          "🔒",
    "aws secrets manager": "🔑",
    "aws key management":  "🔐",
    "amazon bedrock":      "🧠",
    "amazon cognito":      "🪪",
}


def service_emoji(service_name: str) -> str:
    """Return the best-match emoji for a given AWS service name."""
    key = service_name.lower()
    for pattern, emoji in _SERVICE_EMOJIS.items():
        if pattern in key:
            return emoji
    return "💸"


# ─── Date helpers ─────────────────────────────────────────────────────────────

def get_date_ranges() -> dict:
    """
    Compute all ISO date strings needed for Cost Explorer queries.

    Returns a dict with keys:
        yesterday_start  "YYYY-MM-DD"  — the day to report on
        yesterday_end    "YYYY-MM-DD"  — today (exclusive CE end)
        mtd_start        "YYYY-MM-01"  — first of current month
        today            "YYYY-MM-DD"  — exclusive end for MTD query
        yesterday_label  "YYYY-MM-DD"  — human-readable label
    """
    today     = date.today()
    yesterday = today - timedelta(days=1)
    mtd_start = today.replace(day=1)

    return {
        "yesterday_start": yesterday.isoformat(),
        "yesterday_end":   today.isoformat(),
        "mtd_start":       mtd_start.isoformat(),
        "today":           today.isoformat(),
        "yesterday_label": yesterday.strftime("%Y-%m-%d"),
    }


# ─── AWS Cost Explorer calls ──────────────────────────────────────────────────

def get_yesterday_breakdown(ce, dates: dict) -> tuple[float, list]:
    """
    Call 1: Yesterday's cost broken down by SERVICE.

    Granularity = DAILY, GroupBy = SERVICE, Metric = UnblendedCost.

    Returns:
        yesterday_total  — sum of all qualifying service costs
        top_services     — [{"name": str, "cost": float}, ...]
                           sorted descending, filtered >= MIN_COST_THRESHOLD,
                           capped at TOP_SERVICES_SHOWN
    """
    try:
        resp = ce.get_cost_and_usage(
            TimePeriod={
                "Start": dates["yesterday_start"],
                "End":   dates["yesterday_end"],
            },
            Granularity="DAILY",
            Metrics=["UnblendedCost"],
            GroupBy=[{"Type": "DIMENSION", "Key": "SERVICE"}],
        )
    except Exception as exc:
        print(f"❌ Failed to fetch yesterday's service breakdown: {exc}")
        sys.exit(1)

    service_costs: dict[str, float] = {}
    for day in resp.get("ResultsByTime", []):
        for group in day.get("Groups", []):
            svc_name = group["Keys"][0]
            amount   = float(group["Metrics"]["UnblendedCost"]["Amount"])
            if amount >= MIN_COST_THRESHOLD:
                service_costs[svc_name] = service_costs.get(svc_name, 0.0) + amount

    yesterday_total = sum(service_costs.values())
    sorted_services = sorted(service_costs.items(), key=lambda x: x[1], reverse=True)
    top_services    = [
        {"name": name, "cost": cost}
        for name, cost in sorted_services[:TOP_SERVICES_SHOWN]
    ]

    return yesterday_total, top_services


def get_mtd_total(ce, dates: dict) -> float:
    """
    Call 2: Month-to-Date total cost.

    Granularity = MONTHLY, no grouping, Metric = UnblendedCost.
    Returns total as a float (0.0 if today is the 1st — no completed day yet).
    """
    if dates["mtd_start"] == dates["today"]:
        print("   ℹ️  Today is the 1st of the month — MTD window is empty, returning $0.00")
        return 0.0

    try:
        resp = ce.get_cost_and_usage(
            TimePeriod={
                "Start": dates["mtd_start"],
                "End":   dates["today"],
            },
            Granularity="MONTHLY",
            Metrics=["UnblendedCost"],
        )
    except Exception as exc:
        print(f"⚠️  Could not fetch MTD total: {exc}")
        return 0.0

    total = sum(
        float(r["Total"]["UnblendedCost"]["Amount"])
        for r in resp.get("ResultsByTime", [])
    )
    return total


# ─── Message builder ──────────────────────────────────────────────────────────

def escape_md(text: str) -> str:
    """Escape all Telegram MarkdownV2 reserved characters."""
    special = r"_*[]()~`>#+-=|{}.!"
    for ch in special:
        text = text.replace(ch, f"\\{ch}")
    return text


def build_message(
    yesterday_label: str,
    yesterday_total: float,
    mtd_total: float,
    top_services: list,
) -> str:
    """
    Build the Telegram MarkdownV2 digest.

    Format:
      💰 *CORTEX Daily FinOps Digest*
      📅 Date: YYYY\\-MM\\-DD

      📊 *Overview:*
      • Yesterday: *$X\\.XX*
      • Month\\-to\\-Date: *$X\\.XX*

      🔍 *Top Spenders \\(Yesterday\\):*
      1\\. ☁️ Amazon EC2: *$X\\.XX*
      ...
    """
    lines = [
        "💰 *CORTEX Daily FinOps Digest*",
        f"📅 Date: {escape_md(yesterday_label)}",
        "",
        "📊 *Overview:*",
        f"• Yesterday: *${escape_md(f'{yesterday_total:.2f}')}*",
        f"• Month\\-to\\-Date: *${escape_md(f'{mtd_total:.2f}')}*",
        "",
        "🔍 *Top Spenders \\(Yesterday\\):*",
    ]

    if not top_services:
        lines.append("_No significant spend recorded for yesterday\\._")
    else:
        for i, svc in enumerate(top_services, start=1):
            emoji = service_emoji(svc["name"])
            name  = escape_md(svc["name"])
            cost  = escape_md(f"{svc['cost']:.2f}")
            lines.append(f"{i}\\. {emoji} {name}: *${cost}*")

    lines.extend([
        "",
        "📈 [AWS Cost Explorer](https://console.aws.amazon.com/cost-management/home#/dashboard)",
    ])

    return "\n".join(lines)


# ─── Telegram sender ──────────────────────────────────────────────────────────

def send_telegram(message: str) -> None:
    """Send the digest to the configured FinOps Sentinel Telegram topic."""
    if not TELEGRAM_BOT_TOKEN or not TELEGRAM_CHAT_ID:
        print("⏭️  Telegram not configured — dry-run mode")
        print("\n" + "═" * 60)
        print("DRY RUN — Message preview:")
        print("═" * 60)
        print(message)
        return

    url     = f"https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/sendMessage"
    payload: dict = {
        "chat_id":                  TELEGRAM_CHAT_ID,
        "text":                     message,
        "parse_mode":               "MarkdownV2",
        "disable_web_page_preview": True,
    }
    if TELEGRAM_TOPIC_ID:
        payload["message_thread_id"] = int(TELEGRAM_TOPIC_ID)

    try:
        resp = requests.post(url, json=payload, timeout=15)
        if resp.status_code == 200 and resp.json().get("ok"):
            print("✅ Daily FinOps Digest sent to Telegram")
        else:
            print(f"⚠️  Telegram API error {resp.status_code}: {resp.text}")
            print("\nMessage content:\n" + message)
    except requests.exceptions.RequestException as exc:
        print(f"❌ Failed to send Telegram message: {exc}")
        print("\nMessage content:\n" + message)
        sys.exit(1)


# ─── Entry point ──────────────────────────────────────────────────────────────

def main() -> None:
    print("💰 CORTEX — Daily FinOps Digest")
    print("=" * 60)

    dates = get_date_ranges()
    print(f"\n📅 Reporting date : {dates['yesterday_label']}")
    print(f"   MTD window     : {dates['mtd_start']} → {dates['today']} (exclusive)")

    # Cost Explorer is a global service; region must be us-east-1
    try:
        ce = boto3.client("ce", region_name="us-east-1")
    except Exception as exc:
        print(f"❌ Failed to initialise boto3 CE client: {exc}")
        sys.exit(1)

    # ── Call 1: Yesterday's service breakdown ─────────────────────────────────
    print("\n📊 Fetching yesterday's service breakdown…")
    yesterday_total, top_services = get_yesterday_breakdown(ce, dates)
    print(f"   → Yesterday total     : ${yesterday_total:.2f}")
    print(f"   → Qualifying services : {len(top_services)}")
    for svc in top_services:
        print(f"      {service_emoji(svc['name'])} {svc['name']}: ${svc['cost']:.2f}")

    # ── Call 2: MTD total ─────────────────────────────────────────────────────
    print("\n📈 Fetching Month-to-Date total…")
    mtd_total = get_mtd_total(ce, dates)
    print(f"   → MTD total: ${mtd_total:.2f}")

    # ── Build & send ──────────────────────────────────────────────────────────
    print("\n📨 Building Telegram message…")
    message = build_message(
        yesterday_label=dates["yesterday_label"],
        yesterday_total=yesterday_total,
        mtd_total=mtd_total,
        top_services=top_services,
    )

    print("📤 Sending to Telegram…")
    send_telegram(message)

    print("\n✅ Done.")


if __name__ == "__main__":
    main()
