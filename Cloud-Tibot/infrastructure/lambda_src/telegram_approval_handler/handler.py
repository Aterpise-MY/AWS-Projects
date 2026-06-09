"""
Project CORTEX — Telegram Approval Handler (Module 5)

Receives Telegram updates via API Gateway webhook and handles:
  1. Inline button callbacks — approve / reject a pending deployment
  2. /deploy <env> slash command — trigger a terraform-plan-requested dispatch

This Lambda is completely isolated from Modules 1-3.
It uses its own IAM role, its own DynamoDB tables (deployment-audit, rbac-config),
and fetches all secrets from AWS Secrets Manager at runtime.

Environment Variables (non-sensitive, set by Terraform):
  DYNAMODB_RBAC_TABLE         — rbac-config table name
  DYNAMODB_AUDIT_TABLE        — deployment-audit table name
  GITHUB_REPOSITORY           — owner/repo for repository_dispatch
  GITHUB_TOKEN_SECRET_NAME    — SM secret name for GitHub PAT
  TELEGRAM_SECRET_NAME        — SM secret name for webhook validation token
  TELEGRAM_BOT_TOKEN_SECRET   — SM secret name for Bot API token
  TELEGRAM_TOPIC_ID           — Forum thread ID (236) for all messages
"""

import os
import json
import hmac
import time
import logging

import boto3
import requests
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# ---------------------------------------------------------------------------
# AWS clients — initialised once per cold start (shared across invocations)
# ---------------------------------------------------------------------------
_secrets_client = boto3.client('secretsmanager', region_name='us-east-1')
_dynamodb = boto3.resource('dynamodb', region_name='us-east-1')

# ---------------------------------------------------------------------------
# Environment variables
# ---------------------------------------------------------------------------
RBAC_TABLE = os.environ['DYNAMODB_RBAC_TABLE']
AUDIT_TABLE = os.environ['DYNAMODB_AUDIT_TABLE']
GITHUB_REPOSITORY = os.environ['GITHUB_REPOSITORY']
GITHUB_SECRET_NAME = os.environ['GITHUB_TOKEN_SECRET_NAME']
TELEGRAM_SECRET_NAME = os.environ['TELEGRAM_SECRET_NAME']
TELEGRAM_BOT_TOKEN_SECRET = os.environ['TELEGRAM_BOT_TOKEN_SECRET']
TELEGRAM_TOPIC_ID = os.environ.get('TELEGRAM_TOPIC_ID', '')


# ---------------------------------------------------------------------------
# Secrets Manager helper
# ---------------------------------------------------------------------------

def _get_secret(secret_name: str) -> str:
    """Fetch a plaintext secret from Secrets Manager."""
    response = _secrets_client.get_secret_value(SecretId=secret_name)
    return response['SecretString']


# ---------------------------------------------------------------------------
# Webhook validation
# ---------------------------------------------------------------------------

def _validate_telegram_webhook(headers: dict) -> bool:
    """Compare X-Telegram-Bot-Api-Secret-Token header using constant-time comparison."""
    try:
        expected = _get_secret(TELEGRAM_SECRET_NAME)
    except ClientError:
        logger.error('Failed to fetch webhook secret token from Secrets Manager')
        return False
    received = headers.get('X-Telegram-Bot-Api-Secret-Token', '')
    return hmac.compare_digest(received, expected)


# ---------------------------------------------------------------------------
# DynamoDB helpers
# ---------------------------------------------------------------------------

def _get_user_role(telegram_user_id: str) -> str | None:
    """Return the role string for a Telegram user, or None if not found."""
    table = _dynamodb.Table(RBAC_TABLE)
    try:
        response = table.get_item(Key={'user_id': str(telegram_user_id)})
        item = response.get('Item')
        return item['role'] if item else None
    except ClientError as exc:
        logger.error('DynamoDB error fetching RBAC for user_id=%s: %s', telegram_user_id, exc)
        return None


def _get_audit_record(deployment_id: str) -> dict | None:
    """Fetch a deployment record from the audit table."""
    table = _dynamodb.Table(AUDIT_TABLE)
    try:
        response = table.get_item(Key={'deployment_id': deployment_id})
        return response.get('Item')
    except ClientError as exc:
        logger.error('DynamoDB error fetching audit record %s: %s', deployment_id, exc)
        return None


def _update_audit_status(deployment_id: str, status: str, actor: str) -> None:
    """Update the status, actor, and action timestamp on an audit record."""
    table = _dynamodb.Table(AUDIT_TABLE)
    table.update_item(
        Key={'deployment_id': deployment_id},
        UpdateExpression='SET #s = :s, actor_action = :ab, action_at = :ts',
        ExpressionAttributeNames={'#s': 'status'},
        ExpressionAttributeValues={
            ':s': status,
            ':ab': actor,
            ':ts': int(time.time()),
        },
    )


# ---------------------------------------------------------------------------
# GitHub repository_dispatch
# ---------------------------------------------------------------------------

def _trigger_github_dispatch(event_type: str, payload: dict, retries: int = 3) -> bool:
    """POST a repository_dispatch event to GitHub with exponential backoff."""
    try:
        github_token = _get_secret(GITHUB_SECRET_NAME)
    except ClientError:
        logger.error('Failed to fetch GitHub token from Secrets Manager')
        return False

    url = f'https://api.github.com/repos/{GITHUB_REPOSITORY}/dispatches'
    headers = {
        'Accept': 'application/vnd.github+json',
        'Authorization': f'Bearer {github_token}',
        'X-GitHub-Api-Version': '2022-11-28',
    }
    body = {'event_type': event_type, 'client_payload': payload}

    for attempt in range(retries):
        try:
            resp = requests.post(url, json=body, headers=headers, timeout=10)
            if resp.status_code == 204:
                logger.info('repository_dispatch triggered: %s', event_type)
                return True
            logger.warning(
                'Attempt %d/%d failed: HTTP %s — %s',
                attempt + 1, retries, resp.status_code, resp.text,
            )
        except requests.RequestException as exc:
            logger.warning('Attempt %d/%d exception: %s', attempt + 1, retries, exc)

        if attempt < retries - 1:
            time.sleep(2 ** attempt)  # 1 s, 2 s, 4 s

    return False


# ---------------------------------------------------------------------------
# Telegram messaging helper
# ---------------------------------------------------------------------------

def _send_telegram_message(chat_id: str, text: str, bot_token: str) -> None:
    """Send a message to a Telegram chat, routed to the infra topic (236)."""
    payload: dict = {
        'chat_id': chat_id,
        'text': text,
        'parse_mode': 'Markdown',
    }
    if TELEGRAM_TOPIC_ID:
        payload['message_thread_id'] = int(TELEGRAM_TOPIC_ID)

    try:
        resp = requests.post(
            f'https://api.telegram.org/bot{bot_token}/sendMessage',
            json=payload,
            timeout=10,
        )
        if not resp.ok:
            logger.warning('Telegram sendMessage failed: %s', resp.text)
    except requests.RequestException as exc:
        logger.warning('Telegram sendMessage exception: %s', exc)


# ---------------------------------------------------------------------------
# Callback query handler (inline button press: approve / reject)
# ---------------------------------------------------------------------------

def _handle_callback_query(callback_query: dict, bot_token: str) -> dict:
    user = callback_query['from']
    user_id = str(user['id'])
    username = user.get('username', user_id)
    chat_id = str(callback_query['message']['chat']['id'])
    callback_data = callback_query.get('data', '')

    # Parse "approve:deploy-20240101-abc1234" or "reject:..."
    try:
        action, deployment_id = callback_data.split(':', 1)
    except ValueError:
        logger.warning('Malformed callback_data: %s', callback_data)
        return {'statusCode': 400, 'body': 'Malformed callback_data'}

    if action not in ('approve', 'reject'):
        return {'statusCode': 400, 'body': 'Unknown action'}

    # RBAC check
    role = _get_user_role(user_id)
    if role not in ('approver', 'deployer'):
        _send_telegram_message(
            chat_id,
            (
                f'🚫 *Permission Denied*\n\n'
                f'@{username}, you do not have permission to approve or reject deployments.\n\n'
                f'━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
                f'📌 *Required Roles:*\n'
                f'  • `approver` - Can approve/reject deployments\n'
                f'  • `deployer` - Can manage deployments\n\n'
                f'👤 *Your Current Role:* `{role or "none"}`\n'
                f'━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n'
                f'📞 Contact your administrator for access.'
            ),
            bot_token,
        )
        logger.warning('Unauthorized attempt by user_id=%s role=%s', user_id, role)
        return {'statusCode': 403, 'body': 'Unauthorized'}

    # Fetch audit record
    audit = _get_audit_record(deployment_id)
    if not audit:
        _send_telegram_message(
            chat_id,
            (
                f'❌ *Deployment Not Found*\n\n'
                f'━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
                f'🆔 Deployment ID: `{deployment_id}`\n'
                f'━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n'
                f'⚠️ This deployment record does not exist in the database.\n\n'
                f'📋 *Possible Reasons:*\n'
                f'  • Deployment ID is incorrect\n'
                f'  • Record has expired (1 hour TTL)\n'
                f'  • System error during plan creation\n\n'
                f'💡 Please request a new Terraform plan.'
            ),
            bot_token,
        )
        return {'statusCode': 404, 'body': 'Not found'}

    current_status = audit.get('status')
    if current_status != 'pending_approval':
        _send_telegram_message(
            chat_id,
            (
                f'⚠️ *Deployment Already Processed*\n\n'
                f'━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
                f'🆔 Deployment ID: `{deployment_id}`\n'
                f'📊 Current Status: `{current_status.upper()}`\n'
                f'━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n'
                f'This deployment has already been {current_status}.\n'
                f'No further action can be taken.\n\n'
                f'💡 Request a new deployment plan to proceed.'
            ),
            bot_token,
        )
        return {'statusCode': 409, 'body': 'Already processed'}

    if int(time.time()) > int(audit.get('ttl', 0)):
        _send_telegram_message(
            chat_id,
            (
                f'⏰ *Approval Request Expired*\n\n'
                f'━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
                f'🆔 Deployment ID: `{deployment_id}`\n'
                f'⏳ TTL: 1 hour from creation\n'
                f'━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n'
                f'This approval request has expired and can no longer be processed.\n\n'
                f'🔄 *What To Do:*\n'
                f'1. Re-run the Terraform plan\n'
                f'2. A new approval request will be sent\n'
                f'3. Approve/reject with the new request\n\n'
                f'💡 Use `/deploy {audit.get("environment", "env")}` to restart.'
            ),
            bot_token,
        )
        return {'statusCode': 410, 'body': 'Expired'}

    # Trigger GitHub dispatch
    environment = audit.get('environment', 'unknown')
    event_type = 'terraform-apply-approved' if action == 'approve' else 'terraform-apply-rejected'
    payload = {
        'approval_id': deployment_id,
        'approved_by': username if action == 'approve' else None,
        'rejected_by': username if action == 'reject' else None,
        'environment': environment,
    }

    if not _trigger_github_dispatch(event_type, payload):
        _send_telegram_message(
            chat_id,
            (
                f'❌ *Deployment Dispatch Failed*\n\n'
                f'━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
                f'🆔 Deployment ID: `{deployment_id}`\n'
                f'🌍 Environment: `{environment.upper()}`\n'
                f'👤 Processed by: @{username}\n'
                f'📋 Action: {action.upper()}\n'
                f'━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n'
                f'⚠️ *Error:* Failed to dispatch to GitHub after 3 retries\n\n'
                f'🔍 *Diagnosis:*\n'
                f'  • GitHub API may be unreachable\n'
                f'  • Authentication token may be invalid\n'
                f'  • Repository dispatch webhook may be misconfigured\n\n'
                f'🔧 *Recovery:*\n'
                f'1. Check GitHub Actions status\n'
                f'2. Verify GitHub token in Secrets Manager\n'
                f'3. Contact #devops team\n\n'
                f'📝 *Note:* The deployment approval has been recorded but not applied.\n'
                f'🔗 [View GitHub Actions](https://github.com/Aterpise-MY/Cloud-Tibot/actions)'
            ),
            bot_token,
        )
        logger.error('Failed to trigger repository_dispatch for %s', deployment_id)
        return {'statusCode': 502, 'body': 'GitHub dispatch failed'}

    # Update audit table
    new_status = 'approved' if action == 'approve' else 'rejected'
    _update_audit_status(deployment_id, new_status, username)

    # Get additional audit details for rich message
    plan_url = audit.get('plan_url', '')
    requested_by = audit.get('requested_by', 'unknown')
    requested_at = int(audit.get('requested_at', 0))
    action_at = int(time.time())
    
    # Calculate deployment time
    deploy_duration = action_at - requested_at
    duration_str = f"{deploy_duration}s" if deploy_duration < 60 else f"{deploy_duration // 60}m {deploy_duration % 60}s"

    # Build rich confirmation message
    if action == 'approve':
        confirm = (
            f'✅ *TERRAFORM DEPLOYMENT APPROVED*\n\n'
            f'━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
            f'📋 *Deployment Details*\n'
            f'━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
            f'🆔 ID: `{deployment_id}`\n'
            f'🌍 Environment: `{environment.upper()}`\n'
            f'👤 Approved by: @{username}\n'
            f'⏱️ Decision Time: {duration_str}\n\n'
            f'━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
            f'📊 *What Happens Next*\n'
            f'━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
            f'1️⃣ Terraform APPLY will now execute\n'
            f'2️⃣ Changes will be applied to {environment.upper()}\n'
            f'3️⃣ Deployment logs available in GitHub Actions\n'
            f'4️⃣ Completion notification will be sent here\n\n'
            f'━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
            f'⏳ Estimated completion: 5-10 minutes\n'
            f'📝 Requested by: {requested_by}'
        )
        if plan_url:
            confirm += f'\n🔗 [View Plan Details]({plan_url})'
    else:
        confirm = (
            f'❌ *TERRAFORM DEPLOYMENT REJECTED*\n\n'
            f'━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
            f'📋 *Deployment Details*\n'
            f'━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
            f'🆔 ID: `{deployment_id}`\n'
            f'🌍 Environment: `{environment.upper()}`\n'
            f'👤 Rejected by: @{username}\n'
            f'⏱️ Decision Time: {duration_str}\n\n'
            f'━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
            f'📊 *What Happens Next*\n'
            f'━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
            f'1️⃣ Terraform APPLY has been CANCELLED\n'
            f'2️⃣ No changes will be applied\n'
            f'3️⃣ {environment.upper()} infrastructure remains unchanged\n'
            f'4️⃣ Review and retry the plan when ready\n\n'
            f'━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
            f'💡 To proceed with deployment:\n'
            f'   Review the plan and request a new approval\n'
            f'📝 Requested by: {requested_by}'
        )
        if plan_url:
            confirm += f'\n🔗 [Review Plan]({plan_url})'

    _send_telegram_message(chat_id, confirm, bot_token)
    logger.info('Action=%s deployment_id=%s by=%s duration=%s', action, deployment_id, username, duration_str)
    return {'statusCode': 200, 'body': 'OK'}


# ---------------------------------------------------------------------------
# /deploy slash command handler
# ---------------------------------------------------------------------------

def _handle_deploy_command(message: dict, bot_token: str) -> dict:
    """Handle /deploy <env> slash command from an authorised Telegram user."""
    user = message['from']
    user_id = str(user['id'])
    username = user.get('username', user_id)
    chat_id = str(message['chat']['id'])
    text = message.get('text', '').strip()

    # Parse: /deploy dev  or  /deploy staging  or  /deploy production
    parts = text.split()
    if len(parts) < 2:
        _send_telegram_message(
            chat_id,
            (
                '❌ *Invalid Command*\n\n'
                'Usage: `/deploy <environment>`\n\n'
                '📌 *Available Environments:*\n'
                '  • `dev` - Development\n'
                '  • `staging` - Staging\n'
                '  • `production` - Production\n\n'
                '💡 *Example:*\n'
                '`/deploy staging`'
            ),
            bot_token,
        )
        return {'statusCode': 200, 'body': 'Missing environment'}

    environment = parts[1].lower()
    allowed_envs = ('dev', 'staging', 'production', 'prod')
    if environment not in allowed_envs:
        _send_telegram_message(
            chat_id,
            (
                f'❌ *Unknown Environment: `{environment}`*\n\n'
                '📌 *Allowed Environments:*\n'
                '  • `dev` - Development\n'
                '  • `staging` - Staging\n'
                '  • `production` - Production\n\n'
                '🔗 Please use one of the above environments.'
            ),
            bot_token,
        )
        return {'statusCode': 200, 'body': 'Invalid environment'}

    # RBAC check — only approvers and deployers can trigger plans
    role = _get_user_role(user_id)
    if role not in ('approver', 'deployer'):
        _send_telegram_message(
            chat_id,
            (
                f'🚫 *Permission Denied*\n\n'
                f'@{username}, you do not have permission to trigger deployments.\n\n'
                f'📌 *Required Role:* `approver` or `deployer`\n'
                f'👤 *Your Role:* `{role or "none"}`\n\n'
                f'Contact your administrator for access.'
            ),
            bot_token,
        )
        logger.warning('/deploy by unauthorized user_id=%s role=%s', user_id, role)
        return {'statusCode': 403, 'body': 'Unauthorized'}

    # Trigger plan dispatch — pipeline will send approval buttons when plan is ready
    payload = {
        'environment': environment,
        'requested_by': username,
    }

    if not _trigger_github_dispatch('terraform-plan-requested', payload):
        _send_telegram_message(
            chat_id,
            (
                f'❌ *Terraform Plan Failed*\n\n'
                f'━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
                f'Environment: `{environment.upper()}`\n'
                f'Requested by: @{username}\n'
                f'━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n'
                f'⚠️ *Error:* GitHub API unreachable after 3 retries\n\n'
                f'📋 *Actions:*\n'
                f'1. Check GitHub Actions status\n'
                f'2. Verify GitHub token is valid\n'
                f'3. Contact #devops team\n\n'
                f'🔗 [View GitHub Actions](https://github.com/Aterpise-MY/Cloud-Tibot/actions)'
            ),
            bot_token,
        )
        logger.error('/deploy failed to trigger plan dispatch for env=%s', environment)
        return {'statusCode': 502, 'body': 'GitHub dispatch failed'}

    _send_telegram_message(
        chat_id,
        (
            f'⏳ *Terraform Plan Requested*\n\n'
            f'━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
            f'🌍 Environment: `{environment.upper()}`\n'
            f'👤 Requested by: @{username}\n'
            f'⏱️ Time: `{int(time.time())}`\n'
            f'━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n'
            f'📊 *What Happens Next:*\n'
            f'1️⃣ GitHub Actions workflow triggered\n'
            f'2️⃣ Terraform PLAN will execute\n'
            f'3️⃣ Plan results sent to this channel\n'
            f'4️⃣ Approval request will appear below\n\n'
            f'⏳ Estimated wait time: 2-5 minutes\n\n'
            f'🔗 [Monitor in GitHub Actions](https://github.com/Aterpise-MY/Cloud-Tibot/actions)\n'
            f'💡 You will receive approval buttons once the plan is ready'
        ),
        bot_token,
    )
    logger.info('/deploy env=%s by=%s', environment, username)
    return {'statusCode': 200, 'body': 'OK'}


# ---------------------------------------------------------------------------
# Lambda entry point
# ---------------------------------------------------------------------------

def lambda_handler(event, context):  # noqa: ARG001
    # 1. Validate Telegram webhook secret header
    if not _validate_telegram_webhook(event.get('headers', {})):
        logger.warning('Invalid webhook token — request rejected')
        return {'statusCode': 403, 'body': 'Forbidden'}

    try:
        body = json.loads(event.get('body', '{}'))
    except json.JSONDecodeError:
        logger.warning('Malformed JSON body')
        return {'statusCode': 400, 'body': 'Bad Request'}

    try:
        bot_token = _get_secret(TELEGRAM_BOT_TOKEN_SECRET)
    except ClientError:
        logger.error('Failed to fetch bot token from Secrets Manager')
        return {'statusCode': 500, 'body': 'Internal Server Error'}

    # 2a. Inline button callback (approve / reject)
    callback_query = body.get('callback_query')
    if callback_query:
        return _handle_callback_query(callback_query, bot_token)

    # 2b. Text message — check for /deploy command
    message = body.get('message')
    if message:
        text = message.get('text', '')
        if text.startswith('/deploy'):
            return _handle_deploy_command(message, bot_token)

    # Ignore all other update types (edited_message, inline_query, etc.)
    return {'statusCode': 200, 'body': 'No action'}
