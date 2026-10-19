#!/usr/bin/env python3
"""
Demo: See new rich Telegram messages for Approve/Reject actions
"""
import json
import boto3
import uuid
import time

lambda_client = boto3.client('lambda', region_name='us-east-1')
secrets_client = boto3.client('secretsmanager', region_name='us-east-1')
dynamodb = boto3.resource('dynamodb', region_name='us-east-1')

print("=" * 80)
print("  🎨 TERRAFORM APPROVAL MESSAGE DEMO")
print("=" * 80)
print()

# Setup
rbac_table = dynamodb.Table('rbac-config')
audit_table = dynamodb.Table('deployment-audit')

# Create approver user
rbac_table.put_item(Item={
    'user_id': '3702164149',
    'role': 'approver',
    'name': 'Demo Admin'
})

# Create deployment
deployment_id = f"demo-{int(time.time())}"
audit_table.put_item(Item={
    'deployment_id': deployment_id,
    'environment': 'staging',
    'status': 'pending_approval',
    'requested_at': int(time.time()),
    'requested_by': 'github-actions',
    'ttl': int(time.time() + 3600),
    'plan_url': 'https://github.com/Aterpise-MY/Cloud-Tibot/actions/runs/12345'
})

# Get webhook secret
secret = secrets_client.get_secret_value(SecretId='/cortex-infra/telegram-bot-secret-token')
webhook_secret = secret['SecretString']

# Test APPROVE message
print("→ Testing APPROVE message...")
payload = {
    "update_id": int(time.time()),
    "callback_query": {
        "id": f"cb_{uuid.uuid4()}",
        "from": {"id": 3702164149, "is_bot": False, "first_name": "Admin", "username": "admin_user"},
        "chat_instance": "1234567890",
        "data": f"approve:{deployment_id}",
        "message": {
            "message_id": 545,
            "chat": {"id": -1003702164149, "type": "supergroup"},
            "date": int(time.time()),
            "text": "Deployment approval"
        }
    }
}

event = {
    "version": "2.0",
    "rawPath": "/telegram-approve",
    "headers": {"X-Telegram-Bot-Api-Secret-Token": webhook_secret},
    "body": json.dumps(payload),
    "isBase64Encoded": False
}

response = lambda_client.invoke(
    FunctionName='cortex-telegram-approval-handler',
    InvocationType='RequestResponse',
    Payload=json.dumps(event)
)

result = json.loads(response['Payload'].read())
print(f"✅ Lambda returned: {result['statusCode']}")
print()

# Show what the Telegram message looks like
print("=" * 80)
print("  📱 TELEGRAM MESSAGE - APPROVE EXAMPLE")
print("=" * 80)
print()
print("""
✅ TERRAFORM DEPLOYMENT APPROVED

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
📋 Deployment Details
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
🆔 ID: `demo-1715610120`
🌍 Environment: `STAGING`
👤 Approved by: @admin_user
⏱️ Decision Time: 3s

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
📊 What Happens Next
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
1️⃣ Terraform APPLY will now execute
2️⃣ Changes will be applied to STAGING
3️⃣ Deployment logs available in GitHub Actions
4️⃣ Completion notification will be sent here

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
⏳ Estimated completion: 5-10 minutes
📝 Requested by: github-actions
🔗 View Plan Details (link to GitHub)
""")

print()
print("=" * 80)
print("  📱 TELEGRAM MESSAGE - REJECT EXAMPLE")
print("=" * 80)
print()
print("""
❌ TERRAFORM DEPLOYMENT REJECTED

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
📋 Deployment Details
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
🆔 ID: `demo-1715610120`
🌍 Environment: `STAGING`
👤 Rejected by: @admin_user
⏱️ Decision Time: 45s

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
📊 What Happens Next
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
1️⃣ Terraform APPLY has been CANCELLED
2️⃣ No changes will be applied
3️⃣ STAGING infrastructure remains unchanged
4️⃣ Review and retry the plan when ready

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
💡 To proceed with deployment:
   Review the plan and request a new approval
📝 Requested by: github-actions
🔗 Review Plan (link to GitHub)
""")

print()
print("=" * 80)
print("  🚀 PLAN REQUEST MESSAGE")
print("=" * 80)
print()
print("""
⏳ Terraform Plan Requested

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
🌍 Environment: `STAGING`
👤 Requested by: @user_name
⏱️ Time: `1715610120`
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

📊 What Happens Next:
1️⃣ GitHub Actions workflow triggered
2️⃣ Terraform PLAN will execute
3️⃣ Plan results sent to this channel
4️⃣ Approval request will appear below

⏳ Estimated wait time: 2-5 minutes

🔗 Monitor in GitHub Actions
💡 You will receive approval buttons once the plan is ready
""")

print()
print("=" * 80)
print("  ✨ Features of New Messages:")
print("=" * 80)
print("""
✅ Clear status indicators (✅ ❌ ⏳)
✅ Detailed deployment information
✅ Step-by-step next actions
✅ Estimated timelines
✅ Links to relevant resources
✅ Professional formatting with dividers
✅ Emoji for visual clarity
✅ User attribution for actions
✅ Approval/decision timing
✅ Error handling with solutions
""")
