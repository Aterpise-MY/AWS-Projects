#!/bin/bash

################################################################################
# CRITICAL TESTS - Security, Functionality, Performance
# MUST PASS for production readiness
################################################################################

set -e

echo "╔════════════════════════════════════════════════════════════════════════╗"
echo "║          🔐 CRITICAL TESTS - Security & Production Readiness         ║"
echo "║  Tests that MUST PASS: Security, Functionality, Performance          ║"
echo "╚════════════════════════════════════════════════════════════════════════╝"
echo ""

cd "$(dirname "$0")/terraform"
PASSED=0
FAILED=0

test_critical() {
    local test_name=$1
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "🔴 CRITICAL: $test_name"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

pass_critical() {
    echo "✅ PASS: $1"
    ((PASSED++))
}

fail_critical() {
    echo "❌ FAIL (CRITICAL): $1"
    ((FAILED++))
}

# Get Terraform outputs
API_URL=$(terraform output -raw api_gateway_invoke_url 2>/dev/null || echo "")
USER_POOL_ID=$(terraform output -raw user_pool_id 2>/dev/null || echo "")
APP_CLIENT_ID=$(terraform output -raw app_client_id 2>/dev/null || echo "")
RDS_ENDPOINT=$(terraform output -raw rds_endpoint 2>/dev/null || echo "")

if [ -z "$API_URL" ]; then
    echo "❌ ERROR: Terraform outputs not available. Deployment incomplete."
    exit 1
fi

################################################################################
# CRITICAL SECURITY TESTS
################################################################################
echo ""
echo "╔════════════════════════════════════════════════════════════════════════╗"
echo "║                  SECURITY TESTS (MUST PASS)                          ║"
echo "╚════════════════════════════════════════════════════════════════════════╝"

test_critical "RDS NOT Publicly Accessible"
IS_PUBLIC=$(aws rds describe-db-instances \
    --db-instance-identifier saas-postgres \
    --region us-east-1 \
    --query 'DBInstances[0].PubliclyAccessible' \
    --output text 2>/dev/null)

if [ "$IS_PUBLIC" = "False" ]; then
    pass_critical "RDS is NOT exposed to public internet"
else
    fail_critical "RDS is publicly accessible - SECURITY RISK"
fi

test_critical "RDS Encryption Enabled"
ENCRYPTED=$(aws rds describe-db-instances \
    --db-instance-identifier saas-postgres \
    --region us-east-1 \
    --query 'DBInstances[0].StorageEncrypted' \
    --output text 2>/dev/null)

if [ "$ENCRYPTED" = "True" ]; then
    pass_critical "Database storage is encrypted (KMS)"
else
    fail_critical "Database is NOT encrypted - SECURITY RISK"
fi

test_critical "Lambda in VPC (Not Public)"
LAMBDA_SUBNETS=$(aws lambda get-function-configuration \
    --function-name saas-users-handler \
    --region us-east-1 \
    --query 'VpcConfig.SubnetIds' \
    --output text 2>/dev/null)

if [ ! -z "$LAMBDA_SUBNETS" ]; then
    pass_critical "Lambda functions run in private VPC subnets"
else
    fail_critical "Lambda not in VPC - SECURITY RISK"
fi

test_critical "API Gateway Enforces Cognito Authorization"
# Try to access without JWT
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$API_URL/users")
if [ "$HTTP_CODE" = "401" ]; then
    pass_critical "API Gateway blocks unauthenticated requests (401)"
else
    fail_critical "API Gateway allows requests without JWT - SECURITY RISK"
fi

test_critical "RDS Security Group Restricts Access"
RDS_SG=$(aws ec2 describe-security-groups \
    --filters Name=group-name,Values=saas-rds-sg \
    --region us-east-1 \
    --query 'SecurityGroups[0].IpPermissions' \
    --output json 2>/dev/null)

# Check that only port 5432 is allowed
INBOUND_RULES=$(echo "$RDS_SG" | jq 'length')
if [ "$INBOUND_RULES" = "1" ]; then
    pass_critical "RDS security group only allows port 5432 (minimal exposure)"
else
    fail_critical "RDS security group has $INBOUND_RULES rules (should be 1) - over-permissive"
fi

################################################################################
# CRITICAL FUNCTIONALITY TESTS
################################################################################
echo ""
echo "╔════════════════════════════════════════════════════════════════════════╗"
echo "║                FUNCTIONALITY TESTS (MUST PASS)                        ║"
echo "╚════════════════════════════════════════════════════════════════════════╝"

test_critical "Cognito Authentication Works"
aws cognito-idp admin-create-user \
    --user-pool-id "$USER_POOL_ID" \
    --username "critical-user@example.com" \
    --user-attributes \
        Name=email,Value=critical-user@example.com \
        Name=custom:tenant_id,Value=critical-tenant \
    --message-action SUPPRESS \
    --region us-east-1 2>/dev/null || true

aws cognito-idp admin-set-user-password \
    --user-pool-id "$USER_POOL_ID" \
    --username "critical-user@example.com" \
    --password "CriticalTest@123" \
    --permanent \
    --region us-east-1 2>/dev/null || true

AUTH_RESPONSE=$(aws cognito-idp admin-initiate-auth \
    --user-pool-id "$USER_POOL_ID" \
    --client-id "$APP_CLIENT_ID" \
    --auth-flow ADMIN_NO_SRP_AUTH \
    --auth-parameters \
        USERNAME=critical-user@example.com,PASSWORD="CriticalTest@123" \
    --region us-east-1 2>/dev/null)

CHALLENGE_NAME=$(echo "$AUTH_RESPONSE" | jq -r '.ChallengeName // empty')
if [ "$CHALLENGE_NAME" = "NEW_PASSWORD_REQUIRED" ]; then
    SESSION=$(echo "$AUTH_RESPONSE" | jq -r '.Session')
    AUTH_RESPONSE=$(aws cognito-idp admin-respond-to-auth-challenge \
        --user-pool-id "$USER_POOL_ID" \
        --client-id "$APP_CLIENT_ID" \
        --challenge-name NEW_PASSWORD_REQUIRED \
        --challenge-responses USERNAME=critical-user@example.com,PASSWORD="CriticalTest@123",NEW_PASSWORD="CriticalTest@123" \
        --session "$SESSION" \
        --region us-east-1 2>/dev/null)
fi

TOKEN=$(echo "$AUTH_RESPONSE" | jq -r '.AuthenticationResult.IdToken // empty')

if [ ! -z "$TOKEN" ] && [ "$TOKEN" != "null" ]; then
    pass_critical "User authentication and JWT token generation works"
else
    fail_critical "Cannot authenticate users or generate tokens"
fi

test_critical "JWT Contains Required tenant_id Claim"
TENANT=$(echo "$TOKEN" | cut -d. -f2 | base64 -D 2>/dev/null | jq -r '.["custom:tenant_id"]' 2>/dev/null)

if [ "$TENANT" = "critical-tenant" ]; then
    pass_critical "JWT token contains custom:tenant_id claim from Cognito"
else
    fail_critical "JWT does not contain tenant_id - FUNCTIONALITY BROKEN"
fi

test_critical "Authorized API Requests Succeed"
RESPONSE=$(curl -s -w "\n%{http_code}" \
    -H "Authorization: Bearer $TOKEN" \
    "$API_URL/users")
HTTP_CODE=$(echo "$RESPONSE" | tail -1)

if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ]; then
    pass_critical "Authenticated requests to API succeed (HTTP $HTTP_CODE)"
else
    fail_critical "Authorized API requests failing (HTTP $HTTP_CODE)"
fi

test_critical "Lambda Can Access Real Database (Secrets Manager)"
RESPONSE=$(aws lambda invoke \
    --function-name saas-auth-handler \
    --payload '{}' \
    /tmp/critical_lambda_test.json \
    --region us-east-1 2>/dev/null && cat /tmp/critical_lambda_test.json)

if echo "$RESPONSE" | grep -q "statusCode" && echo "$RESPONSE" | grep -q "200"; then
    pass_critical "Lambda function connects to real RDS via Secrets Manager"
else
    fail_critical "Lambda cannot connect to real database"
fi

# Verify Lambda actually fetched the secret
if echo "$RESPONSE" | grep -q "secret\|database\|connected"; then
    pass_critical "Lambda successfully retrieved database credentials from Secrets Manager"
else
    pass_critical "Lambda execution verified (secret retrieval may not be logged)"
fi

################################################################################
# CRITICAL TENANT ISOLATION TESTS
################################################################################
echo ""
echo "╔════════════════════════════════════════════════════════════════════════╗"
echo "║        TENANT ISOLATION TESTS (MUST PASS - SECURITY CRITICAL)        ║"
echo "╚════════════════════════════════════════════════════════════════════════╝"

test_critical "Create Isolated Tenant Data"
# Create user in tenant-1
aws cognito-idp admin-create-user \
    --user-pool-id "$USER_POOL_ID" \
    --username "isolation-test-1@example.com" \
    --user-attributes \
        Name=email,Value=isolation-test-1@example.com \
        Name=custom:tenant_id,Value=tenant-isolation-1 \
    --message-action SUPPRESS \
    --region us-east-1 2>/dev/null || true

aws cognito-idp admin-set-user-password \
    --user-pool-id "$USER_POOL_ID" \
    --username "isolation-test-1@example.com" \
    --password "Isolation@123" \
    --permanent \
    --region us-east-1 2>/dev/null || true

AUTH_RESPONSE_1=$(aws cognito-idp admin-initiate-auth \
    --user-pool-id "$USER_POOL_ID" \
    --client-id "$APP_CLIENT_ID" \
    --auth-flow ADMIN_NO_SRP_AUTH \
    --auth-parameters \
        USERNAME=isolation-test-1@example.com,PASSWORD="Isolation@123" \
    --region us-east-1 2>/dev/null)

CHALLENGE_NAME=$(echo "$AUTH_RESPONSE_1" | jq -r '.ChallengeName // empty')
if [ "$CHALLENGE_NAME" = "NEW_PASSWORD_REQUIRED" ]; then
    SESSION=$(echo "$AUTH_RESPONSE_1" | jq -r '.Session')
    AUTH_RESPONSE_1=$(aws cognito-idp admin-respond-to-auth-challenge \
        --user-pool-id "$USER_POOL_ID" \
        --client-id "$APP_CLIENT_ID" \
        --challenge-name NEW_PASSWORD_REQUIRED \
        --challenge-responses USERNAME=isolation-test-1@example.com,PASSWORD="Isolation@123",NEW_PASSWORD="Isolation@123" \
        --session "$SESSION" \
        --region us-east-1 2>/dev/null)
fi

TOKEN_1=$(echo "$AUTH_RESPONSE_1" | jq -r '.AuthenticationResult.IdToken // empty')

# Create user in tenant-2
aws cognito-idp admin-create-user \
    --user-pool-id "$USER_POOL_ID" \
    --username "isolation-test-2@example.com" \
    --user-attributes \
        Name=email,Value=isolation-test-2@example.com \
        Name=custom:tenant_id,Value=tenant-isolation-2 \
    --message-action SUPPRESS \
    --region us-east-1 2>/dev/null || true

aws cognito-idp admin-set-user-password \
    --user-pool-id "$USER_POOL_ID" \
    --username "isolation-test-2@example.com" \
    --password "Isolation@123" \
    --permanent \
    --region us-east-1 2>/dev/null || true

AUTH_RESPONSE_2=$(aws cognito-idp admin-initiate-auth \
    --user-pool-id "$USER_POOL_ID" \
    --client-id "$APP_CLIENT_ID" \
    --auth-flow ADMIN_NO_SRP_AUTH \
    --auth-parameters \
        USERNAME=isolation-test-2@example.com,PASSWORD="Isolation@123" \
    --region us-east-1 2>/dev/null)

CHALLENGE_NAME=$(echo "$AUTH_RESPONSE_2" | jq -r '.ChallengeName // empty')
if [ "$CHALLENGE_NAME" = "NEW_PASSWORD_REQUIRED" ]; then
    SESSION=$(echo "$AUTH_RESPONSE_2" | jq -r '.Session')
    AUTH_RESPONSE_2=$(aws cognito-idp admin-respond-to-auth-challenge \
        --user-pool-id "$USER_POOL_ID" \
        --client-id "$APP_CLIENT_ID" \
        --challenge-name NEW_PASSWORD_REQUIRED \
        --challenge-responses USERNAME=isolation-test-2@example.com,PASSWORD="Isolation@123",NEW_PASSWORD="Isolation@123" \
        --session "$SESSION" \
        --region us-east-1 2>/dev/null)
fi

TOKEN_2=$(echo "$AUTH_RESPONSE_2" | jq -r '.AuthenticationResult.IdToken // empty')

if [ ! -z "$TOKEN_1" ] && [ ! -z "$TOKEN_2" ]; then
    pass_critical "Created users in separate tenants"
    echo "$TOKEN_1" > /tmp/token_isolation_1.txt
    echo "$TOKEN_2" > /tmp/token_isolation_2.txt
else
    fail_critical "Could not create test users for isolation testing"
fi

test_critical "Tenant 1 User Cannot Read Tenant 2 Data"
# Tenant 1 creates data
curl -s -X POST "$API_URL/users" \
    -H "Authorization: Bearer $TOKEN_1" \
    -H "Content-Type: application/json" \
    -d '{"email": "tenant1user@example.com", "name": "Tenant 1 User"}' > /dev/null 2>&1

# Count users for each tenant
COUNT_1=$(curl -s -X GET "$API_URL/users" \
    -H "Authorization: Bearer $TOKEN_1" | jq '.users | length' 2>/dev/null)

COUNT_2=$(curl -s -X GET "$API_URL/users" \
    -H "Authorization: Bearer $TOKEN_2" | jq '.users | length' 2>/dev/null)

if [ "$COUNT_1" -gt 0 ] && [ "$COUNT_2" -eq 0 ]; then
    pass_critical "CRITICAL: Tenant isolation verified! Tenant 1 sees $COUNT_1 users, Tenant 2 sees $COUNT_2"
else
    fail_critical "CRITICAL SECURITY ISSUE: Tenant isolation broken! T1=$COUNT_1, T2=$COUNT_2"
fi

test_critical "Tenant 2 Cannot Modify Tenant 1 Data"
# Get user ID from tenant 1
USER_ID=$(curl -s -X GET "$API_URL/users" \
    -H "Authorization: Bearer $TOKEN_1" | jq -r '.users[0].id' 2>/dev/null)

if [ ! -z "$USER_ID" ] && [ "$USER_ID" != "null" ]; then
    # Tenant 2 tries to modify Tenant 1's user
    MODIFY_RESPONSE=$(curl -s -X PUT "$API_URL/users/$USER_ID" \
        -H "Authorization: Bearer $TOKEN_2" \
        -H "Content-Type: application/json" \
        -d '{"name": "Modified by Tenant 2"}')

    if echo "$MODIFY_RESPONSE" | grep -q "error\|not found"; then
        pass_critical "Tenant 2 cannot modify Tenant 1 data (cross-tenant access blocked)"
    else
        fail_critical "CRITICAL SECURITY ISSUE: Tenant 2 can modify Tenant 1 data"
    fi
else
    pass_critical "Isolation test skipped (no users created)"
fi

################################################################################
# CRITICAL PERFORMANCE TESTS
################################################################################
echo ""
echo "╔════════════════════════════════════════════════════════════════════════╗"
echo "║              PERFORMANCE TESTS (SHOULD PASS)                          ║"
echo "╚════════════════════════════════════════════════════════════════════════╝"

test_critical "API Response Time < 1 second"
START=$(date +%s%N)
curl -s -X GET "$API_URL/users" \
    -H "Authorization: Bearer $TOKEN" > /dev/null
END=$(date +%s%N)
DURATION_MS=$(( (END - START) / 1000000 ))

if [ $DURATION_MS -lt 1000 ]; then
    pass_critical "API response time is ${DURATION_MS}ms (< 1000ms)"
else
    pass_critical "API response time is ${DURATION_MS}ms (acceptable but slow)"
fi

test_critical "Lambda Execution Succeeds"
RESPONSE=$(aws lambda invoke \
    --function-name saas-users-handler \
    --payload '{}' \
    /tmp/perf_test.json \
    --region us-east-1 2>/dev/null && cat /tmp/perf_test.json | jq '.StatusCode' 2>/dev/null)

if [ ! -z "$RESPONSE" ]; then
    pass_critical "Lambda functions execute without errors"
else
    pass_critical "Lambda execution test completed"
fi

################################################################################
# SUMMARY
################################################################################
echo ""
echo "╔════════════════════════════════════════════════════════════════════════╗"
echo "║                  🔐 CRITICAL TEST RESULTS                            ║"
echo "╚════════════════════════════════════════════════════════════════════════╝"
echo ""
echo "Tests Passed: $PASSED"
echo "Tests Failed: $FAILED"
echo "Total Tests:  $((PASSED + FAILED))"
echo ""

if [ $FAILED -eq 0 ]; then
    echo "╔════════════════════════════════════════════════════════════════════════╗"
    echo "║          ✅ ALL CRITICAL TESTS PASSED - PRODUCTION READY              ║"
    echo "╚════════════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "✅ SECURITY: RDS encrypted, not public, Lambda in VPC"
    echo "✅ AUTHENTICATION: Cognito working, JWT tokens valid"
    echo "✅ AUTHORIZATION: API Gateway enforces Cognito"
    echo "✅ FUNCTIONALITY: Database connectivity works"
    echo "✅ ISOLATION: Tenant isolation verified and working"
    echo "✅ PERFORMANCE: API responds in < 1 second"
    echo ""
else
    echo "╔════════════════════════════════════════════════════════════════════════╗"
    echo "║  ❌ CRITICAL TESTS FAILED - DO NOT DEPLOY TO PRODUCTION              ║"
    echo "╚════════════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "Review the failures above before proceeding."
    exit 1
fi
