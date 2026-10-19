"""
Project CORTEX — Infrastructure Health Check (Post-Apply Verification)

Called by cortex-smart-pipeline.yml AFTER terraform apply to verify
that all critical AWS resources are healthy and operational.

Checks:
  1. API Gateway Connectivity (HTTP 200 or 403 on POST)
  2. DynamoDB Table `cortex_radar_state` status is ACTIVE
  3. EventBridge Rule for Amplify Failures is ENABLED
  4. Lambda Functions exist and are Active
"""

import os
import sys
import json
import boto3
import requests
from datetime import datetime


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
AWS_REGION = os.environ.get("AWS_REGION", "us-east-1")
ENVIRONMENT = os.environ.get("ENVIRONMENT", "prod")
PROJECT_NAME = os.environ.get("PROJECT_NAME", "cortex")

# Resource names (match Terraform naming convention)
DYNAMODB_TABLE = f"{PROJECT_NAME}_radar_state"
EVENTBRIDGE_RULE = f"{PROJECT_NAME}_amplify_build_status"
LAMBDA_FUNCTIONS = [
    f"{PROJECT_NAME}_auto_remediator",
    f"{PROJECT_NAME}_git_radar",
    f"{PROJECT_NAME}_finops_sentinel",
]

# API endpoint — try secret, fallback to auto-discovery
API_ENDPOINT = os.environ.get("CORTEX_API_ENDPOINT", "")


# ---------------------------------------------------------------------------
# Health Check Functions
# ---------------------------------------------------------------------------

def check_api_gateway() -> dict:
    """
    Verify API Gateway is reachable.
    A POST to /webhook/github with empty body should return 200 (Lambda response)
    or 403 (if auth is configured). Both indicate the gateway is alive.
    """
    result = {"name": "API Gateway Connectivity", "status": "UNKNOWN", "details": ""}

    endpoint = API_ENDPOINT
    if not endpoint:
        # Auto-discover from AWS
        try:
            client = boto3.client("apigatewayv2", region_name=AWS_REGION)
            apis = client.get_apis()["Items"]
            cortex_api = next(
                (a for a in apis if PROJECT_NAME in a.get("Name", "").lower()),
                None,
            )
            if cortex_api:
                endpoint = cortex_api["ApiEndpoint"]
            else:
                result["status"] = "FAIL"
                result["details"] = "No CORTEX API Gateway found"
                return result
        except Exception as e:
            result["status"] = "FAIL"
            result["details"] = f"Auto-discovery failed: {e}"
            return result

    try:
        url = f"{endpoint}/webhook/github"
        resp = requests.post(
            url,
            json={"event": "health_check"},
            headers={"Content-Type": "application/json"},
            timeout=15,
        )
        if resp.status_code in (200, 403):
            result["status"] = "PASS"
            result["details"] = f"HTTP {resp.status_code} from {url}"
        else:
            result["status"] = "WARN"
            result["details"] = f"HTTP {resp.status_code} from {url} (expected 200/403)"
    except requests.exceptions.RequestException as e:
        result["status"] = "FAIL"
        result["details"] = f"Connection failed: {e}"

    return result


def check_dynamodb_table() -> dict:
    """Verify DynamoDB table cortex_radar_state is ACTIVE."""
    result = {"name": f"DynamoDB Table ({DYNAMODB_TABLE})", "status": "UNKNOWN", "details": ""}

    try:
        client = boto3.client("dynamodb", region_name=AWS_REGION)
        response = client.describe_table(TableName=DYNAMODB_TABLE)
        table_status = response["Table"]["TableStatus"]

        if table_status == "ACTIVE":
            result["status"] = "PASS"
            result["details"] = f"Table status: {table_status}"
            # Check PITR
            pitr = response["Table"].get("PointInTimeRecoveryDescription", {})
            if pitr:
                result["details"] += f" | PITR: {pitr.get('PointInTimeRecoveryStatus', 'N/A')}"
        else:
            result["status"] = "FAIL"
            result["details"] = f"Table status: {table_status} (expected ACTIVE)"
    except client.exceptions.ResourceNotFoundException:
        result["status"] = "FAIL"
        result["details"] = f"Table '{DYNAMODB_TABLE}' does not exist"
    except Exception as e:
        result["status"] = "FAIL"
        result["details"] = f"Error: {e}"

    return result


def check_eventbridge_rule() -> dict:
    """Verify EventBridge rule for Amplify failures is ENABLED."""
    result = {"name": f"EventBridge Rule ({EVENTBRIDGE_RULE})", "status": "UNKNOWN", "details": ""}

    try:
        client = boto3.client("events", region_name=AWS_REGION)
        response = client.describe_rule(Name=EVENTBRIDGE_RULE)
        state = response.get("State", "UNKNOWN")
        pattern = json.loads(response.get("EventPattern", "{}"))

        if state == "ENABLED":
            result["status"] = "PASS"
            # Verify FAILED is in the pattern
            statuses = pattern.get("detail", {}).get("jobStatus", [])
            if "FAILED" in statuses:
                result["details"] = f"State: {state} | Monitors: {', '.join(statuses)}"
            else:
                result["status"] = "WARN"
                result["details"] = f"State: {state} | ⚠️ 'FAILED' not in jobStatus filter: {statuses}"
        else:
            result["status"] = "FAIL"
            result["details"] = f"State: {state} (expected ENABLED)"
    except client.exceptions.ResourceNotFoundException:
        result["status"] = "FAIL"
        result["details"] = f"Rule '{EVENTBRIDGE_RULE}' does not exist"
    except Exception as e:
        result["status"] = "FAIL"
        result["details"] = f"Error: {e}"

    return result


def check_lambda_functions() -> dict:
    """Verify all CORTEX Lambda functions exist and are Active."""
    result = {"name": "Lambda Functions", "status": "UNKNOWN", "details": ""}

    try:
        client = boto3.client("lambda", region_name=AWS_REGION)
        statuses = []
        all_active = True

        for func_name in LAMBDA_FUNCTIONS:
            try:
                response = client.get_function(FunctionName=func_name)
                state = response["Configuration"]["State"]
                runtime = response["Configuration"]["Runtime"]
                statuses.append(f"  ✅ {func_name}: {state} ({runtime})")
                if state != "Active":
                    all_active = False
            except client.exceptions.ResourceNotFoundException:
                statuses.append(f"  ❌ {func_name}: NOT FOUND")
                all_active = False
            except Exception as e:
                statuses.append(f"  ⚠️ {func_name}: Error — {e}")
                all_active = False

        result["status"] = "PASS" if all_active else "FAIL"
        result["details"] = "\n".join(statuses)
    except Exception as e:
        result["status"] = "FAIL"
        result["details"] = f"Error: {e}"

    return result


# ---------------------------------------------------------------------------
# Main Execution
# ---------------------------------------------------------------------------

def main():
    print("=" * 70)
    print(f"🏥 CORTEX Infrastructure Health Check — {ENVIRONMENT.upper()}")
    print(f"   Region: {AWS_REGION} | Time: {datetime.utcnow().isoformat()}Z")
    print("=" * 70)

    checks = [
        check_api_gateway(),
        check_dynamodb_table(),
        check_eventbridge_rule(),
        check_lambda_functions(),
    ]

    all_passed = True
    has_failures = False

    for check in checks:
        status = check["status"]
        icon = {"PASS": "✅", "WARN": "⚠️", "FAIL": "❌"}.get(status, "❓")

        print(f"\n{icon} {check['name']}: {status}")
        if check["details"]:
            for line in check["details"].split("\n"):
                print(f"   {line}")

        if status == "FAIL":
            has_failures = True
            all_passed = False
        elif status == "WARN":
            all_passed = False

    # Summary
    print("\n" + "=" * 70)
    passed = sum(1 for c in checks if c["status"] == "PASS")
    warned = sum(1 for c in checks if c["status"] == "WARN")
    failed = sum(1 for c in checks if c["status"] == "FAIL")

    print(f"📊 Results: {passed} PASS | {warned} WARN | {failed} FAIL")

    if has_failures:
        print("🔴 HEALTH CHECK FAILED — Infrastructure issues detected!")
        sys.exit(1)
    elif not all_passed:
        print("🟡 HEALTH CHECK PASSED WITH WARNINGS")
        sys.exit(0)
    else:
        print("🟢 ALL SYSTEMS OPERATIONAL")
        sys.exit(0)


if __name__ == "__main__":
    main()
