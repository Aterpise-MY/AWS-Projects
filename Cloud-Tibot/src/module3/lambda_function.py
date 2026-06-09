"""
Project CORTEX - Module 3: FinOps Sentinel
AI-Powered Cloud Cost Optimization & Infrastructure Fix Agent

Handles cost alerts via API Gateway webhooks.
Uses GitHub Copilot SDK as an AI agent to:
  1. Analyze cost anomalies and identify wasteful resources
  2. Generate Terraform changes to right-size infrastructure
  3. Create PRs with cost optimization fixes (resize, scale-down, cleanup)
  4. Detect failed Terraform deployments and auto-remediate
  5. Notify the team on Telegram with cost analysis & action taken
"""

import json
import os
import base64
import urllib3
import boto3
from datetime import datetime, date, timedelta

# ---------------------------------------------------------------------------
# FinOps Scheduled Report — Constants
# ---------------------------------------------------------------------------

_SERVICE_EMOJIS = {
    "amazon lightsail":                    "🪩",
    "aws app runner":                      "🏃",
    "amazon ec2":                          "☁️",
    "ec2 - other":                         "☁️",
    "aws lambda":                          "⚡",
    "amazon s3":                           "🪣",
    "amazon dynamodb":                     "🗄️",
    "amazon rds":                          "🐬",
    "amazon cloudfront":                   "🌐",
    "amazon api gateway":                  "🚪",
    "amazon sns":                          "📣",
    "amazon sqs":                          "📨",
    "amazon cloudwatch":                   "📊",
    "aws cloudtrail":                      "📋",
    "amazon route 53":                     "🔀",
    "aws key management service":          "🔑",
    "amazon elastic container service":    "🐳",
    "aws fargate":                         "🐳",
    "amazon ecr":                          "📦",
    "amazon cognito":                      "👤",
    "amazon secrets manager":              "🔒",
    "aws systems manager":                 "🛠️",
    "amazon vpc":                          "🔗",
    "elastic load balancing":              "⚖️",
    "amazon opensearch service":           "🔍",
    "amazon kinesis":                      "🔄",
    "tax":                                 "🏛️",
}

_MIN_COST     = 0.001   # USD — filter sub-threshold services
_TOP_SERVICES = 12      # max rows in breakdown
_DRILLDOWN_N  = 5       # top N services to show resource names
_RESOURCE_N   = 4       # max resources shown per service
_SPIKE_PCT    = 50.0    # WoW % growth that triggers spike alert
_SPIKE_ABS    = 0.10    # min absolute delta ($) to flag as spike
_ALERT_USD    = 30.0    # weekly total that triggers cost alert


def _service_emoji(name: str) -> str:
    return _SERVICE_EMOJIS.get(name.lower(), "💠")


# ---------------------------------------------------------------------------
# FinOps Scheduled Report — AWS Data Helpers
# ---------------------------------------------------------------------------

def _get_cost_by_service(ce, start: date, end: date) -> dict:
    """Return {service_name: total_usd} for the period (DAILY granularity)."""
    totals = {}
    kwargs = dict(
        TimePeriod={"Start": start.isoformat(), "End": end.isoformat()},
        Granularity="DAILY",
        Metrics=["BlendedCost"],
        GroupBy=[{"Type": "DIMENSION", "Key": "SERVICE"}],
    )
    while True:
        resp = ce.get_cost_and_usage(**kwargs)
        for day in resp["ResultsByTime"]:
            for grp in day["Groups"]:
                svc = grp["Keys"][0]
                amt = float(grp["Metrics"]["BlendedCost"]["Amount"])
                totals[svc] = totals.get(svc, 0.0) + amt
        token = resp.get("NextPageToken")
        if not token:
            break
        kwargs["NextPageToken"] = token
    return totals


def _get_resources_for_service(ce, service_name: str, start: date, end: date) -> list:
    """Return top resources [{name, cost}] for one service. Falls back gracefully."""
    try:
        resp = ce.get_cost_and_usage(
            TimePeriod={"Start": start.isoformat(), "End": end.isoformat()},
            Granularity="DAILY",
            Metrics=["BlendedCost"],
            Filter={"Dimensions": {"Key": "SERVICE", "Values": [service_name]}},
            GroupBy=[{"Type": "DIMENSION", "Key": "RESOURCE_ID"}],
        )
        totals = {}
        for day in resp["ResultsByTime"]:
            for grp in day["Groups"]:
                rid = grp["Keys"][0] or "(untagged)"
                amt = float(grp["Metrics"]["BlendedCost"]["Amount"])
                totals[rid] = totals.get(rid, 0.0) + amt
        if not totals:
            return []
        rows = sorted(totals.items(), key=lambda x: x[1], reverse=True)
        return [{"name": r[0], "cost": r[1]} for r in rows if r[1] >= _MIN_COST]
    except Exception as exc:
        print(f"Resource drill-down unavailable for {service_name}: {exc}")
        return []


def _get_lambda_invocations(cw, start: date, end: date) -> int:
    """Total Lambda invocations from CloudWatch for the period."""
    try:
        resp = cw.get_metric_statistics(
            Namespace="AWS/Lambda",
            MetricName="Invocations",
            StartTime=f"{start}T00:00:00Z",
            EndTime=f"{end}T23:59:59Z",
            Period=604800,
            Statistics=["Sum"],
        )
        return int(sum(dp["Sum"] for dp in resp.get("Datapoints", [])))
    except Exception as exc:
        print(f"Lambda invocations query failed: {exc}")
        return 0


def _build_comparison_table(current: dict, previous: dict) -> list:
    """Merge dicts into sorted rows with delta & WoW % per service."""
    rows = []
    for svc in set(current) | set(previous):
        curr = current.get(svc, 0.0)
        prev = previous.get(svc, 0.0)
        if curr < _MIN_COST and prev < _MIN_COST:
            continue
        delta = curr - prev
        pct   = (delta / prev * 100) if prev > 0 else (100.0 if curr > 0 else 0.0)
        rows.append({
            "service":  svc,
            "current":  curr,
            "previous": prev,
            "delta":    delta,
            "pct":      pct,
            "spike":    pct >= _SPIKE_PCT and delta > _SPIKE_ABS,
        })
    rows.sort(key=lambda r: r["current"], reverse=True)
    return rows


def _delta_str(delta: float, pct: float) -> str:
    arrow = "🔺" if delta > 0.005 else ("🔻" if delta < -0.005 else "➡️")
    sign  = "+" if delta >= 0 else ""
    return f"{arrow} {sign}{delta:.3f} ({sign}{pct:.0f}%)"


def _resource_lines(resources: list, limit: int = _RESOURCE_N) -> list:
    """Format resource drill-down lines (tree style)."""
    if not resources:
        return ["   └ (no resource data — enable CE resource-level granularity)"]
    lines = []
    shown = resources[:limit]
    for i, r in enumerate(shown):
        name = r["name"]
        # Shorten long ARNs to last segment
        if "/" in name:
            name = name.split("/")[-1]
        elif ":" in name and name.startswith("arn:"):
            name = name.split(":")[-1]
        connector = "└" if i == len(shown) - 1 else "├"
        lines.append(f"   {connector} `{name[:36]}`  ${r['cost']:.3f}")
    if len(resources) > limit:
        lines.append(f"   └ … +{len(resources) - limit} more")
    return lines


def _get_mtd_total(ce, mtd_start: date, today: date) -> float:
    """Return Month-to-Date UnblendedCost total (MONTHLY granularity)."""
    if mtd_start == today:          # 1st of the month — no completed days yet
        return 0.0
    try:
        resp = ce.get_cost_and_usage(
            TimePeriod={"Start": mtd_start.isoformat(), "End": today.isoformat()},
            Granularity="MONTHLY",
            Metrics=["UnblendedCost"],
        )
        return sum(
            float(r["Total"]["UnblendedCost"]["Amount"])
            for r in resp.get("ResultsByTime", [])
        )
    except Exception as exc:
        print(f"MTD query failed: {exc}")
        return 0.0


# ---------------------------------------------------------------------------
# FinOps Scheduled Report — Message Builders
# ---------------------------------------------------------------------------

def _build_daily_message(yesterday_total: float, mtd_total: float,
                         top_services: list, report_date: date) -> str:
    """Clean MTD + Yesterday digest for the FinOps Sentinel Telegram topic."""
    lines = [
        "💰 *CORTEX Daily FinOps Digest*",
        f"📅 Date: `{report_date.strftime('%Y-%m-%d')}`",
        "",
        "📊 *Overview:*",
        f"• Yesterday: *${yesterday_total:.2f}*",
        f"• Month\\-to\\-Date: *${mtd_total:.2f}*",
        "",
        "🔍 *Top Spenders \\(Yesterday\\):*",
    ]
    if not top_services:
        lines.append("_No significant spend recorded for yesterday\\._")
    else:
        for i, svc in enumerate(top_services[:_TOP_SERVICES], start=1):
            emoji = _service_emoji(svc["name"])
            lines.append(f"{i}\\. {emoji} {svc['name']}: *${svc['cost']:.2f}*")
    lines += [
        "",
        "📈 [AWS Cost Explorer](https://console.aws.amazon.com/cost-management/home#/dashboard)",
    ]
    return "\n".join(lines)


def _build_weekly_message(rows: list, current_total: float, previous_total: float,
                          lambda_invocations: int, week_end: date, resources_map: dict) -> str:
    week_start      = week_end - timedelta(days=7)
    prev_week_start = week_start - timedelta(days=7)
    total_delta = current_total - previous_total
    total_pct   = (total_delta / previous_total * 100) if previous_total > 0 else 0.0
    total_arrow = "🔺" if total_delta > 0.005 else ("🔻" if total_delta < -0.005 else "➡️")
    total_sign  = "+" if total_delta >= 0 else ""
    alert_line  = f"\n⚠️ *Cost Alert:* Weekly spend exceeds ${_ALERT_USD:.0f}!" if current_total > _ALERT_USD else ""

    lines = [
        "💰 *DND Platform — Weekly Deep Dive*",
        "",
        f"📅 *This week:* `{week_start}` → `{week_end}`",
        f"📅 *vs prior:*  `{prev_week_start}` → `{week_start}`",
        "",
        "─────────────────────────",
        "📊 *Account Summary*",
        f"💵 This week:   `${current_total:.4f}`",
        f"💵 Last week:   `${previous_total:.4f}`",
        f"📈 WoW change: `{total_sign}${total_delta:.4f}` ({total_sign}{total_pct:.0f}%) {total_arrow}",
        f"⚡ Lambda calls: `{lambda_invocations:,}`",
        alert_line,
        "",
        "─────────────────────────",
        "🔍 *Full Service Breakdown*",
        "",
    ]

    other_curr = other_prev = 0.0
    for i, r in enumerate(rows):
        if i >= _TOP_SERVICES:
            other_curr += r["current"]
            other_prev += r["previous"]
            continue
        emoji    = _service_emoji(r["service"])
        spike    = " 🚨" if r["spike"] else ""
        wow      = _delta_str(r["delta"], r["pct"])
        lines.append(f"{emoji} *{r['service']}*{spike}")
        lines.append(f"   Current: `${r['current']:.4f}`  {wow}")
        lines.append(f"   Previous: `${r['previous']:.4f}`")
        if i < _DRILLDOWN_N and r["service"] in resources_map:
            lines.extend(_resource_lines(resources_map[r["service"]]))
        lines.append("")

    if other_curr > _MIN_COST:
        other_delta = other_curr - other_prev
        other_pct   = (other_delta / other_prev * 100) if other_prev > 0 else 0.0
        lines.append(f"💠 *Other ({len(rows) - _TOP_SERVICES} services)*")
        lines.append(f"   Current: `${other_curr:.4f}`  {_delta_str(other_delta, other_pct)}")
        lines.append("")

    # Spike callouts
    spikes = [r for r in rows if r["spike"]]
    if spikes:
        lines += [
            "─────────────────────────",
            f"🚨 *WoW Spikes (>{int(_SPIKE_PCT)}% growth)*",
        ]
        for r in spikes[:6]:
            lines.append(
                f"  • {_service_emoji(r['service'])} {r['service']}: "
                f"`+${r['delta']:.3f}` (+{r['pct']:.0f}%)"
            )
            if r["service"] in resources_map:
                for res in resources_map[r["service"]][:2]:
                    rname = res["name"].split("/")[-1] if "/" in res["name"] else res["name"]
                    lines.append(f"    └ `{rname[:36]}`  +${res['cost']:.3f}")
        lines.append("")

    lines += [
        "─────────────────────────",
        "📊 [AWS Cost Explorer](https://console.aws.amazon.com/cost-management/home#/dashboard)",
    ]
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# FinOps Scheduled Report — Main Orchestrator
# ---------------------------------------------------------------------------

def handle_finops_report(report_type: str, token: str, chat_id: str, topic_id: str) -> dict:
    """Entry point for scheduled daily/weekly FinOps reports."""
    aws_region = os.environ.get("AWS_DEFAULT_REGION", "us-east-1")
    ce = boto3.client("ce",         region_name="us-east-1")  # CE is global
    cw = boto3.client("cloudwatch", region_name=aws_region)

    today = date.today()

    if report_type == "daily":
        # ── Daily: Yesterday finalised cost + MTD total (no billing lag)
        yesterday  = today - timedelta(days=1)
        mtd_start  = today.replace(day=1)

        # Call 1 — Yesterday service breakdown (DAILY, UnblendedCost)
        print(f"[daily] Yesterday breakdown {yesterday} → {today}")
        yesterday_dict = _get_cost_by_service(ce, yesterday, today)
        yesterday_total = sum(v for v in yesterday_dict.values() if v >= _MIN_COST)
        top_services = sorted(
            [{"name": k, "cost": v} for k, v in yesterday_dict.items() if v >= _MIN_COST],
            key=lambda x: x["cost"], reverse=True,
        )

        # Call 2 — Month-to-Date total (MONTHLY, UnblendedCost)
        print(f"[daily] MTD query {mtd_start} → {today}")
        mtd_total = _get_mtd_total(ce, mtd_start, today)

        print(f"[daily] Yesterday=${yesterday_total:.2f}  MTD=${mtd_total:.2f}  services={len(top_services)}")
        message = _build_daily_message(yesterday_total, mtd_total, top_services, yesterday)

    elif report_type == "weekly":
        # ── Weekly: current vs previous 7-day window
        curr_end    = today
        curr_start  = today - timedelta(days=7)
        prev_end    = curr_start
        prev_start  = curr_start - timedelta(days=7)

        print(f"[weekly] Current {curr_start}→{curr_end} | Previous {prev_start}→{prev_end}")
        current_costs  = _get_cost_by_service(ce, curr_start,  curr_end)
        previous_costs = _get_cost_by_service(ce, prev_start,  prev_end)

        rows           = _build_comparison_table(current_costs, previous_costs)
        current_total  = sum(current_costs.values())
        previous_total = sum(previous_costs.values())
        lambda_inv     = _get_lambda_invocations(cw, curr_start, curr_end)

        # Resource drill-down for top N services by current cost
        resources_map = {}
        for r in rows[:_DRILLDOWN_N]:
            resources_map[r["service"]] = _get_resources_for_service(
                ce, r["service"], curr_start, curr_end
            )

        message = _build_weekly_message(
            rows, current_total, previous_total, lambda_inv, curr_end, resources_map
        )
    else:
        message = f"⚠️ Unknown report_type: {report_type}"

    print(f"Sending {report_type} report ({len(message)} chars) to Telegram")
    send_telegram_message(token, chat_id, message, topic_id)

    return {
        "statusCode": 200,
        "body": json.dumps({"message": f"FinOps {report_type} report sent"}),
    }

# ---------------------------------------------------------------------------
# Tool definitions for the Copilot Agent (function-calling schema)
# ---------------------------------------------------------------------------
AGENT_TOOLS = [
    {
        "type": "function",
        "function": {
            "name": "get_terraform_file",
            "description": "Read a Terraform (.tf) file from the infrastructure repository",
            "parameters": {
                "type": "object",
                "properties": {
                    "file_path": {"type": "string", "description": "Path to the Terraform file in the repo"},
                },
                "required": ["file_path"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "list_repo_files",
            "description": "List files in a directory of the GitHub repository to discover Terraform files",
            "parameters": {
                "type": "object",
                "properties": {
                    "directory_path": {"type": "string", "description": "Directory path in the repo (use '' for root)"},
                },
                "required": ["directory_path"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "create_optimization_pr",
            "description": "Create a PR with Terraform changes to optimize costs (resize instances, adjust scaling, remove unused resources)",
            "parameters": {
                "type": "object",
                "properties": {
                    "file_path": {"type": "string", "description": "Terraform file to modify"},
                    "new_content": {"type": "string", "description": "Complete new file content"},
                    "optimization_summary": {"type": "string", "description": "Summary of the optimization changes"},
                    "estimated_savings": {"type": "string", "description": "Estimated monthly cost savings"},
                    "commit_message": {"type": "string", "description": "Git commit message"},
                },
                "required": ["file_path", "new_content", "optimization_summary", "commit_message"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_failed_terraform_runs",
            "description": "Check for failed GitHub Actions workflow runs related to Terraform deployments",
            "parameters": {
                "type": "object",
                "properties": {},
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_workflow_logs",
            "description": "Get detailed job logs for a specific workflow run to diagnose Terraform failures",
            "parameters": {
                "type": "object",
                "properties": {
                    "run_id": {"type": "integer", "description": "Workflow run ID"},
                },
                "required": ["run_id"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "create_fix_pr",
            "description": "Create a PR to fix a failed Terraform deployment",
            "parameters": {
                "type": "object",
                "properties": {
                    "file_path": {"type": "string", "description": "Terraform file to fix"},
                    "new_content": {"type": "string", "description": "Complete corrected file content"},
                    "fix_description": {"type": "string", "description": "Description of what was fixed"},
                    "commit_message": {"type": "string", "description": "Git commit message"},
                },
                "required": ["file_path", "new_content", "fix_description", "commit_message"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "create_issue",
            "description": "Create a GitHub issue for manual review when automated fix is not possible",
            "parameters": {
                "type": "object",
                "properties": {
                    "title": {"type": "string", "description": "Issue title"},
                    "body": {"type": "string", "description": "Issue body in Markdown with analysis"},
                    "labels": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Labels to apply",
                    },
                },
                "required": ["title", "body"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "rerun_terraform_workflow",
            "description": "Re-trigger a failed Terraform deployment workflow",
            "parameters": {
                "type": "object",
                "properties": {
                    "run_id": {"type": "integer", "description": "Workflow run ID to rerun"},
                },
                "required": ["run_id"],
            },
        },
    },
]


# ---------------------------------------------------------------------------
# Lambda Handler
# ---------------------------------------------------------------------------
def lambda_handler(event, context):
    """
    Main entry point.
    Routes:
      - EventBridge scheduled events  → handle_finops_report() (daily/weekly)
      - API Gateway webhook events    → cost_alert / terraform handlers
    """
    print(f"Received event: {json.dumps(event)}")

    # ── Scheduled EventBridge reports (payload comes directly in event, not body)
    report_type = event.get("report_type")
    if report_type in ("daily", "weekly"):
        _token    = os.environ["TELEGRAM_TOKEN"]
        _chat_id  = os.environ["TELEGRAM_CHAT_ID"]
        _topic_id = os.environ.get("TELEGRAM_TOPIC_ID", "")
        return handle_finops_report(report_type, _token, _chat_id, _topic_id)

    # Parse webhook payload (API Gateway path)
    body = json.loads(event.get("body", "{}"))

    # Environment variables
    github_app_id = os.environ["GITHUB_APP_ID"]
    github_app_installation_id = os.environ["GITHUB_APP_INSTALLATION_ID"]
    github_app_private_key = os.environ["GITHUB_APP_PRIVATE_KEY"]
    telegram_token = os.environ["TELEGRAM_TOKEN"]
    telegram_chat_id = os.environ["TELEGRAM_CHAT_ID"]
    telegram_topic_id = os.environ.get("TELEGRAM_TOPIC_ID", "")
    repo_owner = os.environ.get("GITHUB_REPO_OWNER", "")
    repo_name = os.environ.get("GITHUB_REPO_NAME", "")

    # Generate installation token for GitHub API operations
    from copilot_agent import get_installation_token, GitHubAPI
    github_token = get_installation_token(github_app_id, github_app_installation_id, github_app_private_key)
    github = GitHubAPI(github_token)

    # Determine event type
    alert_type = body.get("alert_type", "cost_alert")

    if alert_type == "terraform_plan_review":
        result = handle_terraform_plan_review(body)
    elif alert_type == "terraform_failure":
        result = handle_terraform_failure(body, github, github_app_id, github_app_installation_id, github_app_private_key, repo_owner, repo_name)
    else:
        result = handle_cost_alert(body, github, github_app_id, github_app_installation_id, github_app_private_key, repo_owner, repo_name)

    # Send Telegram notification
    telegram_message = (
        f"💰 *CORTEX FinOps Sentinel*\n"
        f"*Type:* `{alert_type}`\n\n"
        f"{result[:3500]}"
    )
    send_telegram_message(telegram_token, telegram_chat_id, telegram_message, telegram_topic_id)

    return {
        "statusCode": 200,
        "body": json.dumps({
            "message": "FinOps alert processed",
            "alert_type": alert_type,
            "agent_summary": result[:500],
        }),
    }


# ---------------------------------------------------------------------------
# Terraform Plan Review Handler (CI Pipeline FinOps Guard)
# ---------------------------------------------------------------------------

# Cost estimates per resource type (monthly USD, rough approximations)
RESOURCE_COST_ESTIMATES = {
    "aws_lambda_function": 0.20,
    "aws_dynamodb_table": 1.25,
    "aws_apigatewayv2_api": 1.00,
    "aws_cloudwatch_log_group": 0.50,
    "aws_iam_role": 0.00,
    "aws_iam_role_policy": 0.00,
    "aws_iam_role_policy_attachment": 0.00,
    "aws_lambda_permission": 0.00,
    "aws_cloudwatch_event_rule": 0.00,
    "aws_cloudwatch_event_target": 0.00,
    "aws_apigatewayv2_stage": 0.00,
    "aws_apigatewayv2_route": 0.00,
    "aws_apigatewayv2_integration": 0.00,
    "aws_instance": 30.00,       # t3.micro baseline
    "aws_db_instance": 25.00,    # db.t3.micro baseline
    "aws_s3_bucket": 2.30,
    "aws_nat_gateway": 32.00,
    "aws_lb": 22.00,
    "aws_ecs_service": 10.00,
    "aws_rds_cluster": 50.00,
    "aws_elasticache_cluster": 15.00,
}

# High-cost resource types that trigger warnings
HIGH_COST_TYPES = {
    "aws_instance", "aws_db_instance", "aws_nat_gateway", "aws_lb",
    "aws_rds_cluster", "aws_elasticache_cluster", "aws_ecs_service",
    "aws_eks_cluster", "aws_redshift_cluster", "aws_elasticsearch_domain",
    "aws_opensearch_domain",
}


def handle_terraform_plan_review(body):
    """
    Analyze a Terraform JSON plan exported by the CI pipeline.
    Scans the resource_changes array for:
      - 'delete' actions (potential service disruption)
      - High-cost resource creations
      - Unusual scaling changes
    
    Returns a human-readable FinOps analysis string for Telegram.
    """
    print("[FINOPS] Processing terraform_plan_review event")

    environment = body.get("environment", "unknown")
    summary = body.get("summary", {})
    resource_changes = body.get("resource_changes", [])

    total_changes = summary.get("total_changes", len(resource_changes))
    creates = summary.get("creates", [])
    deletes = summary.get("deletes", [])
    updates = summary.get("updates", [])

    # ── Analyze resource_changes array ──
    warnings = []
    cost_delta_estimate = 0.0
    high_cost_creates = []
    delete_risks = []

    for change in resource_changes:
        address = change.get("address", "unknown")
        change_detail = change.get("change", {})
        actions = change_detail.get("actions", ["no-op"])
        resource_type = change.get("type", "")

        # Skip no-op
        if actions == ["no-op"]:
            continue

        # ── DELETE detection: potential service disruption ──
        if "delete" in actions:
            delete_risks.append(f"  🗑️ `{address}`")
            est = RESOURCE_COST_ESTIMATES.get(resource_type, 5.0)
            cost_delta_estimate -= est

        # ── CREATE detection: check for high-cost resources ──
        if "create" in actions:
            est = RESOURCE_COST_ESTIMATES.get(resource_type, 1.0)
            cost_delta_estimate += est

            if resource_type in HIGH_COST_TYPES:
                # Try to extract instance type from planned values
                after_vals = change_detail.get("after", {}) or {}
                instance_type = (
                    after_vals.get("instance_type", "")
                    or after_vals.get("instance_class", "")
                    or after_vals.get("node_type", "")
                    or "unknown-size"
                )
                high_cost_creates.append(
                    f"  💸 `{address}` ({instance_type}) ~${est:.0f}/mo"
                )

        # ── UPDATE detection: check for scaling changes ──
        if "update" in actions:
            before_vals = change_detail.get("before", {}) or {}
            after_vals = change_detail.get("after", {}) or {}
            # Detect memory/timeout/instance size changes
            for key in ("memory_size", "timeout", "instance_type", "instance_class",
                        "desired_count", "min_size", "max_size"):
                before_val = before_vals.get(key)
                after_val = after_vals.get(key)
                if before_val is not None and after_val is not None and before_val != after_val:
                    warnings.append(
                        f"  ⚙️ `{address}` — {key}: `{before_val}` → `{after_val}`"
                    )

    # ── Build report ──
    report_lines = [
        f"📋 *Terraform Plan Analysis*",
        f"*Environment:* `{environment}`",
        f"*Changes:* {total_changes} total "
        f"(+{len(creates)} create, ~{len(updates)} update, -{len(deletes)} delete)",
        "",
    ]

    # Cost estimate
    direction = "📈" if cost_delta_estimate > 0 else "📉" if cost_delta_estimate < 0 else "➡️"
    report_lines.append(
        f"{direction} *Est. Monthly Cost Impact:* ${cost_delta_estimate:+.2f}/mo"
    )
    report_lines.append("")

    # High-cost resource alerts
    if high_cost_creates:
        report_lines.append("⚠️ *High-Cost Resources Being Created:*")
        report_lines.extend(high_cost_creates)
        report_lines.append("")

    # Delete risk alerts
    if delete_risks:
        report_lines.append("🚨 *Resources Being DELETED (verify intent):*")
        report_lines.extend(delete_risks)
        report_lines.append("")

    # Scaling / config changes
    if warnings:
        report_lines.append("⚙️ *Configuration Changes Detected:*")
        report_lines.extend(warnings)
        report_lines.append("")

    # Verdict
    if high_cost_creates or (delete_risks and environment == "prod"):
        report_lines.append("🔴 *Verdict:* REVIEW REQUIRED — high-cost or destructive changes detected")
    elif delete_risks:
        report_lines.append("🟡 *Verdict:* CAUTION — resource deletions in plan")
    elif total_changes == 0:
        report_lines.append("🟢 *Verdict:* No changes — infrastructure in sync")
    else:
        report_lines.append("🟢 *Verdict:* CLEAR — standard changes, no cost anomalies")

    result = "\n".join(report_lines)
    print(f"[FINOPS] Plan review result: {result[:500]}")
    return result


# ---------------------------------------------------------------------------
# Cost Alert Handler
# ---------------------------------------------------------------------------

def handle_cost_alert(body, github, github_app_id, github_app_installation_id, github_app_private_key, owner, repo):
    """AI-powered cost analysis and infrastructure optimization."""
    service = body.get("service", "Unknown")
    cost_amount = body.get("cost_amount", 0)
    period = body.get("period", "Unknown")
    threshold = body.get("threshold", 0)
    resource_details = body.get("resource_details", {})

    # Determine severity
    if threshold > 0 and cost_amount > threshold * 1.5:
        severity = "CRITICAL"
    elif threshold > 0 and cost_amount > threshold:
        severity = "WARNING"
    else:
        severity = "INFO"

    # Tool executor
    def tool_executor(tool_name, args):
        if tool_name == "get_terraform_file":
            return _get_terraform_file(github, owner, repo, args)
        elif tool_name == "list_repo_files":
            return _list_repo_files(github, owner, repo, args)
        elif tool_name == "create_optimization_pr":
            return _create_optimization_pr(github, owner, repo, args)
        elif tool_name == "create_issue":
            return _create_issue(github, owner, repo, args)
        elif tool_name == "get_failed_terraform_runs":
            return _get_failed_terraform_runs(github, owner, repo)
        elif tool_name == "get_workflow_logs":
            return _get_workflow_logs(github, owner, repo, args)
        elif tool_name == "create_fix_pr":
            return _create_fix_pr(github, owner, repo, args)
        elif tool_name == "rerun_terraform_workflow":
            return _rerun_terraform_workflow(github, owner, repo, args)
        return f"Unknown tool: {tool_name}"

    agent = CopilotAgent(github_app_id, github_app_installation_id, github_app_private_key)
    agent.set_system_prompt(
        "You are CORTEX FinOps Sentinel, an expert cloud cost optimization AI agent. "
        "Your job is to analyze cost anomalies and optimize cloud infrastructure.\n\n"
        "Steps:\n"
        "1. List the repo files to find Terraform configurations.\n"
        "2. Read relevant Terraform files to understand the current infrastructure.\n"
        "3. Analyze the cost data and identify optimization opportunities:\n"
        "   - Right-size EC2/Lambda/RDS instances\n"
        "   - Adjust auto-scaling parameters\n"
        "   - Remove unused or over-provisioned resources\n"
        "   - Optimize storage tiers\n"
        "4. Create a PR with Terraform changes and estimated savings.\n"
        "5. If optimization requires manual review, create an issue instead.\n\n"
        "Always be specific about estimated savings and include before/after comparisons."
    )

    response = agent.run_agent_loop(
        user_message=(
            f"Cost Alert - {severity}:\n"
            f"- Service: {service}\n"
            f"- Period: {period}\n"
            f"- Current Cost: ${cost_amount:.2f}\n"
            f"- Threshold: ${threshold:.2f}\n"
            f"- Variance: {((cost_amount / max(threshold, 1) - 1) * 100):.1f}%\n"
            f"- Resource Details: {json.dumps(resource_details)[:500]}\n\n"
            f"Please analyze the infrastructure, find optimization opportunities, "
            f"and create a PR with Terraform changes to reduce costs."
        ),
        tools=AGENT_TOOLS,
        tool_executor=tool_executor,
        max_iterations=8,
    )

    return (
        f"{'🔴' if severity == 'CRITICAL' else '🟠' if severity == 'WARNING' else '🟢'} "
        f"*{severity} — {service}*\n"
        f"Cost: ${cost_amount:.2f} / Threshold: ${threshold:.2f}\n\n"
        f"*AI Analysis:*\n{response[:2500]}"
    )


# ---------------------------------------------------------------------------
# Terraform Failure Handler
# ---------------------------------------------------------------------------

def handle_terraform_failure(body, github, github_app_id, github_app_installation_id, github_app_private_key, owner, repo):
    """AI-diagnose and auto-fix failed Terraform deployments."""
    run_id = body.get("run_id")
    error_message = body.get("error_message", "")
    workspace = body.get("workspace", "default")

    def tool_executor(tool_name, args):
        if tool_name == "get_terraform_file":
            return _get_terraform_file(github, owner, repo, args)
        elif tool_name == "list_repo_files":
            return _list_repo_files(github, owner, repo, args)
        elif tool_name == "get_failed_terraform_runs":
            return _get_failed_terraform_runs(github, owner, repo)
        elif tool_name == "get_workflow_logs":
            return _get_workflow_logs(github, owner, repo, args)
        elif tool_name == "create_fix_pr":
            return _create_fix_pr(github, owner, repo, args)
        elif tool_name == "create_issue":
            return _create_issue(github, owner, repo, args)
        elif tool_name == "rerun_terraform_workflow":
            return _rerun_terraform_workflow(github, owner, repo, args)
        return f"Unknown tool: {tool_name}"

    agent = CopilotAgent(github_app_id, github_app_installation_id, github_app_private_key)
    agent.set_system_prompt(
        "You are CORTEX FinOps Sentinel, an expert Terraform/IaC remediation agent. "
        "A Terraform deployment has failed. Your job is to:\n"
        "1. Fetch the workflow logs to identify the exact Terraform error.\n"
        "2. Read the relevant Terraform files from the repo.\n"
        "3. Diagnose the root cause (resource conflicts, quota issues, syntax errors, state drift).\n"
        "4. Generate a fix and create a PR with corrected Terraform code.\n"
        "5. If the error is transient (API timeout, rate limit), rerun the workflow.\n"
        "6. If manual intervention is needed, create an issue with full analysis.\n\n"
        "Common Terraform failure patterns to check:\n"
        "- Resource already exists (import needed)\n"
        "- Quota exceeded (adjust instance types or request increase)\n"
        "- Invalid configuration (fix syntax/references)\n"
        "- Provider version incompatibility\n"
        "- State lock issues"
    )

    response = agent.run_agent_loop(
        user_message=(
            f"Terraform deployment FAILED:\n"
            f"- Workspace: {workspace}\n"
            f"- Run ID: {run_id if run_id else 'unknown'}\n"
            f"- Error: {error_message[:1000]}\n\n"
            f"Please diagnose the failure, read the Terraform files, and attempt an auto-fix."
        ),
        tools=AGENT_TOOLS,
        tool_executor=tool_executor,
        max_iterations=8,
    )

    return f"🔧 *Terraform Fix Report*\nWorkspace: `{workspace}`\n\n{response[:2500]}"


# ---------------------------------------------------------------------------
# Tool Implementations
# ---------------------------------------------------------------------------

def _get_terraform_file(github, owner, repo, args):
    result = github.get_repo_content(owner, repo, args["file_path"])
    if result["status"] == 200:
        content_b64 = result["data"].get("content", "")
        try:
            return base64.b64decode(content_b64).decode("utf-8")[:15000]
        except Exception:
            return "Could not decode file."
    return f"Could not fetch file (HTTP {result['status']})"


def _list_repo_files(github, owner, repo, args):
    path = args.get("directory_path", "")
    result = github.get_repo_content(owner, repo, path)
    if result["status"] == 200:
        items = result["data"] if isinstance(result["data"], list) else [result["data"]]
        output = []
        for item in items:
            item_type = item.get("type", "")
            name = item.get("name", "")
            size = item.get("size", 0)
            output.append(f"{'📁' if item_type == 'dir' else '📄'} {name} ({size}B)")
        return "\n".join(output)
    return f"Could not list directory (HTTP {result['status']})"


def _create_optimization_pr(github, owner, repo, args):
    """Create a PR with infrastructure optimization changes."""
    try:
        branch_name = f"cortex/cost-optimize-{datetime.utcnow().strftime('%Y%m%d-%H%M%S')}"
        base_sha = github.get_default_branch_sha(owner, repo)
        if not base_sha:
            return "Error: Could not get base branch SHA."

        branch_result = github.create_branch(owner, repo, branch_name, base_sha)
        if branch_result["status"] not in (200, 201):
            return f"Error creating branch: {branch_result['data']}"

        # Get current file SHA
        file_result = github.get_repo_content(owner, repo, args["file_path"])
        file_sha = file_result["data"].get("sha") if file_result["status"] == 200 else None

        content_b64 = base64.b64encode(args["new_content"].encode("utf-8")).decode("utf-8")
        update_result = github.update_file(
            owner, repo, args["file_path"], content_b64,
            args["commit_message"], branch_name, file_sha,
        )
        if update_result["status"] not in (200, 201):
            return f"Error committing changes: {update_result['data']}"

        savings = args.get("estimated_savings", "TBD")
        pr_body = (
            f"## 💰 CORTEX Cost Optimization\n\n"
            f"**Summary:** {args['optimization_summary']}\n\n"
            f"**Estimated Monthly Savings:** {savings}\n\n"
            f"This PR was auto-generated by the CORTEX FinOps Sentinel AI agent.\n"
            f"Please review the Terraform changes before merging."
        )
        pr_result = github.create_pull_request(
            owner, repo,
            f"💰 Cost Optimization: {args['commit_message'][:60]}",
            pr_body, branch_name,
        )
        if pr_result["status"] in (200, 201):
            return f"✅ Optimization PR created: {pr_result['data'].get('html_url', '')}"
        return f"Error creating PR: {pr_result['data']}"
    except Exception as e:
        return f"Error creating optimization PR: {str(e)}"


def _create_fix_pr(github, owner, repo, args):
    """Create a PR to fix failed Terraform."""
    try:
        branch_name = f"cortex/tf-fix-{datetime.utcnow().strftime('%Y%m%d-%H%M%S')}"
        base_sha = github.get_default_branch_sha(owner, repo)
        if not base_sha:
            return "Error: Could not get base branch SHA."

        branch_result = github.create_branch(owner, repo, branch_name, base_sha)
        if branch_result["status"] not in (200, 201):
            return f"Error creating branch: {branch_result['data']}"

        file_result = github.get_repo_content(owner, repo, args["file_path"])
        file_sha = file_result["data"].get("sha") if file_result["status"] == 200 else None

        content_b64 = base64.b64encode(args["new_content"].encode("utf-8")).decode("utf-8")
        update_result = github.update_file(
            owner, repo, args["file_path"], content_b64,
            args["commit_message"], branch_name, file_sha,
        )
        if update_result["status"] not in (200, 201):
            return f"Error committing fix: {update_result['data']}"

        pr_body = (
            f"## 🔧 CORTEX Terraform Fix\n\n"
            f"**Diagnosis:** {args['fix_description']}\n\n"
            f"This PR was auto-generated by the CORTEX FinOps Sentinel to fix a failed deployment.\n"
            f"Please review before merging and re-deploying."
        )
        pr_result = github.create_pull_request(
            owner, repo,
            f"🔧 TF Fix: {args['commit_message'][:60]}",
            pr_body, branch_name,
        )
        if pr_result["status"] in (200, 201):
            return f"✅ Fix PR created: {pr_result['data'].get('html_url', '')}"
        return f"Error creating PR: {pr_result['data']}"
    except Exception as e:
        return f"Error creating fix PR: {str(e)}"


def _get_failed_terraform_runs(github, owner, repo):
    result = github.get_workflow_runs(owner, repo, status="failure")
    if result["status"] != 200:
        return f"Error: {result['data']}"
    runs = result["data"].get("workflow_runs", [])[:5]
    if not runs:
        return "No recent failed workflow runs."
    output = []
    for r in runs:
        output.append(f"- ID: {r['id']} | {r.get('name', 'unknown')} | Conclusion: {r.get('conclusion', '')}")
    return "\n".join(output)


def _get_workflow_logs(github, owner, repo, args):
    result = github.get_workflow_run_logs(owner, repo, args["run_id"])
    if result["status"] != 200:
        return f"Error fetching logs: {result['data']}"
    jobs = result["data"].get("jobs", [])
    output = []
    for job in jobs:
        conclusion = job.get("conclusion", "unknown")
        output.append(f"\n**Job: {job.get('name', 'unknown')}** → {conclusion}")
        for step in job.get("steps", []):
            marker = "❌" if step.get("conclusion") == "failure" else "✅"
            output.append(f"  {marker} {step.get('name', 'unknown')}")
    return "\n".join(output)


def _create_issue(github, owner, repo, args):
    labels = args.get("labels", ["finops", "infrastructure", "auto-detected"])
    result = github.create_issue(owner, repo, args["title"], args["body"], labels)
    if result["status"] in (200, 201):
        return f"✅ Issue created: {result['data'].get('html_url', '')}"
    return f"Error creating issue: {result['data']}"


def _rerun_terraform_workflow(github, owner, repo, args):
    result = github.rerun_workflow(owner, repo, args["run_id"])
    if result["status"] in (200, 201):
        return f"✅ Workflow {args['run_id']} re-triggered."
    return f"Error rerunning workflow: {result['data']}"


# ---------------------------------------------------------------------------
# Telegram notification
# ---------------------------------------------------------------------------
def send_telegram_message(token, chat_id, message, topic_id=""):
    """Send a message to Telegram Bot API, optionally to a specific forum topic."""
    http = urllib3.PoolManager()
    url = f"https://api.telegram.org/bot{token}/sendMessage"
    payload = {
        "chat_id": chat_id,
        "text": message[:4096],
        "parse_mode": "Markdown",
    }
    # Route to specific forum topic if topic_id is provided
    if topic_id:
        payload["message_thread_id"] = int(topic_id)
    try:
        response = http.request(
            "POST", url,
            body=json.dumps(payload).encode("utf-8"),
            headers={"Content-Type": "application/json"},
        )
        if response.status == 200:
            print("Telegram message sent successfully")
        else:
            print(f"Failed to send Telegram message: {response.data.decode('utf-8')}")
    except Exception as e:
        print(f"Error sending Telegram message: {str(e)}")
