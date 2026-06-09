#!/usr/bin/env python3
"""
Comprehensive Webhook Event Tester
Tests all GitHub event types that are now triggered by "Send me everything" setting
"""

import json
import requests
import time
from datetime import datetime
import hashlib
import hmac

# Configuration
WEBHOOK_URL = "https://6w72v0646f.execute-api.us-east-1.amazonaws.com/webhook/github"
GITHUB_WEBHOOK_SECRET = "your-webhook-secret"  # Update if you have one

# Color codes for output
COLORS = {
    "GREEN": "\033[92m",
    "RED": "\033[91m",
    "YELLOW": "\033[93m",
    "BLUE": "\033[94m",
    "CYAN": "\033[96m",
    "END": "\033[0m",
}


def print_header(title):
    print(f"\n{COLORS['CYAN']}{'='*70}")
    print(f"  {title}")
    print(f"{'='*70}{COLORS['END']}\n")


def print_success(msg):
    print(f"{COLORS['GREEN']}✅ {msg}{COLORS['END']}")


def print_error(msg):
    print(f"{COLORS['RED']}❌ {msg}{COLORS['END']}")


def print_info(msg):
    print(f"{COLORS['BLUE']}ℹ️  {msg}{COLORS['END']}")


def print_warning(msg):
    print(f"{COLORS['YELLOW']}⚠️  {msg}{COLORS['END']}")


def sign_github_webhook(payload_body, secret):
    """Sign webhook payload like GitHub does"""
    if not secret:
        return None
    signature = hmac.new(
        secret.encode(),
        payload_body.encode(),
        hashlib.sha256
    ).hexdigest()
    return f"sha256={signature}"


def send_webhook_event(event_type, payload, description=""):
    """Send a webhook event to the API Gateway"""
    print_info(f"Testing: {description or event_type}")
    
    headers = {
        "x-github-event": event_type,
        "content-type": "application/json",
    }
    
    # Add signature if available
    payload_str = json.dumps(payload)
    signature = sign_github_webhook(payload_str, GITHUB_WEBHOOK_SECRET)
    if signature:
        headers["x-hub-signature-256"] = signature
    
    try:
        # Send the JSON payload directly - the HTTP API will handle the body
        response = requests.post(WEBHOOK_URL, data=payload_str, headers=headers, timeout=10)
        
        if response.status_code == 200:
            print_success(f"{event_type} event processed (HTTP {response.status_code})")
            try:
                result = response.json()
                print(f"  Response: {json.dumps(result, indent=2)[:200]}...")
            except:
                print(f"  Response body: {response.text[:200]}...")
            return True
        else:
            print_error(f"Failed with HTTP {response.status_code}")
            print(f"  Response: {response.text[:200]}...")
            return False
    except Exception as e:
        print_error(f"Exception: {str(e)}")
        return False


def test_push_event():
    """Test PUSH event"""
    payload = {
        "ref": "refs/heads/main",
        "before": "0000000000000000000000000000000000000000",
        "after": f"{int(time.time()):040x}"[:40],
        "repository": {
            "id": 987654321,
            "name": "IB-DND-5e-Platform",
            "full_name": "Aterpise-MY/IB-DND-5e-Platform",
            "owner": {"login": "Aterpise-MY"}
        },
        "pusher": {
            "name": "Test User",
            "email": "test@example.com"
        },
        "commits": [
            {
                "id": f"{int(time.time()):040x}"[:40],
                "message": "Test: Webhook push event from 'Send me everything' config",
                "timestamp": datetime.now().isoformat(),
                "author": {
                    "name": "Test User",
                    "email": "test@example.com"
                },
                "added": ["test-file.txt"],
                "modified": [],
                "removed": []
            }
        ]
    }
    return send_webhook_event("push", payload, "PUSH event (commit)")


def test_pull_request_event():
    """Test PULL_REQUEST event"""
    payload = {
        "action": "opened",
        "number": 42,
        "pull_request": {
            "id": 123456789,
            "number": 42,
            "title": "Test: PR from webhook test",
            "body": "This is a test PR for webhook validation",
            "state": "open",
            "user": {
                "login": "test-user",
                "type": "User"
            },
            "html_url": "https://github.com/Aterpise-MY/IB-DND-5e-Platform/pull/42",
            "created_at": datetime.now().isoformat(),
            "updated_at": datetime.now().isoformat(),
            "merged": False
        },
        "repository": {
            "id": 987654321,
            "name": "IB-DND-5e-Platform",
            "full_name": "Aterpise-MY/IB-DND-5e-Platform",
            "owner": {"login": "Aterpise-MY"}
        }
    }
    return send_webhook_event("pull_request", payload, "PULL_REQUEST event (opened)")


def test_pull_request_review_event():
    """Test PULL_REQUEST_REVIEW event"""
    payload = {
        "action": "submitted",
        "review": {
            "id": 987654321,
            "user": {"login": "reviewer"},
            "body": "Looks good to me!",
            "state": "APPROVED",
            "submitted_at": datetime.now().isoformat()
        },
        "pull_request": {
            "id": 123456789,
            "number": 42,
            "title": "Test: PR from webhook test",
            "user": {"login": "test-user"},
            "html_url": "https://github.com/Aterpise-MY/IB-DND-5e-Platform/pull/42"
        },
        "repository": {
            "id": 987654321,
            "name": "IB-DND-5e-Platform",
            "full_name": "Aterpise-MY/IB-DND-5e-Platform",
            "owner": {"login": "Aterpise-MY"}
        }
    }
    return send_webhook_event("pull_request_review", payload, "PULL_REQUEST_REVIEW event (submitted)")


def test_issues_event():
    """Test ISSUES event"""
    payload = {
        "action": "opened",
        "issue": {
            "id": 1234567890,
            "number": 100,
            "title": "Test: Issue from webhook test",
            "body": "This is a test issue",
            "user": {"login": "test-user"},
            "state": "open",
            "html_url": "https://github.com/Aterpise-MY/IB-DND-5e-Platform/issues/100",
            "created_at": datetime.now().isoformat()
        },
        "repository": {
            "id": 987654321,
            "name": "IB-DND-5e-Platform",
            "full_name": "Aterpise-MY/IB-DND-5e-Platform",
            "owner": {"login": "Aterpise-MY"}
        }
    }
    return send_webhook_event("issues", payload, "ISSUES event (opened)")


def test_workflow_run_event():
    """Test WORKFLOW_RUN event"""
    payload = {
        "action": "completed",
        "workflow_run": {
            "id": 987654321,
            "name": "Test Workflow",
            "head_branch": "main",
            "head_sha": f"{int(time.time()):040x}"[:40],
            "status": "completed",
            "conclusion": "failure",
            "created_at": datetime.now().isoformat(),
            "updated_at": datetime.now().isoformat(),
            "html_url": "https://github.com/Aterpise-MY/IB-DND-5e-Platform/actions/runs/987654321"
        },
        "repository": {
            "id": 987654321,
            "name": "IB-DND-5e-Platform",
            "full_name": "Aterpise-MY/IB-DND-5e-Platform",
            "owner": {"login": "Aterpise-MY"}
        }
    }
    return send_webhook_event("workflow_run", payload, "WORKFLOW_RUN event (completed with failure)")


def test_create_event():
    """Test CREATE event (branch/tag creation)"""
    payload = {
        "ref": "feature/test-branch",
        "ref_type": "branch",
        "description": "Test feature branch",
        "master_branch": "main",
        "repository": {
            "id": 987654321,
            "name": "IB-DND-5e-Platform",
            "full_name": "Aterpise-MY/IB-DND-5e-Platform",
            "owner": {"login": "Aterpise-MY"}
        },
        "sender": {
            "login": "test-user",
            "type": "User"
        }
    }
    return send_webhook_event("create", payload, "CREATE event (new branch)")


def test_release_event():
    """Test RELEASE event"""
    payload = {
        "action": "published",
        "release": {
            "id": 123456789,
            "tag_name": "v1.0.0",
            "name": "Version 1.0.0",
            "body": "Initial release",
            "draft": False,
            "prerelease": False,
            "created_at": datetime.now().isoformat(),
            "published_at": datetime.now().isoformat(),
            "html_url": "https://github.com/Aterpise-MY/IB-DND-5e-Platform/releases/tag/v1.0.0"
        },
        "repository": {
            "id": 987654321,
            "name": "IB-DND-5e-Platform",
            "full_name": "Aterpise-MY/IB-DND-5e-Platform",
            "owner": {"login": "Aterpise-MY"}
        }
    }
    return send_webhook_event("release", payload, "RELEASE event (published)")


def test_member_event():
    """Test MEMBER event (user added to repo)"""
    payload = {
        "action": "added",
        "member": {
            "login": "new-collaborator",
            "type": "User"
        },
        "repository": {
            "id": 987654321,
            "name": "IB-DND-5e-Platform",
            "full_name": "Aterpise-MY/IB-DND-5e-Platform",
            "owner": {"login": "Aterpise-MY"}
        }
    }
    return send_webhook_event("member", payload, "MEMBER event (collaborator added)")


def test_fork_event():
    """Test FORK event"""
    payload = {
        "forkee": {
            "id": 999888777,
            "name": "IB-DND-5e-Platform",
            "full_name": "forked-user/IB-DND-5e-Platform",
            "owner": {"login": "forked-user"},
            "html_url": "https://github.com/forked-user/IB-DND-5e-Platform"
        },
        "repository": {
            "id": 987654321,
            "name": "IB-DND-5e-Platform",
            "full_name": "Aterpise-MY/IB-DND-5e-Platform",
            "owner": {"login": "Aterpise-MY"}
        }
    }
    return send_webhook_event("fork", payload, "FORK event (repo forked)")


def test_watch_event():
    """Test WATCH event (star added)"""
    payload = {
        "action": "started",
        "repository": {
            "id": 987654321,
            "name": "IB-DND-5e-Platform",
            "full_name": "Aterpise-MY/IB-DND-5e-Platform",
            "owner": {"login": "Aterpise-MY"},
            "stargazers_count": 42
        },
        "sender": {
            "login": "star-user",
            "type": "User"
        }
    }
    return send_webhook_event("watch", payload, "WATCH event (star added)")


def main():
    print_header("🚀 COMPREHENSIVE WEBHOOK EVENT TESTER")
    print_info(f"Webhook URL: {WEBHOOK_URL}")
    print_info(f"Testing all event types with 'Send me everything' config")
    print_info(f"Timestamp: {datetime.now().isoformat()}")
    
    # Run all tests
    tests = [
        ("PUSH Events", test_push_event),
        ("PULL_REQUEST Events", test_pull_request_event),
        ("PULL_REQUEST_REVIEW Events", test_pull_request_review_event),
        ("ISSUES Events", test_issues_event),
        ("WORKFLOW_RUN Events", test_workflow_run_event),
        ("CREATE Events", test_create_event),
        ("RELEASE Events", test_release_event),
        ("MEMBER Events", test_member_event),
        ("FORK Events", test_fork_event),
        ("WATCH Events", test_watch_event),
    ]
    
    results = {}
    for test_name, test_func in tests:
        try:
            print_header(test_name)
            result = test_func()
            results[test_name] = "✅ PASSED" if result else "❌ FAILED"
            time.sleep(1)  # Rate limiting
        except Exception as e:
            print_error(f"Test crashed: {e}")
            results[test_name] = "❌ CRASHED"
            time.sleep(1)
    
    # Summary
    print_header("📊 TEST SUMMARY")
    for test_name, result in results.items():
        print(f"{result}: {test_name}")
    
    passed = sum(1 for r in results.values() if "✅" in r)
    total = len(results)
    print_info(f"\nPassed: {passed}/{total}")
    
    # Next steps
    print_header("✅ VERIFICATION CHECKLIST")
    print("""
1. ✅ Check Lambda CloudWatch logs:
   aws logs tail /aws/lambda/cortex_git_radar --follow

2. ✅ Verify Telegram Topic 111 received notifications:
   - Check CORTEX Git Radar topic in Telegram
   - Should see messages for each event type

3. ✅ Check API Gateway logs:
   aws logs tail /aws/apigateway/cortex-chatops-api --follow

4. ✅ Verify no 500 errors in GitHub webhook deliveries

5. ✅ Check DynamoDB state table:
   aws dynamodb scan --table-name cortex_radar_state --region us-east-1
    """)


if __name__ == "__main__":
    main()
