"""
Project CORTEX - Module 2: Git Radar
AI-Powered GitHub Event Intelligence Agent

Processes GitHub webhooks (push, PR, workflow failures) via API Gateway.
Uses GitHub Copilot SDK as an AI agent to:
  1. Auto-review Pull Requests for security, bugs, and Terraform drift
  2. Detect failed GitHub Actions and trigger auto-remediation
  3. Provide intelligent commit/PR summaries on Telegram dashboard
  4. Maintain stateful dashboard via DynamoDB
"""

import json
import os
import base64
import boto3
import urllib3
from datetime import datetime

from copilot_agent import CopilotAgent, GitHubAPI

# Initialize AWS clients
dynamodb = boto3.resource("dynamodb")
table = None

# ---------------------------------------------------------------------------
# Tool definitions for the Copilot Agent (function-calling schema)
# ---------------------------------------------------------------------------
AGENT_TOOLS = [
    {
        "type": "function",
        "function": {
            "name": "get_file_content",
            "description": "Read a file from the GitHub repository to review its content",
            "parameters": {
                "type": "object",
                "properties": {
                    "file_path": {"type": "string", "description": "Path to the file in the repo"},
                    "ref": {"type": "string", "description": "Git ref (branch/sha) to read from"},
                },
                "required": ["file_path"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_pr_diff",
            "description": "Get the diff/changed files for a pull request",
            "parameters": {
                "type": "object",
                "properties": {
                    "pr_number": {"type": "integer", "description": "Pull request number"},
                },
                "required": ["pr_number"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "post_pr_review_comment",
            "description": "Post a review comment on a pull request with your analysis and suggestions",
            "parameters": {
                "type": "object",
                "properties": {
                    "pr_number": {"type": "integer", "description": "Pull request number"},
                    "comment": {"type": "string", "description": "Review comment in Markdown"},
                },
                "required": ["pr_number", "comment"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_failed_workflows",
            "description": "List recent failed GitHub Actions workflow runs",
            "parameters": {
                "type": "object",
                "properties": {},
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_workflow_job_logs",
            "description": "Get job details and failed steps for a specific workflow run",
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
            "name": "create_remediation_issue",
            "description": "Create a GitHub issue with analysis and recommended fix for a detected problem",
            "parameters": {
                "type": "object",
                "properties": {
                    "title": {"type": "string", "description": "Issue title"},
                    "body": {"type": "string", "description": "Issue body in Markdown with analysis and recommendations"},
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
            "name": "rerun_workflow",
            "description": "Re-trigger a failed GitHub Actions workflow run",
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
# CORTEX Guardian Agent Scan Event Handler
# ---------------------------------------------------------------------------
def handle_agent_scan_event(body: dict) -> dict:
    """
    Handle agent_scan events from CORTEX Guardian (Module 4).
    Module 4 runs in GitHub Actions and sends PR analysis results via webhook.
    
    Expected payload structure:
    {
        "event": "agent_scan",
        "pr": <pr_number>,
        "status": "⚠️ Risks Found" | "🟢 Clean",
        "risk_level": "🔴 CRITICAL" | "🟡 MEDIUM" | "🟢 LOW" | "✅ CLEAN",
        "summary": "<analysis_text>",
        "repository": "owner/repo",
        "scanner": "CORTEX-Guardian",
        "timestamp": "2026-02-10T..."
    }
    """
    print(f"[GIT RADAR] Processing CORTEX Guardian agent_scan event")
    
    # Extract event data
    pr_number = body.get("pr", "Unknown")
    status = body.get("status", "Unknown")
    risk_level = body.get("risk_level", "")
    summary = body.get("summary", "No summary provided")
    repository = body.get("repository", "Unknown")
    scanner = body.get("scanner", "CORTEX-Guardian")
    timestamp = body.get("timestamp", "Unknown")
    
    print(f"[GIT RADAR] PR #{pr_number} | Status: {status} | Risk: {risk_level}")
    
    # Format Telegram message for agent scan results
    telegram_message = f"""🛡️ **[CORTEX GUARDIAN]**
PR Analysis Complete

**Repository**: `{repository}`
**PR**: #{pr_number}
**Status**: {status}
**Risk Level**: {risk_level}

**Analysis Summary**:
{summary[:1500]}

---
*🤖 Automated by {scanner} | {timestamp}*
"""
    
    # Send to Telegram — route to Guardian Alert topic
    telegram_token = os.environ.get("TELEGRAM_TOKEN")
    telegram_chat_id = os.environ.get("TELEGRAM_CHAT_ID")
    guardian_topic_id = os.environ.get("TELEGRAM_TOPIC_GUARDIAN_ALERT", "")
    
    if telegram_token and telegram_chat_id:
        try:
            send_telegram_message(telegram_token, telegram_chat_id, telegram_message, guardian_topic_id)
            print(f"[GIT RADAR] Agent scan notification sent to Telegram (topic={guardian_topic_id})")
        except Exception as e:
            print(f"[GIT RADAR] Failed to send Telegram notification: {e}")
    else:
        print(f"[GIT RADAR] Telegram credentials not configured, skipping notification")
    
    # Log to DynamoDB (optional)
    try:
        if table:
            table.put_item(
                Item={
                    "event_id": f"agent_scan_{pr_number}_{timestamp}",
                    "event_type": "agent_scan",
                    "pr_number": str(pr_number),
                    "status": status,
                    "risk_level": risk_level,
                    "repository": repository,
                    "timestamp": timestamp,
                    "summary_preview": summary[:500],
                }
            )
            print(f"[GIT RADAR] Agent scan event logged to DynamoDB")
    except Exception as e:
        print(f"[GIT RADAR] DynamoDB logging failed (non-critical): {e}")
    
    return {
        "statusCode": 200,
        "body": json.dumps({
            "message": "Agent scan event processed",
            "pr": pr_number,
            "status": status,
            "notification_sent": True
        }),
    }


# ---------------------------------------------------------------------------
# Lambda Handler
# ---------------------------------------------------------------------------
def lambda_handler(event, context):
    """
    Main entry point for GitHub webhook events via API Gateway.
    Routes events to the Copilot AI agent for intelligent processing.
    """
    global table
    table = dynamodb.Table(os.environ["DYNAMODB_TABLE"])

    # ── Enhanced Logging: dump full incoming event for CloudWatch ──
    print("=" * 60)
    print("[GIT RADAR] Lambda invoked")
    print(f"[GIT RADAR] Raw event payload: {json.dumps(event)}")
    print("=" * 60)

    # ── Case-insensitive header lookup ──
    # API Gateway may send headers as X-GitHub-Event, x-github-event, etc.
    raw_headers = event.get("headers", {}) or {}
    headers = {k.lower(): v for k, v in raw_headers.items()}

    github_event = headers.get("x-github-event", "unknown")
    print(f"[GIT RADAR] Detected GitHub event type: {github_event}")

    try:
        body = json.loads(event.get("body", "{}"))
    except (json.JSONDecodeError, TypeError) as e:
        print(f"[GIT RADAR] ERROR: Failed to parse body: {e}")
        return {
            "statusCode": 400,
            "body": json.dumps({"error": "Invalid JSON body"}),
        }

    print(f"[GIT RADAR] Parsed body keys: {list(body.keys())}")

    # ── Handle CORTEX Guardian Agent Scan Event (from Module 4) ──
    # Module 4 (GitHub Actions) sends custom 'agent_scan' events with PR analysis
    if body.get("event") == "agent_scan":
        print(f"[GIT RADAR] Detected CORTEX Guardian agent_scan event")
        return handle_agent_scan_event(body)

    # ── Handle GitHub Ping Event ──
    # GitHub sends a 'ping' when a webhook is first created/configured.
    if github_event == "ping":
        zen = body.get("zen", "")
        hook_id = body.get("hook_id", "")
        print(f"[GIT RADAR] Ping received — zen: '{zen}', hook_id: {hook_id}")
        return {
            "statusCode": 200,
            "body": json.dumps({
                "message": "Pong! Webhook is active.",
                "zen": zen,
                "hook_id": hook_id,
            }),
        }

    # ── Environment variables ──
    github_app_id = os.environ["GITHUB_APP_ID"]
    github_app_installation_id = os.environ["GITHUB_APP_INSTALLATION_ID"]
    github_app_private_key = os.environ["GITHUB_APP_PRIVATE_KEY"]
    telegram_token = os.environ["TELEGRAM_TOKEN"]
    telegram_chat_id = os.environ["TELEGRAM_CHAT_ID"]
    telegram_topic_id = os.environ.get("TELEGRAM_TOPIC_ID", "")
    repo_owner = os.environ.get("GITHUB_REPO_OWNER", "")
    repo_name = os.environ.get("GITHUB_REPO_NAME", "")

    # Auto-detect repo from webhook payload
    if not repo_owner or not repo_name:
        repo_full = body.get("repository", {}).get("full_name", "")
        if "/" in repo_full:
            repo_owner, repo_name = repo_full.split("/", 1)

    print(f"[GIT RADAR] Repo: {repo_owner}/{repo_name}")

    # Generate installation token for GitHub API operations
    from copilot_agent import get_installation_token
    github = None
    try:
        github_token = get_installation_token(github_app_id, github_app_installation_id, github_app_private_key)
        github = GitHubAPI(github_token)
        print(f"[GIT RADAR] GitHub App token generated successfully")
    except Exception as token_exc:
        print(f"[GIT RADAR] WARNING: GitHub App token generation failed: {token_exc}")
        # Continue — basic Telegram notifications will still fire without GitHub API access

    # ------------------------------------------------------------------
    # Route by event type (wrapped in try-except so Telegram always fires)
    # ------------------------------------------------------------------
    try:
        if github_event == "pull_request":
            print(f"[GIT RADAR] Routing to pull_request handler")
            result = handle_pull_request(body, github, github_app_id, github_app_installation_id, github_app_private_key, repo_owner, repo_name)
        elif github_event == "workflow_run":
            print(f"[GIT RADAR] Routing to workflow_run handler")
            result = handle_workflow_run(body, github, github_app_id, github_app_installation_id, github_app_private_key, repo_owner, repo_name)
        elif github_event == "push":
            print(f"[GIT RADAR] Routing to push handler")
            result = handle_push_event(body, github, github_app_id, github_app_installation_id, github_app_private_key, repo_owner, repo_name)
        elif github_event == "create":
            print(f"[GIT RADAR] Routing to create handler")
            result = handle_create_event(body)
        else:
            result = f"Received `{github_event}` event — no action needed."
            print(f"[GIT RADAR] Unhandled event type: {github_event}")
    except Exception as exc:
        result = f"⚠️ Error processing `{github_event}` event: {str(exc)}"
        print(f"[GIT RADAR] EXCEPTION in event handler: {exc}")
        import traceback
        traceback.print_exc()

    print(f"[GIT RADAR] Handler result (first 500 chars): {str(result)[:500]}")

    # ── Update Telegram dashboard ──
    dashboard_msg = (
        f"📡 *CORTEX Git Radar*\n"
        f"Event: `{github_event}` | Repo: `{repo_owner}/{repo_name}`\n\n"
        f"{result[:3000]}"
    )

    try:
        update_telegram_dashboard(telegram_token, telegram_chat_id, dashboard_msg, telegram_topic_id)
        print(f"[GIT RADAR] Telegram dashboard update attempted (topic={telegram_topic_id})")
    except Exception as tg_exc:
        print(f"[GIT RADAR] EXCEPTION sending to Telegram: {tg_exc}")
        import traceback
        traceback.print_exc()

    return {
        "statusCode": 200,
        "body": json.dumps({"message": "Event processed", "event_type": github_event}),
    }


# ---------------------------------------------------------------------------
# Event Handlers (each uses the Copilot AI Agent)
# ---------------------------------------------------------------------------

def handle_pull_request(payload, github, github_app_id, github_app_installation_id, github_app_private_key, owner, repo):
    """AI-powered PR review: security, bugs, Terraform/IaC drift detection."""
    action = payload.get("action", "unknown")
    pr = payload.get("pull_request", {})
    pr_number = pr.get("number")
    pr_title = pr.get("title", "")
    pr_body_text = pr.get("body", "") or ""
    pr_user = pr.get("user", {}).get("login", "unknown")
    pr_url = pr.get("html_url", "")

    if action not in ("opened", "synchronize", "reopened"):
        merged = pr.get("merged", False)
        action_label = {
            "closed": "🔀 Merged" if merged else "🚫 Closed",
            "labeled": "🏷️ Labeled",
            "unlabeled": "🏷️ Unlabeled",
            "assigned": "👤 Assigned",
            "review_requested": "👀 Review Requested",
            "ready_for_review": "✅ Ready for Review",
        }.get(action, f"📋 {action.replace('_', ' ').title()}")
        return f"{action_label} *PR #{pr_number}*: {pr_title}\n👤 By: {pr_user}\n🔗 {pr_url}"

    if github is None:
        return (
            f"🔍 *PR #{pr_number} opened*: {pr_title}\n"
            f"👤 By: {pr_user}\n"
            f"🔗 {pr_url}\n"
            f"⚠️ _AI review skipped — GitHub App authentication failed_"
        )

    # Tool executor
    def tool_executor(tool_name, args):
        if tool_name == "get_file_content":
            return _get_file_content(github, owner, repo, args)
        elif tool_name == "get_pr_diff":
            return _get_pr_diff(github, owner, repo, args)
        elif tool_name == "post_pr_review_comment":
            return _post_pr_review_comment(github, owner, repo, args)
        elif tool_name == "get_failed_workflows":
            return _get_failed_workflows(github, owner, repo)
        elif tool_name == "get_workflow_job_logs":
            return _get_workflow_job_logs(github, owner, repo, args)
        elif tool_name == "create_remediation_issue":
            return _create_remediation_issue(github, owner, repo, args)
        elif tool_name == "rerun_workflow":
            return _rerun_workflow(github, owner, repo, args)
        return f"Unknown tool: {tool_name}"

    agent = CopilotAgent(github_app_id, github_app_installation_id, github_app_private_key)
    agent.set_system_prompt(
        "You are CORTEX Git Radar, an expert AI code reviewer. "
        "Your job is to review Pull Requests for:\n"
        "1. **Security vulnerabilities** (hardcoded secrets, injection risks, etc.)\n"
        "2. **Bugs and logic errors**\n"
        "3. **Terraform/IaC issues** (drift, misconfigurations, missing resources)\n"
        "4. **Best practices** (naming, error handling, performance)\n\n"
        "Steps:\n"
        "1. Fetch the PR diff to see what changed.\n"
        "2. If needed, read full files for more context.\n"
        "3. Post a comprehensive review comment on the PR.\n"
        "Be constructive and actionable. Use Markdown formatting."
    )

    response = agent.run_agent_loop(
        user_message=(
            f"Review this Pull Request:\n"
            f"- PR #{pr_number}: {pr_title}\n"
            f"- Author: {pr_user}\n"
            f"- Description: {pr_body_text[:500]}\n"
            f"- URL: {pr_url}\n\n"
            f"Please fetch the diff, review the changes, and post a review comment."
        ),
        tools=AGENT_TOOLS,
        tool_executor=tool_executor,
        max_iterations=6,
    )

    return f"🔍 *PR Review for #{pr_number}*\n{response[:2000]}"


def handle_workflow_run(payload, github, github_app_id, github_app_installation_id, github_app_private_key, owner, repo):
    """Detect failed CI/CD workflows and auto-diagnose with AI."""
    action = payload.get("action", "")
    workflow_run = payload.get("workflow_run", {})
    conclusion = workflow_run.get("conclusion", "")
    run_id = workflow_run.get("id")
    run_name = workflow_run.get("name", "unknown")

    if conclusion != "failure":
        return f"Workflow `{run_name}` completed with `{conclusion}` — no action needed."

    if github is None:
        return (
            f"⚙️ *Workflow Failed*: `{run_name}`\n"
            f"🔴 Run ID: `{run_id}`\n"
            f"⚠️ _AI diagnosis skipped — GitHub App authentication failed_"
        )

    def tool_executor(tool_name, args):
        if tool_name == "get_failed_workflows":
            return _get_failed_workflows(github, owner, repo)
        elif tool_name == "get_workflow_job_logs":
            return _get_workflow_job_logs(github, owner, repo, args)
        elif tool_name == "create_remediation_issue":
            return _create_remediation_issue(github, owner, repo, args)
        elif tool_name == "rerun_workflow":
            return _rerun_workflow(github, owner, repo, args)
        elif tool_name == "get_file_content":
            return _get_file_content(github, owner, repo, args)
        return f"Unknown tool: {tool_name}"

    agent = CopilotAgent(github_app_id, github_app_installation_id, github_app_private_key)
    agent.set_system_prompt(
        "You are CORTEX Git Radar, an expert CI/CD diagnostics agent. "
        "A GitHub Actions workflow has failed. Your job is to:\n"
        "1. Fetch the workflow job logs to identify which step failed.\n"
        "2. Analyze the error and determine root cause.\n"
        "3. If it's a flaky test or transient error, rerun the workflow.\n"
        "4. If it's a real bug, create a GitHub issue with diagnosis and fix suggestions.\n"
        "Be precise and include error excerpts in your analysis."
    )

    response = agent.run_agent_loop(
        user_message=(
            f"GitHub Actions workflow FAILED:\n"
            f"- Workflow: {run_name}\n"
            f"- Run ID: {run_id}\n"
            f"- Conclusion: {conclusion}\n\n"
            f"Please fetch the job logs for run ID {run_id}, diagnose the failure, "
            f"and take appropriate action (rerun or create issue)."
        ),
        tools=AGENT_TOOLS,
        tool_executor=tool_executor,
        max_iterations=6,
    )

    return f"⚙️ *Workflow Failure Analysis: {run_name}*\n{response[:2000]}"


def handle_push_event(payload, github, github_app_id, github_app_installation_id, github_app_private_key, owner, repo):
    """Generate intelligent commit summary using AI."""
    branch = payload.get("ref", "").replace("refs/heads/", "")
    pusher = payload.get("pusher", {}).get("name", "Unknown")
    commits = payload.get("commits", [])

    print(f"[GIT RADAR][PUSH] Branch={branch}, Pusher={pusher}, Commits={len(commits)}")

    if not commits:
        msg = f"Push to `{branch}` by {pusher} — no commits."
        print(f"[GIT RADAR][PUSH] {msg}")
        return msg

    commit_details = []
    for c in commits[:5]:
        sha_short = c.get('id', '')[:7]
        msg_line = c.get('message', '').splitlines()[0]
        added = len(c.get('added', []))
        modified = len(c.get('modified', []))
        removed = len(c.get('removed', []))
        commit_details.append(f"  • `{sha_short}` {msg_line} (+{added} ~{modified} -{removed})")

    print(f"[GIT RADAR][PUSH] Commit count: {len(commits)}")

    # Try AI summary via Copilot — skip if unavailable (don't show error to user)
    summary_section = ""
    try:
        agent = CopilotAgent(github_app_id, github_app_installation_id, github_app_private_key)
        agent.set_system_prompt(
            "You are CORTEX Git Radar. Summarize the following git push in 1-2 sentences. "
            "Highlight any infrastructure (Terraform/CloudFormation) changes, dependency updates, "
            "or security-relevant modifications. Be concise."
        )

        summary = agent.chat(
            f"Push to `{branch}` by {pusher} ({len(commits)} commits):\n"
            + "\n".join(commit_details)
        )

        print(f"[GIT RADAR][PUSH] Copilot response success={summary.get('success')}")

        if summary.get("success"):
            ai_content = summary.get("message", {}).get("content", "")
            if ai_content:
                summary_section = f"\n\n*AI Summary:* {ai_content[:500]}"
        else:
            print(f"[GIT RADAR][PUSH] Copilot unavailable: {summary.get('error')}")
    except Exception as e:
        print(f"[GIT RADAR][PUSH] Copilot EXCEPTION (skipping AI summary): {e}")

    # Build result - show commits instead of AI error if AI fails
    result = (
        f"📝 *Push to {owner}/{repo}*\n"
        f"*Branch:* `{branch}` | *By:* {pusher}\n"
        f"*Commits:* {len(commits)}\n"
        + "\n".join(commit_details[:3])  # Show first 3 commits
        + (f"\n_...and {len(commits) - 3} more_" if len(commits) > 3 else "")
        + summary_section
    )
    
    print(f"[GIT RADAR][PUSH] Final result (first 300): {result[:300]}")
    return result


def handle_create_event(payload):
    """Notify on new branch or tag creation."""
    ref = payload.get("ref", "unknown")
    ref_type = payload.get("ref_type", "branch")
    sender = payload.get("sender", {}).get("login", "Unknown")
    repo = payload.get("repository", {}).get("full_name", "unknown/repo")

    print(f"[GIT RADAR][CREATE] ref_type={ref_type}, ref={ref}, sender={sender}")

    emoji = "🌿" if ref_type == "branch" else "🏷️"
    label = "branch" if ref_type == "branch" else "tag"

    return (
        f"{emoji} *New {label} created*\n"
        f"*{label.capitalize()}:* `{ref}`\n"
        f"*Repo:* `{repo}`\n"
        f"*By:* {sender}"
    )


# ---------------------------------------------------------------------------
# Tool Implementations
# ---------------------------------------------------------------------------

def _get_file_content(github, owner, repo, args):
    ref = args.get("ref", "main")
    result = github.get_repo_content(owner, repo, args["file_path"], ref=ref)
    if result["status"] == 200:
        content_b64 = result["data"].get("content", "")
        try:
            return base64.b64decode(content_b64).decode("utf-8")[:10000]
        except Exception:
            return "Could not decode file."
    return f"Could not fetch file (HTTP {result['status']})"


def _get_pr_diff(github, owner, repo, args):
    """Get PR changed files."""
    http = urllib3.PoolManager()
    url = f"https://api.github.com/repos/{owner}/{repo}/pulls/{args['pr_number']}/files"
    resp = http.request("GET", url, headers={
        "Authorization": f"token {github.pat}",
        "Accept": "application/vnd.github+json",
        "User-Agent": "CORTEX-Agent",
    })
    if resp.status != 200:
        return f"Could not fetch PR diff (HTTP {resp.status})"

    files = json.loads(resp.data.decode("utf-8"))
    output = []
    for f in files[:15]:
        filename = f.get("filename", "")
        status = f.get("status", "")
        additions = f.get("additions", 0)
        deletions = f.get("deletions", 0)
        patch = f.get("patch", "")[:2000]
        output.append(
            f"### {filename} ({status}, +{additions}/-{deletions})\n```diff\n{patch}\n```"
        )
    return "\n\n".join(output) if output else "No files changed."


def _post_pr_review_comment(github, owner, repo, args):
    result = github.add_pr_comment(owner, repo, args["pr_number"], args["comment"])
    if result["status"] in (200, 201):
        return f"✅ Review comment posted on PR #{args['pr_number']}"
    return f"Error posting comment: {result['data']}"


def _get_failed_workflows(github, owner, repo):
    result = github.get_workflow_runs(owner, repo, status="failure")
    if result["status"] != 200:
        return f"Error fetching workflows: {result['data']}"
    runs = result["data"].get("workflow_runs", [])[:5]
    if not runs:
        return "No recent failed workflows."
    output = []
    for r in runs:
        output.append(f"- Run ID: {r['id']} | {r.get('name', 'unknown')} | {r.get('conclusion', '')}")
    return "\n".join(output)


def _get_workflow_job_logs(github, owner, repo, args):
    result = github.get_workflow_run_logs(owner, repo, args["run_id"])
    if result["status"] != 200:
        return f"Error fetching job logs: {result['data']}"
    jobs = result["data"].get("jobs", [])
    output = []
    for job in jobs:
        job_name = job.get("name", "unknown")
        conclusion = job.get("conclusion", "unknown")
        output.append(f"\n**Job: {job_name}** → {conclusion}")
        for step in job.get("steps", []):
            step_status = "❌" if step.get("conclusion") == "failure" else "✅"
            output.append(f"  {step_status} {step.get('name', 'unknown')}")
    return "\n".join(output)


def _create_remediation_issue(github, owner, repo, args):
    labels = args.get("labels", ["bug", "ci-failure", "auto-detected"])
    result = github.create_issue(owner, repo, args["title"], args["body"], labels)
    if result["status"] in (200, 201):
        return f"✅ Issue created: {result['data'].get('html_url', '')}"
    return f"Error creating issue: {result['data']}"


def _rerun_workflow(github, owner, repo, args):
    result = github.rerun_workflow(owner, repo, args["run_id"])
    if result["status"] in (200, 201):
        return f"✅ Workflow run {args['run_id']} re-triggered."
    return f"Error rerunning workflow: {result['data']}"


# ---------------------------------------------------------------------------
# Telegram Dashboard (with DynamoDB state)
# ---------------------------------------------------------------------------

def update_telegram_dashboard(token, chat_id, message, topic_id=""):
    """Send/update Telegram dashboard message with DynamoDB state tracking."""
    # Get existing message ID from DynamoDB
    try:
        response = table.get_item(Key={"id": "telegram_dashboard"})
        existing_msg_id = response.get("Item", {}).get("message_id")
    except Exception as e:
        print(f"DynamoDB read error: {str(e)}")
        existing_msg_id = None

    new_message_id = send_telegram_message(token, chat_id, message, topic_id)

    # Store new message ID
    if new_message_id:
        try:
            table.put_item(Item={
                "id": "telegram_dashboard",
                "message_id": new_message_id,
                "updated_at": datetime.utcnow().isoformat(),
            })
        except Exception as e:
            print(f"DynamoDB write error: {str(e)}")


def send_telegram_message(token, chat_id, message, topic_id=""):
    """Send Telegram message to a specific forum topic and return message ID."""
    http = urllib3.PoolManager()
    url = f"https://api.telegram.org/bot{token}/sendMessage"

    print(f"[GIT RADAR] Sending Telegram message to chat_id={chat_id}, topic_id={topic_id}, length={len(message)}")

    payload = {
        "chat_id": chat_id,
        "text": message[:4096],
        "parse_mode": "Markdown",
        "disable_web_page_preview": True,
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
        print(f"[GIT RADAR] Telegram API response status: {response.status}")
        response_body = response.data.decode("utf-8")
        print(f"[GIT RADAR] Telegram API response body: {response_body[:500]}")

        if response.status == 200:
            result = json.loads(response_body)
            msg_id = result.get("result", {}).get("message_id")
            print(f"[GIT RADAR] Telegram message sent successfully, message_id={msg_id}")
            return msg_id
        else:
            # Markdown parse failures return 400 — retry without parse_mode
            if response.status == 400 and "can't parse" in response_body.lower():
                print("[GIT RADAR] Markdown parse error — retrying as plain text")
                payload["parse_mode"] = ""
                retry = http.request(
                    "POST", url,
                    body=json.dumps(payload).encode("utf-8"),
                    headers={"Content-Type": "application/json"},
                )
                print(f"[GIT RADAR] Plain-text retry status: {retry.status}")
                if retry.status == 200:
                    result = json.loads(retry.data.decode("utf-8"))
                    return result.get("result", {}).get("message_id")
            print(f"[GIT RADAR] Telegram send FAILED: {response_body}")
            return None
    except Exception as e:
        print(f"[GIT RADAR] Telegram send EXCEPTION: {str(e)}")
        import traceback
        traceback.print_exc()
        return None
