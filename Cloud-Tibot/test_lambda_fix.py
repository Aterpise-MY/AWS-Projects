"""
Test cortex_git_radar Lambda with push event to verify Telegram works after fix
"""
import boto3
import json
import base64

client = boto3.client("lambda", region_name="us-east-1")

# Build a test event similar to what API Gateway sends
push_body = json.dumps({
    "ref": "refs/heads/main",
    "before": "0000000000000000000000000000000000000000",
    "after": "abc123def456789",
    "repository": {
        "id": 987654321,
        "name": "Cloud-Tibot",
        "full_name": "Brendon20011007/Cloud-Tibot",
        "owner": {"login": "Brendon20011007"}
    },
    "pusher": {"name": "Brendon20011007", "email": "brendon@example.com"},
    "commits": [{
        "id": "abc123def456",
        "message": "test: verify cortex_git_radar Telegram notification fix",
        "timestamp": "2026-03-16T15:00:00Z",
        "author": {"name": "Brendon20011007", "email": "brendon@example.com"},
        "added": [],
        "modified": ["README.md"],
        "removed": []
    }],
    "head_commit": {
        "id": "abc123def456",
        "message": "test: verify cortex_git_radar Telegram notification fix"
    }
})

apigw_event = {
    "version": "2.0",
    "routeKey": "POST /webhook/github",
    "rawPath": "/webhook/github",
    "rawQueryString": "",
    "headers": {
        "content-type": "application/json",
        "x-github-event": "push",
        "x-github-delivery": "test-delivery-cortex-fix-verify",
        "host": "6w72v0646f.execute-api.us-east-1.amazonaws.com"
    },
    "body": push_body,
    "isBase64Encoded": False
}

print("Invoking cortex_git_radar with test push event...")
print("(This should not crash and should send Telegram notification)")

response = client.invoke(
    FunctionName="cortex_git_radar",
    InvocationType="RequestResponse",
    LogType="Tail",  # Get logs inline
    Payload=json.dumps(apigw_event).encode("utf-8")
)

status_code = response["StatusCode"]
func_error = response.get("FunctionError", None)
payload = json.loads(response["Payload"].read())
log_result = base64.b64decode(response.get("LogResult", "")).decode("utf-8", errors="replace")

print(f"\nHTTP Status: {status_code}")
print(f"Function Error: {func_error or 'None (success)'}")
print(f"\nResponse Payload: {json.dumps(payload, indent=2)}")
print(f"\n--- Tail Logs ---")
for line in log_result.splitlines():
    if line.strip():
        print(line)
