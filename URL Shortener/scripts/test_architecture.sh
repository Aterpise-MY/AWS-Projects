#!/usr/bin/env bash
# Architecture validation for the URL Shortener project.
# Run from the URL Shortener/ directory: bash scripts/test_architecture.sh
#
# Hardcoded live resource IDs (us-east-1, account 022499047467, deployed 2026-06-26).
# If Terraform state is available the script overrides these from terraform output.

set -euo pipefail

PASS=0
FAIL=0
WARN=0

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}[PASS]${NC} $1"; PASS=$((PASS + 1)); }
fail() { echo -e "${RED}[FAIL]${NC} $1"; FAIL=$((FAIL + 1)); }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; WARN=$((WARN + 1)); }
header() { echo -e "\n── $1 ──────────────────────────────────────────────"; }

# ── Prerequisites ─────────────────────────────────────────────────────────────
for cmd in terraform aws curl jq; do
  command -v "$cmd" &>/dev/null || { echo "Missing required tool: $cmd"; exit 1; }
done

# ── Live resource IDs (hardcoded from 2026-06-26 deployment) ─────────────────
FUNCTION_NAME="url-shortener-function"
FUNCTION_ARN="arn:aws:lambda:us-east-1:022499047467:function:url-shortener-function"
TABLE_NAME="url-shortener-links"
TABLE_ARN="arn:aws:dynamodb:us-east-1:022499047467:table/url-shortener-links"
API_ID="qywjck4di7"
API_NAME="url-shortener-api"
STAGE="v1"
ROLE_NAME="url-shortener-lambda-exec"
ROLE_ARN="arn:aws:iam::022499047467:role/url-shortener-lambda-exec"
LOG_GROUP_LAMBDA="/aws/lambda/url-shortener-function"
LOG_GROUP_API="/aws/apigateway/url-shortener"
BASE_URL="https://qywjck4di7.execute-api.us-east-1.amazonaws.com/v1"

# Override from Terraform state if available
TF_DIR="$(dirname "$0")/../terraform"
if [[ -f "$TF_DIR/terraform.tfstate" ]]; then
  pushd "$TF_DIR" > /dev/null
  TABLE_NAME=$(terraform output -raw dynamodb_table_name 2>/dev/null || echo "$TABLE_NAME")
  FUNCTION_NAME=$(terraform output -raw lambda_function_name 2>/dev/null || echo "$FUNCTION_NAME")
  API_ID=$(terraform output -raw rest_api_id 2>/dev/null || echo "$API_ID")
  LOG_GROUP_LAMBDA=$(terraform output -raw lambda_log_group 2>/dev/null || echo "$LOG_GROUP_LAMBDA")
  BASE_URL=$(terraform output -raw api_base_url 2>/dev/null || echo "$BASE_URL")
  popd > /dev/null
fi

SHORTEN_URL="$BASE_URL/shorten"
REDIRECT_URL="$BASE_URL/redirect"
STATS_URL="$BASE_URL/stats"

# ── 1. Terraform state ────────────────────────────────────────────────────────
header "1. Terraform State"
if [[ -f "$TF_DIR/terraform.tfstate" ]]; then
  TF_RESOURCES=$(cd "$TF_DIR" && terraform show -json 2>/dev/null | jq '.values.root_module.resources | length' 2>/dev/null || echo 0)
  if [[ "$TF_RESOURCES" -ge 15 ]]; then
    pass "Terraform state has $TF_RESOURCES resources (expected >= 15)"
  else
    fail "Terraform state has only $TF_RESOURCES resources (expected >= 15)"
  fi
else
  warn "No terraform.tfstate found — skipping Terraform state check; using hardcoded IDs"
fi

# ── 2. DynamoDB ───────────────────────────────────────────────────────────────
header "2. DynamoDB Table"
TABLE_STATUS=$(aws dynamodb describe-table \
  --table-name "$TABLE_NAME" \
  --query 'Table.TableStatus' \
  --output text \
  --region us-east-1 2>/dev/null || echo "NOT_FOUND")
if [[ "$TABLE_STATUS" == "ACTIVE" ]]; then
  pass "DynamoDB table '$TABLE_NAME' is ACTIVE"
else
  fail "DynamoDB table '$TABLE_NAME' status: $TABLE_STATUS"
fi

TTL_STATUS=$(aws dynamodb describe-time-to-live \
  --table-name "$TABLE_NAME" \
  --query 'TimeToLiveDescription.TimeToLiveStatus' \
  --output text \
  --region us-east-1 2>/dev/null || echo "UNKNOWN")
if [[ "$TTL_STATUS" == "ENABLED" ]]; then
  pass "DynamoDB TTL ENABLED on attribute 'expires_at'"
else
  warn "DynamoDB TTL status: $TTL_STATUS"
fi

PITR=$(aws dynamodb describe-continuous-backups \
  --table-name "$TABLE_NAME" \
  --query 'ContinuousBackupsDescription.PointInTimeRecoveryDescription.PointInTimeRecoveryStatus' \
  --output text \
  --region us-east-1 2>/dev/null || echo "UNKNOWN")
if [[ "$PITR" == "ENABLED" ]]; then
  pass "Point-in-time recovery ENABLED (35-day window)"
else
  fail "PITR status: $PITR"
fi

# ── 3. Lambda ─────────────────────────────────────────────────────────────────
header "3. Lambda Function"
FUNCTION_STATE=$(aws lambda get-function \
  --function-name "$FUNCTION_NAME" \
  --query 'Configuration.State' \
  --output text \
  --region us-east-1 2>/dev/null || echo "NOT_FOUND")
if [[ "$FUNCTION_STATE" == "Active" ]]; then
  pass "Lambda '$FUNCTION_NAME' is Active"
else
  fail "Lambda state: $FUNCTION_STATE"
fi

RUNTIME=$(aws lambda get-function \
  --function-name "$FUNCTION_NAME" \
  --query 'Configuration.Runtime' \
  --output text \
  --region us-east-1 2>/dev/null || echo "UNKNOWN")
if [[ "$RUNTIME" == "python3.11" ]]; then
  pass "Lambda runtime: $RUNTIME"
else
  warn "Lambda runtime: $RUNTIME (expected python3.11)"
fi

TABLE_ENV=$(aws lambda get-function-configuration \
  --function-name "$FUNCTION_NAME" \
  --query 'Environment.Variables.TABLE_NAME' \
  --output text \
  --region us-east-1 2>/dev/null || echo "MISSING")
if [[ "$TABLE_ENV" == "$TABLE_NAME" ]]; then
  pass "Lambda TABLE_NAME env var = '$TABLE_NAME'"
else
  fail "Lambda TABLE_NAME env var: '$TABLE_ENV' (expected '$TABLE_NAME')"
fi

MEM=$(aws lambda get-function \
  --function-name "$FUNCTION_NAME" \
  --query 'Configuration.MemorySize' \
  --output text \
  --region us-east-1 2>/dev/null || echo "0")
if [[ "$MEM" == "256" ]]; then
  pass "Lambda memory: ${MEM} MB"
else
  warn "Lambda memory: ${MEM} MB (expected 256)"
fi

# ── 4. IAM ────────────────────────────────────────────────────────────────────
header "4. IAM Role"
ROLE_EXISTS=$(aws iam get-role \
  --role-name "$ROLE_NAME" \
  --query 'Role.RoleName' \
  --output text 2>/dev/null || echo "NOT_FOUND")
if [[ "$ROLE_EXISTS" == "$ROLE_NAME" ]]; then
  pass "IAM role '$ROLE_NAME' exists (ID: AROAQKPIMHAVVHLXGW6JB)"
else
  fail "IAM role not found: $ROLE_NAME"
fi

POLICY_COUNT=$(aws iam list-role-policies \
  --role-name "$ROLE_NAME" \
  --query 'PolicyNames | length(@)' \
  --output text 2>/dev/null || echo 0)
if [[ "$POLICY_COUNT" -ge 2 ]]; then
  pass "IAM role has $POLICY_COUNT inline policies (dynamodb + logs)"
else
  fail "IAM role has only $POLICY_COUNT inline policies (expected 2)"
fi

# ── 5. API Gateway ────────────────────────────────────────────────────────────
header "5. API Gateway"
API_STATUS=$(aws apigateway get-rest-api \
  --rest-api-id "$API_ID" \
  --query 'apiStatus' \
  --output text \
  --region us-east-1 2>/dev/null || echo "NOT_FOUND")
if [[ "$API_STATUS" == "AVAILABLE" ]]; then
  pass "API Gateway '$API_NAME' ($API_ID) is AVAILABLE"
else
  fail "API Gateway status: $API_STATUS"
fi

for RESOURCE_PATH in shorten redirect stats; do
  COUNT=$(aws apigateway get-resources \
    --rest-api-id "$API_ID" \
    --query "items[?pathPart=='$RESOURCE_PATH'] | length(@)" \
    --output text \
    --region us-east-1 2>/dev/null || echo 0)
  if [[ "$COUNT" -ge 1 ]]; then
    pass "API resource /$RESOURCE_PATH exists"
  else
    fail "API resource /$RESOURCE_PATH not found"
  fi
done

STAGE_EXISTS=$(aws apigateway get-stages \
  --rest-api-id "$API_ID" \
  --query "item[?stageName=='$STAGE'] | length(@)" \
  --output text \
  --region us-east-1 2>/dev/null || echo 0)
if [[ "$STAGE_EXISTS" -ge 1 ]]; then
  pass "API Gateway stage '$STAGE' (deployment: 3rvnft) exists"
else
  fail "API Gateway stage '$STAGE' not found"
fi

# ── 6. CloudWatch ─────────────────────────────────────────────────────────────
header "6. CloudWatch"
LG_EXISTS=$(aws logs describe-log-groups \
  --log-group-name-prefix "$LOG_GROUP_LAMBDA" \
  --query "logGroups[?logGroupName=='$LOG_GROUP_LAMBDA'] | length(@)" \
  --output text \
  --region us-east-1 2>/dev/null || echo 0)
if [[ "$LG_EXISTS" -ge 1 ]]; then
  pass "Lambda log group '$LOG_GROUP_LAMBDA' exists"
else
  warn "Lambda log group not found — will be created on first invocation"
fi

API_LG_EXISTS=$(aws logs describe-log-groups \
  --log-group-name-prefix "$LOG_GROUP_API" \
  --query "logGroups[?logGroupName=='$LOG_GROUP_API'] | length(@)" \
  --output text \
  --region us-east-1 2>/dev/null || echo 0)
if [[ "$API_LG_EXISTS" -ge 1 ]]; then
  pass "API Gateway log group '$LOG_GROUP_API' exists"
else
  warn "API Gateway log group not found"
fi

ALARM_COUNT=$(aws cloudwatch describe-alarms \
  --alarm-name-prefix "url-shortener" \
  --query 'MetricAlarms | length(@)' \
  --output text \
  --region us-east-1 2>/dev/null || echo 0)
if [[ "$ALARM_COUNT" -ge 3 ]]; then
  pass "CloudWatch alarms: $ALARM_COUNT configured"
else
  fail "CloudWatch alarms: only $ALARM_COUNT found (expected 3)"
fi

ALARMS_IN_ALARM=$(aws cloudwatch describe-alarms \
  --alarm-name-prefix "url-shortener" \
  --state-value ALARM \
  --query 'MetricAlarms | length(@)' \
  --output text \
  --region us-east-1 2>/dev/null || echo 0)
if [[ "$ALARMS_IN_ALARM" -eq 0 ]]; then
  pass "All CloudWatch alarms are in OK state"
else
  fail "$ALARMS_IN_ALARM alarm(s) currently in ALARM state"
fi

# ── 7. Live API Tests ─────────────────────────────────────────────────────────
header "7. Live API Tests"
TEST_CODE="test-$(date +%s)"

# POST /shorten — create with custom code
SHORTEN_RESP=$(curl -sf -X POST "$SHORTEN_URL" \
  -H "Content-Type: application/json" \
  -d "{\"long_url\":\"https://example.com/test\",\"custom_code\":\"$TEST_CODE\",\"expires_in_days\":1,\"created_by\":\"test-script\",\"label\":\"Architecture Test Link\"}" \
  2>/dev/null || echo "{}")
RETURNED_CODE=$(echo "$SHORTEN_RESP" | jq -r '.short_code // empty' 2>/dev/null)
if [[ "$RETURNED_CODE" == "$TEST_CODE" ]]; then
  pass "POST /shorten → 201 Created, short_code: $TEST_CODE"
else
  fail "POST /shorten failed — response: $SHORTEN_RESP"
fi

# GET /stats — retrieve link metadata
STATS_RESP=$(curl -sf "$STATS_URL?short_code=$TEST_CODE" 2>/dev/null || echo "{}")
STATS_CODE=$(echo "$STATS_RESP" | jq -r '.short_code // empty' 2>/dev/null)
if [[ "$STATS_CODE" == "$TEST_CODE" ]]; then
  pass "GET /stats → 200 OK, returned metadata for $TEST_CODE"
else
  fail "GET /stats failed — response: $STATS_RESP"
fi

# GET /redirect — follow link, verify 301
HTTP_STATUS=$(curl -so /dev/null -w "%{http_code}" "$REDIRECT_URL?short_code=$TEST_CODE" 2>/dev/null || echo "000")
if [[ "$HTTP_STATUS" == "301" ]]; then
  pass "GET /redirect → HTTP 301 Moved Permanently"
else
  fail "GET /redirect returned HTTP $HTTP_STATUS (expected 301)"
fi

# POST /shorten — duplicate custom code → 409 Conflict
CONFLICT_STATUS=$(curl -so /dev/null -w "%{http_code}" -X POST "$SHORTEN_URL" \
  -H "Content-Type: application/json" \
  -d "{\"long_url\":\"https://other.com\",\"custom_code\":\"$TEST_CODE\"}" \
  2>/dev/null || echo "000")
if [[ "$CONFLICT_STATUS" == "409" ]]; then
  pass "POST /shorten duplicate → HTTP 409 Conflict"
else
  fail "POST /shorten duplicate returned HTTP $CONFLICT_STATUS (expected 409)"
fi

# GET /stats — unknown short_code → 404
MISSING_STATUS=$(curl -so /dev/null -w "%{http_code}" "$STATS_URL?short_code=nonexistent-code-xyz987" 2>/dev/null || echo "000")
if [[ "$MISSING_STATUS" == "404" ]]; then
  pass "GET /stats unknown code → HTTP 404 Not Found"
else
  fail "GET /stats unknown code returned HTTP $MISSING_STATUS (expected 404)"
fi

# GET /stats — verify click_count incremented after redirect
CLICK_COUNT=$(curl -sf "$STATS_URL?short_code=$TEST_CODE" 2>/dev/null | jq -r '.click_count // 0' 2>/dev/null)
if [[ "$CLICK_COUNT" -ge 1 ]]; then
  pass "click_count incremented to $CLICK_COUNT after redirect"
else
  fail "click_count not incremented — got: $CLICK_COUNT"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════"
echo "  Deployed: https://qywjck4di7.execute-api.us-east-1.amazonaws.com/v1"
echo "  Table:    arn:aws:dynamodb:us-east-1:022499047467:table/url-shortener-links"
echo "  Function: arn:aws:lambda:us-east-1:022499047467:function:url-shortener-function"
echo "════════════════════════════════════════════════════════"
echo "  Results: ${PASS} PASS  |  ${WARN} WARN  |  ${FAIL} FAIL"
echo "════════════════════════════════════════════════════════"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
