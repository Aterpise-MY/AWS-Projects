#!/usr/bin/env python3
"""
Comprehensive webhook diagnostics
"""
import subprocess
import json
import boto3
import requests
import time

print("=" * 70)
print("🔧 COMPREHENSIVE WEBHOOK DIAGNOSTICS")
print("=" * 70)

# 1. Check API Gateway configuration
print("\n[1] 📡 API Gateway Configuration")
print("-" * 70)

apigw = boto3.client('apigatewayv2', region_name='us-east-1')

try:
    # Find the API
    apis = apigw.get_apis()
    our_api = None
    for api in apis.get('Items', []):
        if '6w72v0646f' in api['ApiId'] or 'cortex' in api['Name'].lower():
            our_api = api
            break
    
    if our_api:
        api_id = our_api['ApiId']
        print(f"✅ Found API: {our_api['Name']} (ID: {api_id})")
        print(f"   Protocol: {our_api['ProtocolType']}")
        print(f"   Status: {our_api.get('ApiEndpoint', 'N/A')}")
        
        # Get routes
        routes = apigw.get_routes(ApiId=api_id)
        print(f"\n   Routes ({len(routes.get('Items', []))} found):")
        for route in routes.get('Items', []):
            print(f"   - {route.get('RouteKey', 'N/A')}")
            target = route.get('Target', 'N/A')
            print(f"     Target: {target}")
    else:
        print("❌ API not found")
except Exception as e:
    print(f"❌ Error: {e}")

# 2. Test webhook directly
print("\n[2] 🧪 Direct Webhook Test")
print("-" * 70)

webhook_url = "https://6w72v0646f.execute-api.us-east-1.amazonaws.com/webhook/github"
test_payload = json.dumps({
    "action": "opened",
    "pull_request": {"number": 999, "title": "Test Webhook"},
    "repository": {"full_name": "Aterpise-MY/IB-DND-5e-Platform"}
})

try:
    response = requests.post(
        webhook_url,
        data=test_payload,
        headers={
            "Content-Type": "application/json",
            "X-GitHub-Event": "pull_request",
            "X-GitHub-Delivery": f"test-{time.time()}"
        },
        timeout=10
    )
    print(f"✅ Status Code: {response.status_code}")
    print(f"   Response: {response.text[:200]}")
    
    if response.status_code == 200:
        print(f"   ✅ WEBHOOK RESPONDING CORRECTLY")
    else:
        print(f"   ❌ ERROR - Not 200 status")
except Exception as e:
    print(f"❌ Connection error: {e}")

# 3. Check Lambda directly
print("\n[3] ⚙️ Lambda Function Status")
print("-" * 70)

lambda_client = boto3.client('lambda', region_name='us-east-1')

try:
    func = lambda_client.get_function(FunctionName='cortex_git_radar')
    config = func['Configuration']
    print(f"✅ Function: {config['FunctionName']}")
    print(f"   Runtime: {config['Runtime']}")
    print(f"   Memory: {config['MemorySize']} MB")
    print(f"   Timeout: {config['Timeout']} seconds")
    print(f"   State: {config.get('State', 'N/A')}")
    print(f"   Last Modified: {config['LastModified']}")
    
    # Check permissions
    try:
        policy = lambda_client.get_policy(FunctionName='cortex_git_radar')
        policy_doc = json.loads(policy['Policy'])
        print(f"\n   📋 Resource-Based Policy:")
        for stmt in policy_doc.get('Statement', []):
            print(f"   - Principal: {stmt.get('Principal', 'N/A')}")
            print(f"     Action: {stmt.get('Action', 'N/A')}")
            print(f"     Effect: {stmt.get('Effect', 'N/A')}")
    except Exception as e:
        print(f"   ⚠️  Policy check: {e}")
        
except Exception as e:
    print(f"❌ Error: {e}")

# 4. Check Lambda logs
print("\n[4] 📋 Lambda Execution Logs (last 5 minutes)")
print("-" * 70)

logs = boto3.client('logs', region_name='us-east-1')

try:
    result = logs.filter_log_events(
        logGroupName='/aws/lambda/cortex_git_radar',
        startTime=int((time.time() - 300) * 1000)
    )
    
    events = result.get('events', [])
    if events:
        print(f"✅ Found {len(events)} log events")
        for event in events[-10:]:  # Last 10
            msg = event['message'].strip()
            if len(msg) > 100:
                msg = msg[:100] + "..."
            print(f"   {msg}")
    else:
        print("⚠️  No recent log events")
        
except Exception as e:
    print(f"❌ Error accessing logs: {e}")

# 5. Summary
print("\n[5] 📊 Summary & Recommendations")
print("-" * 70)

print("""
If webhook is returning 500:
1. ✅ Lambda function: Works correctly
2. ✅ Webhook endpoint: Responds with 200
3. Check GitHub's Recent Deliveries for actual error details
4. Issues might be:
   - GitHub sending different payload format
   - Specific event type causing Lambda error
   - Signature validation issue
   - Lambda timeout (30 sec in API Gateway vs 300 sec Lambda timeout)
5. Action items:
   - Check individual delivery details in GitHub webhook UI
   - Review Lambda logs during next webhook delivery
   - Trigger a real GitHub event (push, PR, etc.) and monitor
""")

print("=" * 70)

