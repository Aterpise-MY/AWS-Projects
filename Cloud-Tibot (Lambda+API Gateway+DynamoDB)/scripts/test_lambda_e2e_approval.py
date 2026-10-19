#!/usr/bin/env python3
"""
End-to-end test: Create deployment audit record → Approve via Lambda → Verify result
"""
import json
import boto3
import uuid
from datetime import datetime, timedelta
import time

# AWS clients
lambda_client = boto3.client('lambda', region_name='us-east-1')
dynamodb = boto3.resource('dynamodb', region_name='us-east-1')
secrets_client = boto3.client('secretsmanager', region_name='us-east-1')

AUDIT_TABLE = 'deployment-audit'
RBAC_TABLE = 'rbac-config'

print("=" * 80)
print("  🎯 END-TO-END CORTEX APPROVAL WORKFLOW TEST")
print("=" * 80)
print()

# Step 1: Ensure user has approver role
print("→ Step 1: Setting up RBAC for test user (3702164149)...")
try:
    rbac_table = dynamodb.Table(RBAC_TABLE)
    rbac_table.put_item(
        Item={
            'user_id': '3702164149',
            'role': 'approver',
            'name': 'Test Admin',
            'created_at': int(time.time())
        }
    )
    print("✅ User configured as approver")
except Exception as e:
    print(f"❌ Error: {e}")
    exit(1)

# Step 2: Create deployment audit record
print()
print("→ Step 2: Creating deployment audit record...")
deployment_id = f"deploy-{datetime.now().strftime('%Y%m%d-%H%M%S')}-{str(uuid.uuid4())[:8]}"
ttl = int((datetime.now() + timedelta(hours=1)).timestamp())

try:
    audit_table = dynamodb.Table(AUDIT_TABLE)
    audit_table.put_item(
        Item={
            'deployment_id': deployment_id,
            'environment': 'staging',
            'status': 'pending_approval',
            'requested_at': int(time.time()),
            'requested_by': 'github-actions',
            'ttl': ttl,
            'plan_url': 'https://github.com/Aterpise-MY/Cloud-Tibot/actions/runs/12345',
        }
    )
    print(f"✅ Created deployment: {deployment_id}")
except Exception as e:
    print(f"❌ Error: {e}")
    exit(1)

# Step 3: Get webhook secret
print()
print("→ Step 3: Fetching Telegram webhook secret...")
try:
    secret_resp = secrets_client.get_secret_value(
        SecretId='/cortex-infra/telegram-bot-secret-token'
    )
    webhook_secret = secret_resp['SecretString']
    print(f"✅ Got webhook secret")
except Exception as e:
    print(f"❌ Error: {e}")
    exit(1)

# Step 4: Invoke Lambda with approval
print()
print("→ Step 4: Invoking Lambda with approval callback...")

telegram_payload = {
    "update_id": int(time.time()),
    "callback_query": {
        "id": f"callback_{uuid.uuid4()}",
        "from": {
            "id": 3702164149,
            "is_bot": False,
            "first_name": "Admin",
            "username": "admin_user"
        },
        "chat_instance": "1234567890",
        "data": f"approve:{deployment_id}",
        "message": {
            "message_id": 545,
            "chat": {
                "id": -1003702164149,
                "type": "supergroup"
            },
            "date": int(time.time()),
            "text": "Deployment approval required"
        }
    }
}

payload_json = json.dumps(telegram_payload, separators=(',', ':'))

api_gateway_event = {
    "version": "2.0",
    "routeKey": "POST /telegram-approve",
    "rawPath": "/telegram-approve",
    "rawQueryString": "",
    "headers": {
        "X-Telegram-Bot-Api-Secret-Token": webhook_secret
    },
    "body": payload_json,
    "isBase64Encoded": False
}

try:
    response = lambda_client.invoke(
        FunctionName='cortex-telegram-approval-handler',
        InvocationType='RequestResponse',
        LogType='Tail',
        Payload=json.dumps(api_gateway_event)
    )
    
    status_code = response['StatusCode']
    response_payload = json.loads(response['Payload'].read())
    
    print(f"✅ Lambda responded with status: {status_code}")
    print(f"   Response: {json.dumps(response_payload, indent=2)}")
    
    # Check if successful
    if response_payload.get('statusCode') == 200:
        print("✅ Approval processed successfully!")
    else:
        print(f"⚠️  Lambda returned {response_payload.get('statusCode')}: {response_payload.get('body')}")
    
except Exception as e:
    print(f"❌ Error invoking Lambda: {e}")
    exit(1)

# Step 5: Verify audit record was updated
print()
print("→ Step 5: Verifying audit record was updated...")
try:
    time.sleep(2)  # Wait for DynamoDB consistency
    response = audit_table.get_item(Key={'deployment_id': deployment_id})
    item = response.get('Item', {})
    
    status = item.get('status')
    actor = item.get('actor_action')
    
    if status == 'approved':
        print(f"✅ Deployment approved by: {actor}")
    elif status == 'pending_approval':
        print(f"⚠️  Status still pending (may need more time or checking Lambda logs)")
    else:
        print(f"⚠️  Status: {status}")
    
    print(f"   Full record: {json.dumps(item, indent=2, default=str)}")
    
except Exception as e:
    print(f"❌ Error: {e}")

print()
print("=" * 80)
print("  ✅ End-to-end test complete!")
print("=" * 80)
