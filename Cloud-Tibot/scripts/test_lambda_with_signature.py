#!/usr/bin/env python3
"""
Test Lambda approval handler simulating API Gateway webhook
"""
import json
import hmac
import hashlib
import boto3
import requests
from datetime import datetime

# AWS clients
lambda_client = boto3.client('lambda', region_name='us-east-1')
secrets_client = boto3.client('secretsmanager', region_name='us-east-1')

print("=" * 80)
print("  🔐 LAMBDA TEST WITH VALID TELEGRAM SIGNATURE (API Gateway format)")
print("=" * 80)
print()

# Step 1: Get the Telegram webhook secret
print("→ Step 1: Fetching Telegram webhook secret...")
try:
    secret_resp = secrets_client.get_secret_value(
        SecretId='/cortex-infra/telegram-bot-secret-token'
    )
    webhook_secret = secret_resp['SecretString']
    print(f"✅ Got webhook secret")
except Exception as e:
    print(f"❌ Error: {e}")
    exit(1)

# Step 2: Create valid Telegram webhook payload
print()
print("→ Step 2: Creating Telegram webhook payload with token header...")

telegram_payload = {
    "update_id": 1234567890,
    "callback_query": {
        "id": "callback_query_123",
        "from": {
            "id": 3702164149,
            "is_bot": False,
            "first_name": "Admin",
            "username": "admin_user"
        },
        "chat_instance": "1234567890",
        "data": "approve:deploy-20240512-test001",
        "message": {
            "message_id": 545,
            "chat": {
                "id": -1003702164149,
                "type": "supergroup"
            },
            "date": 1715528400,
            "text": "Deployment approval required"
        }
    }
}

# Telegram webhook uses X-Telegram-Bot-Api-Secret-Token header (plain token, not signature)
payload_json = json.dumps(telegram_payload, separators=(',', ':'))

# Create API Gateway event format
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

print(f"✅ Token sent: {webhook_secret[:20]}...")
print(f"   Payload size: {len(payload_json)} bytes")
print()

# Step 3: Invoke Lambda with API Gateway event
print("→ Step 3: Invoking Lambda with valid signature...")
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
    print()
    
    # Show logs
    if 'LogResult' in response:
        import base64
        logs = base64.b64decode(response['LogResult']).decode('utf-8')
        print("→ Lambda execution logs:")
        for line in logs.split('\n')[-20:]:  # Last 20 lines
            if line.strip():
                print(f"   {line}")
    
except Exception as e:
    print(f"❌ Error invoking Lambda: {e}")
    import traceback
    traceback.print_exc()
    exit(1)

print()
print("=" * 80)
print("  ✅ Test complete!")
print("=" * 80)
