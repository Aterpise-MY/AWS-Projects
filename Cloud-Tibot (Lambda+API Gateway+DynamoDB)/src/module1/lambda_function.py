"""
Project CORTEX - Module 1: Auto-Remediator
AI-Powered AWS Amplify Build Monitor with Rich Telegram Notifications
+ Automatic Retry on Build Failures

Triggered by EventBridge on ANY AWS Amplify build status change
(STARTED, SUCCEED, FAILED) for ALL Amplify apps in the account.

Features:
  - Status-specific rich Telegram notifications (Started, Success, Failed)
  - Auto-retry: triggers a rebuild when FAILED is detected (max 1 retry)
  - Prevents infinite retry loops by checking recent job history
  - Cross-region aware: Amplify may be in a different region than Lambda
  - Auto-routed to "Auto-Remediator" Telegram forum topic
"""

import json
import os
import boto3
import urllib3
from datetime import datetime

# Maximum number of auto-retries per branch per failed build
MAX_AUTO_RETRIES = 1


# ---------------------------------------------------------------------------
# Lambda Handler
# ---------------------------------------------------------------------------
def lambda_handler(event, context):
    """
    Main entry point. Receives EventBridge Amplify build status change events
    for ALL Amplify apps and sends rich, status-specific Telegram notifications.

    On FAILED status, attempts to auto-retry the build (max 1 retry per failure).
    """
    print(f"[AUTO-REMEDIATOR] Event received: {json.dumps(event)}")

    # Extract event details
    detail = event.get("detail", {})
    app_id = detail.get("appId", "Unknown")
    branch_name = detail.get("branchName", "Unknown")
    job_id = detail.get("jobId", "Unknown")
    job_status = detail.get("jobStatus", "Unknown")
    commit_id = detail.get("commitId", "")
    commit_message = detail.get("commitMessage", "")
    commit_time = detail.get("commitTime", "")

    print(f"[AUTO-REMEDIATOR] App={app_id}, Branch={branch_name}, Status={job_status}, Job={job_id}")

    # Environment variables
    telegram_token = os.environ["TELEGRAM_TOKEN"]
    telegram_chat_id = os.environ["TELEGRAM_CHAT_ID"]
    telegram_topic_id = os.environ.get("TELEGRAM_TOPIC_ID", "")
    # Amplify may live in a different region than this Lambda
    amplify_region = os.environ.get("AMPLIFY_REGION", os.environ.get("AWS_REGION", "us-east-1"))
    aws_region = os.environ.get("AWS_REGION", "us-east-1")

    # Create Amplify client for the correct region
    amplify_client = boto3.client("amplify", region_name=amplify_region)

    # Try to get the app name from Amplify
    app_name = app_id
    try:
        app_resp = amplify_client.get_app(appId=app_id)
        app_name = app_resp.get("app", {}).get("name", app_id)
        print(f"[AUTO-REMEDIATOR] Resolved app name: {app_name}")
    except Exception as e:
        print(f"[AUTO-REMEDIATOR] Could not fetch app name: {e}")

    # Build Amplify console link (use amplify_region for console URL)
    console_url = (
        f"https://{amplify_region}.console.aws.amazon.com/amplify/home"
        f"?region={amplify_region}#/{app_id}/{branch_name}/{job_id}"
    )

    # Build commit display
    commit_display = f"`{commit_id[:7]}`" if commit_id else "N/A"
    commit_msg_line = f"\n*Commit:* {commit_display}"
    if commit_message:
        # Truncate commit message to first line only
        commit_first_line = commit_message.split("\n")[0][:80]
        commit_msg_line += f" — _{commit_first_line}_"

    # -----------------------------------------------------------------------
    # AUTO-RETRY LOGIC: On FAILED, check if we should retry
    # -----------------------------------------------------------------------
    retry_triggered = False
    retry_job_id = None

    if job_status == "FAILED":
        retry_triggered, retry_job_id = attempt_auto_retry(
            amplify_client, app_id, app_name, branch_name, job_id
        )

    # Build status-specific message (include retry info if applicable)
    telegram_message = build_status_message(
        job_status, app_name, app_id, branch_name, job_id,
        commit_msg_line, console_url, commit_time,
        retry_triggered=retry_triggered, retry_job_id=retry_job_id
    )

    print(f"[AUTO-REMEDIATOR] Sending Telegram notification (topic_id={telegram_topic_id})")
    send_telegram_message(telegram_token, telegram_chat_id, telegram_message, telegram_topic_id)

    return {
        "statusCode": 200,
        "body": json.dumps({
            "message": f"Telegram notification sent for {job_status}",
            "app_id": app_id,
            "app_name": app_name,
            "branch": branch_name,
            "status": job_status,
            "topic_id": telegram_topic_id,
            "retry_triggered": retry_triggered,
            "retry_job_id": retry_job_id,
        }),
    }


# ---------------------------------------------------------------------------
# Auto-Retry Logic
# ---------------------------------------------------------------------------
def attempt_auto_retry(amplify_client, app_id, app_name, branch_name, failed_job_id):
    """
    Attempt to auto-retry a failed Amplify build.

    Safety guards:
    - Checks recent build history to count consecutive failures
    - Only retries if there have been fewer than MAX_AUTO_RETRIES consecutive failures
    - This prevents infinite retry loops

    Returns:
        tuple: (retry_triggered: bool, retry_job_id: str or None)
    """
    print(f"[AUTO-RETRY] Evaluating retry for app={app_id}, branch={branch_name}, failed_job={failed_job_id}")

    try:
        # List recent jobs to check for consecutive failures
        jobs_resp = amplify_client.list_jobs(
            appId=app_id,
            branchName=branch_name,
            maxResults=5
        )
        jobs = jobs_resp.get("jobSummaries", [])

        if not jobs:
            print("[AUTO-RETRY] No job history found, proceeding with retry")
        else:
            # Count consecutive FAILED jobs (most recent first)
            consecutive_failures = 0
            for job in jobs:
                if job.get("status") == "FAILED":
                    consecutive_failures += 1
                else:
                    break

            print(f"[AUTO-RETRY] Consecutive failures: {consecutive_failures}, max allowed: {MAX_AUTO_RETRIES}")

            if consecutive_failures > MAX_AUTO_RETRIES:
                print(f"[AUTO-RETRY] SKIPPING retry — {consecutive_failures} consecutive failures exceeds limit")
                return False, None

        # Trigger a new build via RETRY first, fall back to RELEASE
        retry_job_id = None
        try:
            print(f"[AUTO-RETRY] Attempting RETRY job for app={app_id}, branch={branch_name}")
            retry_resp = amplify_client.start_job(
                appId=app_id,
                branchName=branch_name,
                jobType="RETRY",
                jobId=failed_job_id
            )
            retry_job_id = retry_resp.get("jobSummary", {}).get("jobId")
            print(f"[AUTO-RETRY] RETRY triggered successfully, new job_id={retry_job_id}")
            return True, retry_job_id

        except amplify_client.exceptions.LimitExceededException:
            print("[AUTO-RETRY] RETRY rate limited, trying RELEASE instead")
        except Exception as e:
            print(f"[AUTO-RETRY] RETRY failed ({e}), trying RELEASE instead")

        # Fallback: start a fresh RELEASE build
        try:
            print(f"[AUTO-RETRY] Attempting RELEASE job for app={app_id}, branch={branch_name}")
            release_resp = amplify_client.start_job(
                appId=app_id,
                branchName=branch_name,
                jobType="RELEASE"
            )
            retry_job_id = release_resp.get("jobSummary", {}).get("jobId")
            print(f"[AUTO-RETRY] RELEASE triggered successfully, new job_id={retry_job_id}")
            return True, retry_job_id

        except Exception as e:
            print(f"[AUTO-RETRY] RELEASE also failed: {e}")
            return False, None

    except Exception as e:
        print(f"[AUTO-RETRY] Error during retry evaluation: {e}")
        import traceback
        traceback.print_exc()
        return False, None


# ---------------------------------------------------------------------------
# Status-Specific Message Builder
# ---------------------------------------------------------------------------
def build_status_message(status, app_name, app_id, branch, job_id, commit_line, console_url, commit_time,
                         retry_triggered=False, retry_job_id=None):
    """Build rich, status-specific Telegram messages with contextual information."""
    
    if status == "STARTED":
        return (
            f"🚀 **Build Started**\n"
            f"━━━━━━━━━━━━━━━━━━━━━━\n\n"
            f"*App:* `{app_name}`\n"
            f"*Branch:* `{branch}`"
            f"{commit_line}\n"
            f"*Job ID:* `{job_id}`\n\n"
            f"⏳ Build is now in progress...\n\n"
            f"[View Live Build →]({console_url})"
        )
    
    elif status == "SUCCEED":
        timestamp = datetime.utcnow().strftime("%H:%M UTC")
        return (
            f"✅ **Build Succeeded**\n"
            f"━━━━━━━━━━━━━━━━━━━━━━\n\n"
            f"*App:* `{app_name}`\n"
            f"*Branch:* `{branch}`"
            f"{commit_line}\n"
            f"*Completed:* {timestamp}\n\n"
            f"🎉 Deployment successful!\n\n"
            f"[View Deployment →]({console_url})"
        )
    
    elif status == "FAILED":
        # Include retry info if auto-retry was triggered
        retry_section = ""
        if retry_triggered and retry_job_id:
            retry_section = (
                f"\n\n🔄 *Auto-Retry Triggered*\n"
                f"New Job ID: `{retry_job_id}`\n"
                f"A rebuild has been automatically started."
            )
        elif retry_triggered:
            retry_section = (
                f"\n\n🔄 *Auto-Retry Triggered*\n"
                f"A rebuild has been automatically started."
            )
        else:
            retry_section = (
                f"\n\n⚠️ *Auto-Retry Skipped*\n"
                f"Max consecutive retries reached. Manual intervention needed."
            )

        return (
            f"🚨 **BUILD FAILED**\n"
            f"━━━━━━━━━━━━━━━━━━━━━━\n\n"
            f"*App:* `{app_name}`\n"
            f"*Branch:* `{branch}`"
            f"{commit_line}\n"
            f"*Job ID:* `{job_id}`\n"
            f"*Status:* ❌ FAILED"
            f"{retry_section}\n\n"
            f"[View Error Logs →]({console_url})\n"
            f"[Troubleshoot Build →](https://docs.aws.amazon.com/amplify/latest/userguide/troubleshooting.html)"
        )
    
    elif status == "CANCELLING":
        return (
            f"⏸️ **Build Cancelling**\n"
            f"━━━━━━━━━━━━━━━━━━━━━━\n\n"
            f"*App:* `{app_name}`\n"
            f"*Branch:* `{branch}`\n"
            f"*Job ID:* `{job_id}`\n\n"
            f"Build is being cancelled...\n\n"
            f"[View Console →]({console_url})"
        )
    
    elif status == "CANCELLED":
        return (
            f"🚫 **Build Cancelled**\n"
            f"━━━━━━━━━━━━━━━━━━━━━━\n\n"
            f"*App:* `{app_name}`\n"
            f"*Branch:* `{branch}`\n"
            f"*Job ID:* `{job_id}`\n\n"
            f"Build was cancelled by user.\n\n"
            f"[View Console →]({console_url})"
        )
    
    else:
        # Fallback for unknown statuses
        return (
            f"ℹ️ **Amplify Build Status Update**\n"
            f"━━━━━━━━━━━━━━━━━━━━━━\n\n"
            f"*App:* `{app_name}`\n"
            f"*Branch:* `{branch}`\n"
            f"*Status:* `{status}`"
            f"{commit_line}\n"
            f"*Job ID:* `{job_id}`\n\n"
            f"[View Console →]({console_url})"
        )


# ---------------------------------------------------------------------------
# Telegram notification
# ---------------------------------------------------------------------------
def send_telegram_message(token, chat_id, message, topic_id=""):
    """Send a message to Telegram Bot API, routed to Auto-Remediator forum topic."""
    http = urllib3.PoolManager()
    url = f"https://api.telegram.org/bot{token}/sendMessage"
    
    print(f"[AUTO-REMEDIATOR] Sending to chat_id={chat_id}, topic_id={topic_id}, length={len(message)}")
    
    payload = {
        "chat_id": chat_id,
        "text": message[:4096],
        "parse_mode": "Markdown",
        "disable_web_page_preview": False,  # Allow preview for Amplify console links
    }
    
    # Route to Auto-Remediator forum topic
    if topic_id:
        payload["message_thread_id"] = int(topic_id)
    
    try:
        response = http.request(
            "POST", url,
            body=json.dumps(payload).encode("utf-8"),
            headers={"Content-Type": "application/json"},
        )
        
        response_body = response.data.decode("utf-8")
        print(f"[AUTO-REMEDIATOR] Telegram API response: {response.status}")
        
        if response.status == 200:
            result = json.loads(response_body)
            msg_id = result.get("result", {}).get("message_id")
            print(f"[AUTO-REMEDIATOR] Telegram message sent successfully, message_id={msg_id}")
            return msg_id
        else:
            # Markdown parse failures return 400 — retry without parse_mode
            if response.status == 400 and "can't parse" in response_body.lower():
                print("[AUTO-REMEDIATOR] Markdown parse error — retrying as plain text")
                payload["parse_mode"] = ""
                retry = http.request(
                    "POST", url,
                    body=json.dumps(payload).encode("utf-8"),
                    headers={"Content-Type": "application/json"},
                )
                if retry.status == 200:
                    result = json.loads(retry.data.decode("utf-8"))
                    msg_id = result.get("result", {}).get("message_id")
                    print(f"[AUTO-REMEDIATOR] Plain-text retry succeeded, message_id={msg_id}")
                    return msg_id
            
            print(f"[AUTO-REMEDIATOR] Telegram send FAILED: {response_body}")
            return None
    except Exception as e:
        print(f"[AUTO-REMEDIATOR] Telegram send EXCEPTION: {str(e)}")
        import traceback
        traceback.print_exc()
        return None

