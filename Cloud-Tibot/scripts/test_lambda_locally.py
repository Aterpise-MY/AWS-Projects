#!/usr/bin/env python3
"""
Test Lambda handler locally to find errors
"""

import sys
import json
import os

# Set environment variables
os.environ["TELEGRAM_TOPIC_ID"] = "111"
os.environ["TELEGRAM_CHAT_ID"] = "-1003702164149"
os.environ["GITHUB_REPO_NAME"] = "IB-DND-5e-Platform"
os.environ["GITHUB_REPO_OWNER"] = "Aterpise-MY"
os.environ["TELEGRAM_TOKEN"] = "8281522719:AAHb8gk-sIVpjnGmOIYbE5FuzZ347J4FKTc"
os.environ["GITHUB_APP_ID"] = "2833634"
os.environ["GITHUB_APP_INSTALLATION_ID"] = "109164039"
os.environ["GITHUB_APP_PRIVATE_KEY"] = "IpIEa4xqv8FeigqIDPBXjuvQdHgmi8GUeb1HbZ7BfP4="
os.environ["DYNAMODB_TABLE"] = "cortex_radar_state"
os.environ["PROJECT_NAME"] = "cortex"

# Add module2 to path
sys.path.insert(0, '/Users/brendonang/Code/Cloud-Tibot/src/module2')

# Import the Lambda handler
try:
    from lambda_function import lambda_handler
    print("✅ Successfully imported lambda_handler")
except Exception as e:
    print(f"❌ Failed to import lambda_handler: {e}")
    import traceback
    traceback.print_exc()
    sys.exit(1)

# Create a test API Gateway event (HTTP API v2 format)
test_event = {
    "headers": {
        "x-github-event": "push",
        "content-type": "application/json"
    },
    "body": json.dumps({
        "ref": "refs/heads/main",
        "repository": {
            "full_name": "Aterpise-MY/IB-DND-5e-Platform",
            "id": 987654321
        },
        "commits": [
            {
                "id": "abc123",
                "message": "Test commit",
                "author": {"name": "Test User"}
            }
        ]
    })
}

# Mock Lambda context
class MockContext:
    aws_request_id = "test-request-id"
    function_name = "cortex_git_radar"
    function_version = "$LATEST"
    invoked_function_arn = "arn:aws:lambda:us-east-1:022499047467:function:cortex_git_radar"
    memory_limit_in_mb = 1024
    get_remaining_time_in_millis = lambda: 300000

# Test the handler
try:
    print("\n" + "="*70)
    print("Testing Lambda handler with PUSH event...")
    print("="*70)
    response = lambda_handler(test_event, MockContext())
    print(f"\n✅ Lambda handler executed successfully!")
    print(f"Response status: {response.get('statusCode')}")
    print(f"Response body: {response.get('body')}")
except Exception as e:
    print(f"\n❌ Lambda handler failed:")
    print(f"Error: {e}")
    import traceback
    traceback.print_exc()
