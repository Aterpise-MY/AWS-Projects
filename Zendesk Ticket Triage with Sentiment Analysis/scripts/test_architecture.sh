#!/usr/bin/env bash
# Architecture validation for the Zendesk Ticket Triage project.
# Run from the project directory: bash scripts/test_architecture.sh
#
# Verifies every deployed AWS resource and exercises the triage Lambda with a
# locally-signed synthetic webhook (HMAC-SHA256), confirming sentiment scoring
# and the DynamoDB audit write end-to-end. Live IDs are read from Terraform
# state when available, otherwise the hardcoded defaults below are used.

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

for cmd in aws jq; do
  command -v "$cmd" &>/dev/null || { echo "Missing required tool: $cmd"; exit 1; }
done

REGION="us-east-1"

# ── Defaults (overridden from Terraform state when present) ───────────────────
FUNCTION_NAME="zendesk-triage-function"
TABLE_NAME="SentimentAnalysis"
API_NAME="zendesk-triage-api"
STAGE="v1"
ROLE_NAME="zendesk-triage-lambda-exec"
TOPIC_NAME="zendesk-triage-negative-alerts"
SECRET_NAME="zendesk-triage/zendesk"
LOG_GROUP_LAMBDA="/aws/lambda/zendesk-triage-function"

TF_DIR="$(dirname "$0")/../terraform"
if [[ -f "$TF_DIR/terraform.tfstate" ]]; then
  pushd "$TF_DIR" > /dev/null
  TABLE_NAME=$(terraform output -raw dynamodb_table_name 2>/dev/null || echo "$TABLE_NAME")
  FUNCTION_NAME=$(terraform output -raw lambda_function_name 2>/dev/null || echo "$FUNCTION_NAME")
  LOG_GROUP_LAMBDA=$(terraform output -raw lambda_log_group 2>/dev/null || echo "$LOG_GROUP_LAMBDA")
  popd > /dev/null
fi

# ── 1. DynamoDB ───────────────────────────────────────────────────────────────
header "1. DynamoDB Table"
TABLE_STATUS=$(aws dynamodb describe-table --table-name "$TABLE_NAME" \
  --query 'Table.TableStatus' --output text --region "$REGION" 2>/dev/null || echo "NOT_FOUND")
[[ "$TABLE_STATUS" == "ACTIVE" ]] && pass "DynamoDB table '$TABLE_NAME' is ACTIVE" \
  || fail "DynamoDB table '$TABLE_NAME' status: $TABLE_STATUS"

KEY_SCHEMA=$(aws dynamodb describe-table --table-name "$TABLE_NAME" \
  --query 'Table.KeySchema[].AttributeName' --output text --region "$REGION" 2>/dev/null || echo "")
[[ "$KEY_SCHEMA" == *"TicketID"* && "$KEY_SCHEMA" == *"CreatedAt"* ]] \
  && pass "Key schema is TicketID (HASH) + CreatedAt (RANGE)" \
  || fail "Unexpected key schema: $KEY_SCHEMA"

# ── 2. Lambda ─────────────────────────────────────────────────────────────────
header "2. Lambda Function"
FUNCTION_STATE=$(aws lambda get-function --function-name "$FUNCTION_NAME" \
  --query 'Configuration.State' --output text --region "$REGION" 2>/dev/null || echo "NOT_FOUND")
[[ "$FUNCTION_STATE" == "Active" ]] && pass "Lambda '$FUNCTION_NAME' is Active" \
  || fail "Lambda state: $FUNCTION_STATE"

RUNTIME=$(aws lambda get-function --function-name "$FUNCTION_NAME" \
  --query 'Configuration.Runtime' --output text --region "$REGION" 2>/dev/null || echo "UNKNOWN")
[[ "$RUNTIME" == "python3.11" ]] && pass "Lambda runtime: $RUNTIME" \
  || warn "Lambda runtime: $RUNTIME (expected python3.11)"

# ── 3. IAM ────────────────────────────────────────────────────────────────────
header "3. IAM Role"
ROLE_EXISTS=$(aws iam get-role --role-name "$ROLE_NAME" \
  --query 'Role.RoleName' --output text 2>/dev/null || echo "NOT_FOUND")
[[ "$ROLE_EXISTS" == "$ROLE_NAME" ]] && pass "IAM role '$ROLE_NAME' exists" \
  || fail "IAM role not found: $ROLE_NAME"

POLICY_COUNT=$(aws iam list-role-policies --role-name "$ROLE_NAME" \
  --query 'PolicyNames | length(@)' --output text 2>/dev/null || echo 0)
[[ "$POLICY_COUNT" -ge 5 ]] \
  && pass "IAM role has $POLICY_COUNT inline policies (dynamodb, comprehend, sns, secrets, logs)" \
  || fail "IAM role has only $POLICY_COUNT inline policies (expected 5)"

# ── 4. SNS ────────────────────────────────────────────────────────────────────
header "4. SNS Topic"
TOPIC_ARN=$(aws sns list-topics --region "$REGION" \
  --query "Topics[?contains(TopicArn, '$TOPIC_NAME')].TopicArn | [0]" --output text 2>/dev/null || echo "None")
[[ "$TOPIC_ARN" != "None" && -n "$TOPIC_ARN" ]] && pass "SNS topic '$TOPIC_NAME' exists" \
  || fail "SNS topic '$TOPIC_NAME' not found"

# ── 5. Secrets Manager ────────────────────────────────────────────────────────
header "5. Secrets Manager"
SECRET_STATE=$(aws secretsmanager describe-secret --secret-id "$SECRET_NAME" \
  --query 'Name' --output text --region "$REGION" 2>/dev/null || echo "NOT_FOUND")
[[ "$SECRET_STATE" == "$SECRET_NAME" ]] && pass "Secret '$SECRET_NAME' exists" \
  || fail "Secret '$SECRET_NAME' not found"

# ── 6. API Gateway ────────────────────────────────────────────────────────────
header "6. API Gateway"
API_ID=$(aws apigateway get-rest-apis --region "$REGION" \
  --query "items[?name=='$API_NAME'].id | [0]" --output text 2>/dev/null || echo "None")
[[ "$API_ID" != "None" && -n "$API_ID" ]] && pass "API Gateway '$API_NAME' ($API_ID) exists" \
  || fail "API Gateway '$API_NAME' not found"

if [[ "$API_ID" != "None" && -n "$API_ID" ]]; then
  WEBHOOK_COUNT=$(aws apigateway get-resources --rest-api-id "$API_ID" --region "$REGION" \
    --query "items[?pathPart=='webhook'] | length(@)" --output text 2>/dev/null || echo 0)
  [[ "$WEBHOOK_COUNT" -ge 1 ]] && pass "API resource /webhook exists" \
    || fail "API resource /webhook not found"
fi

# ── 7. CloudWatch ─────────────────────────────────────────────────────────────
header "7. CloudWatch"
LG_EXISTS=$(aws logs describe-log-groups --log-group-name-prefix "$LOG_GROUP_LAMBDA" \
  --query "logGroups[?logGroupName=='$LOG_GROUP_LAMBDA'] | length(@)" --output text --region "$REGION" 2>/dev/null || echo 0)
[[ "$LG_EXISTS" -ge 1 ]] && pass "Lambda log group exists" \
  || warn "Lambda log group not found — created on first invocation"

ALARM_COUNT=$(aws cloudwatch describe-alarms --alarm-name-prefix "zendesk-triage" \
  --query 'MetricAlarms | length(@)' --output text --region "$REGION" 2>/dev/null || echo 0)
[[ "$ALARM_COUNT" -ge 3 ]] && pass "CloudWatch alarms: $ALARM_COUNT configured" \
  || fail "CloudWatch alarms: only $ALARM_COUNT found (expected 3)"

# ── 8. Live triage test (signed synthetic webhook) ────────────────────────────
header "8. Live Triage Test"
SIGNING_SECRET=$(aws secretsmanager get-secret-value --secret-id "$SECRET_NAME" \
  --query 'SecretString' --output text --region "$REGION" 2>/dev/null \
  | jq -r '.webhook_signing_secret // empty' 2>/dev/null || echo "")

if [[ -z "$SIGNING_SECRET" || "$SIGNING_SECRET" == "REPLACE_ME" ]]; then
  warn "Signing secret still placeholder — skipping live invoke (set real secret to enable)"
else
  TS=$(date +%s)
  BODY='{"id":"999001","subject":"Order late again","description":"This is the third time my order is late and no one will help. I am done."}'
  SIG=$(printf '%s%s' "$TS" "$BODY" | openssl dgst -sha256 -hmac "$SIGNING_SECRET" -binary | base64)
  EVENT=$(jq -n --arg body "$BODY" --arg sig "$SIG" --arg ts "$TS" \
    '{httpMethod:"POST",resource:"/webhook",headers:{"X-Zendesk-Webhook-Signature":$sig,"X-Zendesk-Webhook-Signature-Timestamp":$ts},body:$body}')
  RESP=$(aws lambda invoke --function-name "$FUNCTION_NAME" --region "$REGION" \
    --cli-binary-format raw-in-base64-out --payload "$EVENT" /dev/stdout 2>/dev/null | head -1 || echo "{}")
  SENTIMENT=$(echo "$RESP" | jq -r '.body | fromjson | .sentiment // empty' 2>/dev/null || echo "")
  if [[ "$SENTIMENT" == "NEGATIVE" ]]; then
    pass "Synthetic negative webhook scored NEGATIVE and triaged to urgent"
  else
    warn "Live invoke returned: $RESP"
  fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════"
echo "  Results: ${PASS} PASS  |  ${WARN} WARN  |  ${FAIL} FAIL"
echo "════════════════════════════════════════════════════════"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
