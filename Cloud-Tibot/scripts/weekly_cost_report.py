#!/usr/bin/env python3
"""
💰 FinOps Sentinel — Weekly Deep Dive Cost Report
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Queries AWS Cost Explorer for the current & previous 7-day windows,
computes a per-service Week-over-Week (WoW) delta, and sends a rich
Markdown digest to the FinOps Sentinel Telegram topic.

Environment Variables (injected by GitHub Actions):
  AWS_ACCESS_KEY_ID          — AWS credentials (via aws-actions/configure-aws-credentials)
  AWS_SECRET_ACCESS_KEY      — AWS credentials
  AWS_DEFAULT_REGION         — Target region (default: us-east-1)
  TELEGRAM_BOT_TOKEN         — Bot token
  TELEGRAM_CHAT_ID           — Supergroup / channel chat ID
  TELEGRAM_TOPIC_FINOPS      — Thread / topic ID (optional)
  GITHUB_REPOSITORY          — Injected automatically by Actions
  GITHUB_RUN_ID              — Injected automatically by Actions
"""

from __future__ import annotations

import os
import sys
import logging
from datetime import date, timedelta
from typing import Optional

import boto3
import requests
from tabulate import tabulate

# ─── Logging ──────────────────────────────────────────────────────────────────

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-8s  %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
log = logging.getLogger(__name__)

# ─── Configuration ────────────────────────────────────────────────────────────

AWS_REGION         = os.environ.get("AWS_DEFAULT_REGION", "us-east-1")
TELEGRAM_BOT_TOKEN = os.environ.get("TELEGRAM_BOT_TOKEN", "")
TELEGRAM_CHAT_ID   = os.environ.get("TELEGRAM_CHAT_ID", "")
TELEGRAM_TOPIC_ID  = os.environ.get("TELEGRAM_TOPIC_FINOPS", "")
GITHUB_REPO        = os.environ.get("GITHUB_REPOSITORY", "")
GITHUB_RUN_ID      = os.environ.get("GITHUB_RUN_ID", "")

# Tuning knobs
TOP_SERVICES_SHOWN  = 12    # Max rows in the breakdown table
MIN_COST_THRESHOLD  = 0.001 # USD — ignore services below this
ALERT_THRESHOLD_USD = 10.0  # Weekly total that triggers a cost alert
WOW_SPIKE_PCT       = 50.0  # % growth that flags a service as a spike

# ─── Service emoji map ────────────────────────────────────────────────────────

_SERVICE_EMOJIS: dict[str, str] = {
    "amazon ec2":                        "☁️",
    "aws lambda":                        "⚡",
    "amazon s3":                         "🪣",
    "amazon dynamodb":                   "🗄️",
    "amazon rds":                        "🐬",
    "amazon cloudfront":                 "🌐",
    "amazon api gateway":                "🚪",
    "amazon sns":                        "📣",
    "amazon sqs":                        "📨",
    "amazon cloudwatch":                 "📊",
    "aws cloudtrail":                    "📋",
    "amazon route 53":                   "🔀",
    "aws key management service":        "🔑",
    "amazon elastic container service":  "🐳",
    "aws fargate":                       "🐳",
    "amazon ecr":                        "📦",
    "amazon cognito":                    "👤",
    "amazon secrets manager":            "🔒",
    "aws systems manager":               "🛠️",
    "amazon vpc":                        "🔗",
    "amazon elb":                        "⚖️",
    "elastic load balancing":            "⚖️",
    "amazon opensearch service":         "🔍",
    "amazon kinesis":                    "🔄",
    "aws glue":                          "🧩",
    "amazon athena":                     "🔬",
    "amazon redshift":                   "🏗️",
    "tax":                               "🏛️",
}


def _service_emoji(name: str) -> str:
    return _SERVICE_EMOJIS.get(name.lower(), "💠")


# ─── AWS helpers ──────────────────────────────────────────────────────────────

def get_cost_by_service(
    ce_client,
    start: date,
    end: date,
) -> dict[str, float]:
    """
    Return {service_name: total_blended_cost_usd} for the given period.
    Uses DAILY granularity and groups by SERVICE dimension.
    """
    log.info("Querying CE: %s → %s", start, end)
    paginator = ce_client.get_paginator("get_cost_and_usage")
    pages = paginator.paginate(
        TimePeriod={
            "Start": start.isoformat(),
            "End":   end.isoformat(),
        },
        Granularity="DAILY",
        Metrics=["BlendedCost"],
        GroupBy=[{"Type": "DIMENSION", "Key": "SERVICE"}],
    )

    totals: dict[str, float] = {}
    for page in pages:
        for day in page["ResultsByTime"]:
            for group in day["Groups"]:
                svc   = group["Keys"][0]
                amt   = float(group["Metrics"]["BlendedCost"]["Amount"])
                totals[svc] = totals.get(svc, 0.0) + amt

    return totals


def get_lambda_invocations(cw_client, start: date, end: date) -> int:
    """Return total Lambda invocations for the period via CloudWatch."""
    try:
        resp = cw_client.get_metric_statistics(
            Namespace="AWS/Lambda",
            MetricName="Invocations",
            StartTime=f"{start}T00:00:00Z",
            EndTime=f"{end}T23:59:59Z",
            Period=604800,
            Statistics=["Sum"],
        )
        datapoints = resp.get("Datapoints", [])
        return int(sum(dp["Sum"] for dp in datapoints))
    except Exception as exc:  # noqa: BLE001
        log.warning("CloudWatch Lambda query failed: %s", exc)
        return 0


# ─── Data processing ──────────────────────────────────────────────────────────

def build_comparison_table(
    current: dict[str, float],
    previous: dict[str, float],
) -> list[dict]:
    """
    Merge current & previous week data into a list of rows, sorted by
    current-week cost descending.  Filters out sub-threshold services.

    Each row: {service, current, previous, delta, pct, spike}
    """
    all_services = set(current) | set(previous)
    rows = []

    for svc in all_services:
        curr_cost = current.get(svc, 0.0)
        prev_cost = previous.get(svc, 0.0)

        # Skip noise
        if curr_cost < MIN_COST_THRESHOLD and prev_cost < MIN_COST_THRESHOLD:
            continue

        delta = curr_cost - prev_cost
        if prev_cost > 0:
            pct = (delta / prev_cost) * 100
        elif curr_cost > 0:
            pct = 100.0   # new service this week
        else:
            pct = 0.0

        rows.append({
            "service":  svc,
            "current":  curr_cost,
            "previous": prev_cost,
            "delta":    delta,
            "pct":      pct,
            "spike":    pct >= WOW_SPIKE_PCT and delta > 0.10,
        })

    rows.sort(key=lambda r: r["current"], reverse=True)
    return rows


# ─── Message formatting ───────────────────────────────────────────────────────

def _delta_str(delta: float, pct: float) -> str:
    """Human-readable delta with direction arrow."""
    arrow = "🔺" if delta > 0.005 else ("🔻" if delta < -0.005 else "➡️")
    sign  = "+" if delta >= 0 else ""
    return f"{arrow} {sign}{delta:.2f} ({sign}{pct:.0f}%)"


def build_telegram_message(
    rows: list[dict],
    current_total: float,
    previous_total: float,
    lambda_invocations: int,
    week_end: date,
) -> str:
    """Compose the full Markdown message for Telegram."""

    total_delta    = current_total - previous_total
    total_pct      = ((total_delta / previous_total) * 100) if previous_total > 0 else 0.0
    total_arrow    = "🔺" if total_delta > 0.005 else ("🔻" if total_delta < -0.005 else "➡️")
    total_sign     = "+" if total_delta >= 0 else ""

    week_start     = week_end - timedelta(days=7)
    prev_week_start = week_start - timedelta(days=7)

    alert_block = ""
    if current_total > ALERT_THRESHOLD_USD:
        alert_block = f"\n⚠️ *Cost Alert:* Weekly spend exceeds ${ALERT_THRESHOLD_USD:.0f}!\n"

    # ── Header ────────────────────────────────────────────────────────────────
    lines = [
        "💰 *DND Platform — Weekly Deep Dive*",
        "",
        f"📅 *Period:* `{week_start}` → `{week_end}`",
        f"📅 *vs prior:* `{prev_week_start}` → `{week_start}`",
        "",
        "─────────────────────────",
        "*📊 Account Summary*",
        f"💵 This week:   `${current_total:.2f}`",
        f"💵 Last week:   `${previous_total:.2f}`",
        f"📈 WoW change: `{total_sign}{total_delta:.2f}` ({total_sign}{total_pct:.0f}%) {total_arrow}",
        f"⚡ Lambda calls: `{lambda_invocations:,}`",
        alert_block,
        "─────────────────────────",
        "*🔍 Service Breakdown (Top services)*",
        "",
    ]

    # ── Per-service table ─────────────────────────────────────────────────────
    display_rows = rows[:TOP_SERVICES_SHOWN]

    for r in display_rows:
        emoji    = _service_emoji(r["service"])
        spike    = " 🚨" if r["spike"] else ""
        svc_name = r["service"]
        curr_str = f"${r['current']:.3f}"
        wow_str  = _delta_str(r["delta"], r["pct"])
        lines.append(f"{emoji} *{svc_name}*{spike}")
        lines.append(f"   Current: `{curr_str}`  {wow_str}")

    # Remainder rolled up
    if len(rows) > TOP_SERVICES_SHOWN:
        rest_cost = sum(r["current"] for r in rows[TOP_SERVICES_SHOWN:])
        lines.append(f"💠 *Other ({len(rows) - TOP_SERVICES_SHOWN} services)*")
        lines.append(f"   Current: `${rest_cost:.3f}`")

    # ── Spike callouts ────────────────────────────────────────────────────────
    spikes = [r for r in rows if r["spike"]]
    if spikes:
        lines += [
            "",
            "─────────────────────────",
            "🚨 *WoW Spikes (>{}% growth)*".format(int(WOW_SPIKE_PCT)),
        ]
        for r in spikes[:5]:
            lines.append(
                f"  • {_service_emoji(r['service'])} {r['service']}: "
                f"`+${r['delta']:.3f}` (+{r['pct']:.0f}%)"
            )

    # ── Footer ────────────────────────────────────────────────────────────────
    lines += [
        "",
        "─────────────────────────",
    ]
    if GITHUB_REPO and GITHUB_RUN_ID:
        lines.append(
            f"📊 [AWS Cost Explorer](https://console.aws.amazon.com/cost-management/home#/dashboard)  "
            f"🔗 [Workflow](https://github.com/{GITHUB_REPO}/actions/runs/{GITHUB_RUN_ID})"
        )
    else:
        lines.append(
            "📊 [AWS Cost Explorer](https://console.aws.amazon.com/cost-management/home#/dashboard)"
        )

    return "\n".join(lines)


# ─── Telegram sender ──────────────────────────────────────────────────────────

def send_telegram(message: str) -> bool:
    """POST the message to the Telegram Bot API.  Returns True on success."""
    if not TELEGRAM_BOT_TOKEN or not TELEGRAM_CHAT_ID:
        log.warning("Telegram not configured — skipping send.")
        return False

    payload: dict = {
        "chat_id":                  TELEGRAM_CHAT_ID,
        "text":                     message,
        "parse_mode":               "Markdown",
        "disable_web_page_preview": True,
    }
    if TELEGRAM_TOPIC_ID:
        try:
            payload["message_thread_id"] = int(TELEGRAM_TOPIC_ID)
        except ValueError:
            log.warning("TELEGRAM_TOPIC_FINOPS is not a valid integer: %s", TELEGRAM_TOPIC_ID)

    url = f"https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/sendMessage"
    try:
        resp = requests.post(url, json=payload, timeout=15)
        resp.raise_for_status()
        log.info("Telegram message sent (ok=%s)", resp.json().get("ok"))
        return True
    except requests.RequestException as exc:
        log.error("Telegram send failed: %s", exc)
        return False


# ─── Entry point ──────────────────────────────────────────────────────────────

def main() -> int:
    today      = date.today()
    # Current window: last 7 complete days (yesterday back 7 days)
    # CE end date is exclusive, so we use today as end to include yesterday
    curr_end   = today
    curr_start = today - timedelta(days=7)

    # Previous window: the 7 days before current window
    prev_end   = curr_start
    prev_start = curr_start - timedelta(days=7)

    log.info("Current week:  %s → %s", curr_start, curr_end)
    log.info("Previous week: %s → %s", prev_start, prev_end)

    # ── AWS clients ───────────────────────────────────────────────────────────
    session    = boto3.Session(region_name=AWS_REGION)
    ce_client  = session.client("ce",         region_name="us-east-1")   # CE is global
    cw_client  = session.client("cloudwatch", region_name=AWS_REGION)

    # ── Fetch data ────────────────────────────────────────────────────────────
    try:
        current_costs  = get_cost_by_service(ce_client, curr_start,  curr_end)
        previous_costs = get_cost_by_service(ce_client, prev_start,  prev_end)
    except Exception as exc:  # noqa: BLE001
        log.error("Fatal: Could not query Cost Explorer: %s", exc)
        return 1

    lambda_invocations = get_lambda_invocations(cw_client, curr_start, curr_end)

    # ── Process ───────────────────────────────────────────────────────────────
    rows           = build_comparison_table(current_costs, previous_costs)
    current_total  = sum(current_costs.values())
    previous_total = sum(previous_costs.values())

    log.info(
        "This week: $%.2f | Last week: $%.2f | Services: %d",
        current_total, previous_total, len(rows),
    )

    # ── Print ASCII table to Actions log ─────────────────────────────────────
    table_data = [
        [
            r["service"][:40],
            f"${r['current']:.3f}",
            f"${r['previous']:.3f}",
            f"{'+'if r['delta']>=0 else ''}{r['delta']:.3f}",
            f"{'+'if r['pct']>=0 else ''}{r['pct']:.1f}%",
            "🚨" if r["spike"] else "",
        ]
        for r in rows
    ]
    print(tabulate(
        table_data,
        headers=["Service", "This Week", "Last Week", "Delta $", "WoW %", ""],
        tablefmt="github",
    ))

    # ── Build & send Telegram message ─────────────────────────────────────────
    message = build_telegram_message(
        rows               = rows,
        current_total      = current_total,
        previous_total     = previous_total,
        lambda_invocations = lambda_invocations,
        week_end           = curr_end,
    )

    log.info("Message length: %d chars", len(message))
    success = send_telegram(message)
    return 0 if success else 1


if __name__ == "__main__":
    sys.exit(main())
