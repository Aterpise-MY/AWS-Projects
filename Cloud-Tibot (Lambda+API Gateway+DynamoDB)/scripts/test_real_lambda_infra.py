#!/usr/bin/env python3
"""
Test real Lambda function in AWS for CORTEX Infra Pipeline approval handler

This script:
1. Invokes the real cortex-telegram-approval-handler Lambda
2. Sends a Telegram webhook callback (approval decision)
3. Monitors the response
4. Checks DynamoDB audit logs
5. Verifies the entire approval flow works
"""

import json
import boto3
import requests
from datetime import datetime

# AWS Configuration
AWS_REGION = "us-east-1"
LAMBDA_FUNCTION = "cortex-telegram-approval-handler"
DYNAMODB_AUDIT_TABLE = "deployment-audit"

# Telegram Configuration
TELEGRAM_BOT_TOKEN = "8281522719:AAHb8gk-sIVpjnGmOIYbE5FuzZ347J4FKTc"
TELEGRAM_CHAT_ID = "-1003702164149"
TELEGRAM_TOPIC_ID = 236

# ============================================================================
# Colored Output
# ============================================================================

class Colors:
    HEADER = '\033[95m'
    BLUE = '\033[94m'
    CYAN = '\033[96m'
    GREEN = '\033[92m'
    YELLOW = '\033[93m'
    RED = '\033[91m'
    END = '\033[0m'
    BOLD = '\033[1m'

def print_header(text):
    print(f"\n{Colors.BOLD}{Colors.CYAN}{'=' * 80}{Colors.END}")
    print(f"{Colors.BOLD}{Colors.CYAN}  {text}{Colors.END}")
    print(f"{Colors.BOLD}{Colors.CYAN}{'=' * 80}{Colors.END}\n")

def print_section(text):
    print(f"\n{Colors.BOLD}{Colors.BLUE}{'─' * 80}{Colors.END}")
    print(f"{Colors.BOLD}{Colors.BLUE}  {text}{Colors.END}")
    print(f"{Colors.BOLD}{Colors.BLUE}{'─' * 80}{Colors.END}\n")

def print_success(text):
    print(f"{Colors.GREEN}✅ {text}{Colors.END}")

def print_info(text):
    print(f"{Colors.CYAN}ℹ️  {text}{Colors.END}")

def print_warning(text):
    print(f"{Colors.YELLOW}⚠️  {text}{Colors.END}")

def print_error(text):
    print(f"{Colors.RED}❌ {text}{Colors.END}")

def print_step(num, text):
    print(f"{Colors.YELLOW}→ Step {num}: {text}{Colors.END}")

# ============================================================================
# Lambda Invocation
# ============================================================================

def invoke_lambda(approval_status="approve"):
    """Invoke the real Lambda function with a Telegram webhook callback"""
    print_step(1, "Invoking Real Lambda Function")
    
    try:
        lambda_client = boto3.client('lambda', region_name=AWS_REGION)
        
        # Create Telegram webhook payload
        payload = {
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
                "data": f"{'approve' if approval_status == 'approve' else 'reject'}_deployment"
            }
        }
        
        print_info(f"Payload: {json.dumps(payload, indent=2)}")
        
        # Invoke Lambda
        response = lambda_client.invoke(
            FunctionName=LAMBDA_FUNCTION,
            InvocationType='RequestResponse',
            Payload=json.dumps(payload)
        )
        
        # Parse response
        status_code = response['StatusCode']
        response_payload = json.loads(response['Payload'].read())
        
        print_info(f"HTTP Status Code: {status_code}")
        
        if status_code == 200:
            print_success("Lambda invoked successfully")
            print_info(f"Response: {json.dumps(response_payload, indent=2)}")
            return response_payload
        else:
            print_error(f"Lambda returned error: {status_code}")
            print_info(f"Response: {json.dumps(response_payload, indent=2)}")
            return None
            
    except Exception as e:
        print_error(f"Error invoking Lambda: {str(e)}")
        return None

# ============================================================================
# Telegram Notification
# ============================================================================

def send_approval_request():
    """Send approval request to Telegram"""
    print_step(2, "Sending Approval Request to Telegram")
    
    try:
        message_text = (
            "🚀 *CORTEX Infra Terraform Testing*\n\n"
            "📋 *Test:* Real Lambda approval workflow\n"
            "🔗 *Status:* Testing terraform approval and Telegram integration\n\n"
            "⏳ *Awaiting Real Infrastructure Test*\n"
            "Terraform plan with 15 -target flags ready"
        )
        
        payload = {
            "chat_id": TELEGRAM_CHAT_ID,
            "text": message_text,
            "parse_mode": "Markdown",
            "message_thread_id": TELEGRAM_TOPIC_ID,
            "reply_markup": {
                "inline_keyboard": [
                    [
                        {"text": "✅ Approve", "callback_data": "approve_deployment"},
                        {"text": "❌ Reject", "callback_data": "reject_deployment"}
                    ]
                ]
            }
        }
        
        response = requests.post(
            f"https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/sendMessage",
            json=payload,
            timeout=30
        )
        
        if response.status_code == 200:
            result = response.json()
            if result.get("ok"):
                message_id = result.get('result', {}).get('message_id')
                print_success(f"Approval request sent to Telegram (Message ID: {message_id})")
                return message_id
        
        print_error(f"Failed to send Telegram message: {response.text}")
        return None
        
    except Exception as e:
        print_error(f"Error sending Telegram message: {str(e)}")
        return None

# ============================================================================
# Audit Log Verification
# ============================================================================

def check_audit_logs():
    """Check DynamoDB audit logs for the approval decision"""
    print_step(3, "Checking DynamoDB Audit Logs")
    
    try:
        dynamodb = boto3.client('dynamodb', region_name=AWS_REGION)
        
        response = dynamodb.scan(
            TableName=DYNAMODB_AUDIT_TABLE,
            Limit=5,
            ScanIndexForward=False
        )
        
        items = response.get('Items', [])
        
        if items:
            print_success(f"Found {len(items)} audit log entries")
            for idx, item in enumerate(items, 1):
                timestamp = item.get('timestamp', {}).get('S', 'N/A')
                user_id = item.get('user_id', {}).get('S', 'N/A')
                action = item.get('action', {}).get('S', 'N/A')
                print_info(f"  {idx}. User: {user_id} | Action: {action} | Time: {timestamp}")
            return True
        else:
            print_warning("No audit log entries found")
            return False
            
    except Exception as e:
        print_error(f"Error checking audit logs: {str(e)}")
        return False

# ============================================================================
# Lambda Logs Verification
# ============================================================================

def check_lambda_logs():
    """Check CloudWatch logs for Lambda execution"""
    print_step(4, "Checking CloudWatch Lambda Logs")
    
    try:
        logs_client = boto3.client('logs', region_name=AWS_REGION)
        
        log_group = f"/aws/lambda/{LAMBDA_FUNCTION}"
        
        # Describe log streams
        response = logs_client.describe_log_streams(
            logGroupName=log_group,
            orderBy='LastEventTime',
            descending=True,
            limit=1
        )
        
        streams = response.get('logStreams', [])
        
        if streams:
            latest_stream = streams[0]
            stream_name = latest_stream.get('logStreamName')
            
            print_success(f"Found log stream: {stream_name}")
            
            # Get log events
            log_response = logs_client.get_log_events(
                logGroupName=log_group,
                logStreamName=stream_name,
                limit=10
            )
            
            events = log_response.get('events', [])
            if events:
                print_info(f"Latest {len(events)} log entries:")
                for event in events[-5:]:
                    message = event.get('message', '').strip()
                    if message:
                        print_info(f"  {message}")
                return True
        else:
            print_warning("No log streams found")
            return False
            
    except Exception as e:
        print_error(f"Error checking logs: {str(e)}")
        return False

# ============================================================================
# Health Check
# ============================================================================

def health_check():
    """Verify all infrastructure components are healthy"""
    print_step(5, "Infrastructure Health Check")
    
    checks_passed = 0
    total_checks = 0
    
    # Check 1: Lambda function
    total_checks += 1
    try:
        lambda_client = boto3.client('lambda', region_name=AWS_REGION)
        response = lambda_client.get_function_configuration(FunctionName=LAMBDA_FUNCTION)
        state = response.get('State', 'Unknown')
        if state == 'Active':
            print_success(f"Lambda function active: {LAMBDA_FUNCTION}")
            checks_passed += 1
        else:
            print_warning(f"Lambda state: {state}")
    except Exception as e:
        print_error(f"Lambda check failed: {str(e)}")
    
    # Check 2: DynamoDB table
    total_checks += 1
    try:
        dynamodb = boto3.client('dynamodb', region_name=AWS_REGION)
        response = dynamodb.describe_table(TableName=DYNAMODB_AUDIT_TABLE)
        status = response['Table']['TableStatus']
        if status == 'ACTIVE':
            print_success(f"DynamoDB table active: {DYNAMODB_AUDIT_TABLE}")
            checks_passed += 1
        else:
            print_warning(f"DynamoDB status: {status}")
    except Exception as e:
        print_error(f"DynamoDB check failed: {str(e)}")
    
    # Check 3: Secrets Manager
    total_checks += 1
    try:
        secrets_client = boto3.client('secretsmanager', region_name=AWS_REGION)
        response = secrets_client.get_secret_value(SecretId='/cortex-infra/telegram-bot-token')
        if response.get('SecretString'):
            print_success("Telegram bot token accessible in Secrets Manager")
            checks_passed += 1
        else:
            print_warning("Telegram bot token not found")
    except Exception as e:
        print_error(f"Secrets check failed: {str(e)}")
    
    # Check 4: CloudWatch Logs
    total_checks += 1
    try:
        logs_client = boto3.client('logs', region_name=AWS_REGION)
        response = logs_client.describe_log_groups(
            logGroupNamePrefix=f"/aws/lambda/{LAMBDA_FUNCTION}"
        )
        if response.get('logGroups'):
            print_success(f"CloudWatch log group exists: /aws/lambda/{LAMBDA_FUNCTION}")
            checks_passed += 1
        else:
            print_warning("CloudWatch log group not found")
    except Exception as e:
        print_error(f"CloudWatch check failed: {str(e)}")
    
    print_info(f"Health checks passed: {checks_passed}/{total_checks}")
    return checks_passed >= 3

# ============================================================================
# Main
# ============================================================================

def main():
    print_header("🚀 REAL LAMBDA TEST - CORTEX INFRA APPROVAL HANDLER")
    
    print_info(f"Lambda Function: {LAMBDA_FUNCTION}")
    print_info(f"Region: {AWS_REGION}")
    print_info(f"Telegram Chat: {TELEGRAM_CHAT_ID}")
    print_info(f"Telegram Topic: {TELEGRAM_TOPIC_ID}")
    
    print_section("Test Execution")
    
    # Step 1: Send approval request to Telegram
    message_id = send_approval_request()
    
    # Step 2: Invoke real Lambda
    lambda_response = invoke_lambda(approval_status="approve")
    
    # Step 3: Check audit logs
    audit_ok = check_audit_logs()
    
    # Step 4: Check Lambda logs
    logs_ok = check_lambda_logs()
    
    # Step 5: Health check
    health_ok = health_check()
    
    # Summary
    print_section("📊 Test Summary")
    
    if lambda_response and audit_ok and logs_ok and health_ok:
        print_success("✅ ALL TESTS PASSED")
        print_info("Real Lambda approval workflow is fully functional")
    else:
        print_warning("⚠️  Some tests did not fully complete")
        print_info("Check logs for details")
    
    print_section("🎯 Results")
    print(f"""
Lambda Response: {'✅ Received' if lambda_response else '❌ Failed'}
Audit Logs: {'✅ Found' if audit_ok else '❌ Not found'}
CloudWatch Logs: {'✅ Found' if logs_ok else '❌ Not found'}
Health Check: {'✅ Passed' if health_ok else '❌ Failed'}
Telegram Message: {'✅ Sent' if message_id else '❌ Failed'}
    """)

if __name__ == "__main__":
    main()
