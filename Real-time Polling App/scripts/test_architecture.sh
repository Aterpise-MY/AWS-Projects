#!/usr/bin/env bash
# Architecture validation for the Real-time Polling App project.
# Run from the project root: bash scripts/test_architecture.sh
#
# Verifies all Terraform-managed AWS resources exist and are healthy. Live
# WebSocket message tests require wscat and are run separately (see README).

set -uo pipefail

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

for cmd in terraform aws jq; do
  command -v "$cmd" &>/dev/null || { echo "Missing required tool: $cmd"; exit 1; }
done

REGION="${AWS_REGION:-us-east-1}"
PREFIX="realtime-polling"
TF_DIR="$(dirname "$0")/../terraform"

cd "$TF_DIR"

# ── 1. Terraform state ────────────────────────────────────────────────────────
header "1. Terraform State"
TF_RESOURCES=$(terraform show -json 2>/dev/null | jq '[.values.root_module.resources[]] | length' 2>/dev/null || echo 0)
if [[ "$TF_RESOURCES" -ge 25 ]]; then
  pass "Terraform state has $TF_RESOURCES resources (expected >= 25)"
else
  fail "Terraform state has only $TF_RESOURCES resources (expected >= 25)"
fi

API_ID=$(terraform output -raw api_id 2>/dev/null || echo "")
STAGE=$(terraform output -raw stage_name 2>/dev/null || echo "production")

# ── 2. DynamoDB tables ────────────────────────────────────────────────────────
header "2. DynamoDB Tables"
for TBL in polls connections livestream-sessions flashsale-items design-surveys; do
  NAME="${PREFIX}-${TBL}"
  STATUS=$(aws dynamodb describe-table --table-name "$NAME" --query 'Table.TableStatus' --output text --region "$REGION" 2>/dev/null || echo "NOT_FOUND")
  if [[ "$STATUS" == "ACTIVE" ]]; then
    pass "Table '$NAME' is ACTIVE"
  else
    fail "Table '$NAME' status: $STATUS"
  fi
done

# Connections GSI
GSI=$(aws dynamodb describe-table --table-name "${PREFIX}-connections" --query "Table.GlobalSecondaryIndexes[?IndexName=='sessionId-index'].IndexName | [0]" --output text --region "$REGION" 2>/dev/null || echo "None")
if [[ "$GSI" == "sessionId-index" ]]; then
  pass "Connections GSI 'sessionId-index' exists"
else
  fail "Connections GSI 'sessionId-index' not found"
fi

# Connections TTL
TTL=$(aws dynamodb describe-time-to-live --table-name "${PREFIX}-connections" --query 'TimeToLiveDescription.TimeToLiveStatus' --output text --region "$REGION" 2>/dev/null || echo "UNKNOWN")
if [[ "$TTL" == "ENABLED" ]]; then
  pass "Connections TTL ENABLED on attribute 'ttl'"
else
  warn "Connections TTL status: $TTL"
fi

# LiveStream TTL
LS_TTL=$(aws dynamodb describe-time-to-live --table-name "${PREFIX}-livestream-sessions" --query 'TimeToLiveDescription.TimeToLiveStatus' --output text --region "$REGION" 2>/dev/null || echo "UNKNOWN")
if [[ "$LS_TTL" == "ENABLED" ]]; then
  pass "LiveStreamSessions TTL ENABLED on 'expiresAt'"
else
  warn "LiveStreamSessions TTL status: $LS_TTL"
fi

# ── 3. Lambda functions ───────────────────────────────────────────────────────
header "3. Lambda Functions"
for FN in manage_connections handle_vote broadcast_results livestream_vote flashsale_update design_vote; do
  NAME="${PREFIX}-${FN}"
  STATE=$(aws lambda get-function --function-name "$NAME" --query 'Configuration.State' --output text --region "$REGION" 2>/dev/null || echo "NOT_FOUND")
  if [[ "$STATE" == "Active" ]]; then
    pass "Lambda '$NAME' is Active"
  else
    fail "Lambda '$NAME' state: $STATE"
  fi
done

# ── 4. IAM role ───────────────────────────────────────────────────────────────
header "4. IAM Role"
ROLE=$(aws iam get-role --role-name "${PREFIX}-lambda-exec" --query 'Role.RoleName' --output text 2>/dev/null || echo "NOT_FOUND")
if [[ "$ROLE" == "${PREFIX}-lambda-exec" ]]; then
  pass "IAM role '${PREFIX}-lambda-exec' exists"
else
  fail "IAM role not found"
fi

POLICY_COUNT=$(aws iam list-role-policies --role-name "${PREFIX}-lambda-exec" --query 'PolicyNames | length(@)' --output text 2>/dev/null || echo 0)
if [[ "$POLICY_COUNT" -ge 3 ]]; then
  pass "IAM role has $POLICY_COUNT inline policies (dynamodb + manage-connections + logs)"
else
  fail "IAM role has only $POLICY_COUNT inline policies (expected 3)"
fi

# ── 5. WebSocket API ──────────────────────────────────────────────────────────
header "5. WebSocket API"
if [[ -n "$API_ID" ]]; then
  PROTO=$(aws apigatewayv2 get-api --api-id "$API_ID" --query 'ProtocolType' --output text --region "$REGION" 2>/dev/null || echo "NOT_FOUND")
  if [[ "$PROTO" == "WEBSOCKET" ]]; then
    pass "API '$API_ID' is a WEBSOCKET API"
  else
    fail "API protocol: $PROTO"
  fi

  RSE=$(aws apigatewayv2 get-api --api-id "$API_ID" --query 'RouteSelectionExpression' --output text --region "$REGION" 2>/dev/null || echo "")
  if [[ "$RSE" == '$request.body.action' ]]; then
    pass "Route selection expression is \$request.body.action"
  else
    warn "Route selection expression: $RSE"
  fi

  ROUTE_COUNT=$(aws apigatewayv2 get-routes --api-id "$API_ID" --query 'Items | length(@)' --output text --region "$REGION" 2>/dev/null || echo 0)
  if [[ "$ROUTE_COUNT" -ge 7 ]]; then
    pass "WebSocket API has $ROUTE_COUNT routes (expected 7)"
  else
    fail "WebSocket API has only $ROUTE_COUNT routes (expected 7)"
  fi

  STAGE_STATE=$(aws apigatewayv2 get-stage --api-id "$API_ID" --stage-name "$STAGE" --query 'StageName' --output text --region "$REGION" 2>/dev/null || echo "NOT_FOUND")
  if [[ "$STAGE_STATE" == "$STAGE" ]]; then
    pass "Stage '$STAGE' exists (auto-deploy)"
  else
    fail "Stage '$STAGE' not found"
  fi
else
  fail "Could not read api_id from terraform output — is the stack deployed?"
fi

# ── 6. CloudWatch ─────────────────────────────────────────────────────────────
header "6. CloudWatch"
ALARM_COUNT=$(aws cloudwatch describe-alarms --alarm-name-prefix "$PREFIX" --query 'MetricAlarms | length(@)' --output text --region "$REGION" 2>/dev/null || echo 0)
if [[ "$ALARM_COUNT" -ge 7 ]]; then
  pass "CloudWatch alarms: $ALARM_COUNT configured (6 Lambda + 1 integration)"
else
  fail "CloudWatch alarms: only $ALARM_COUNT found (expected 7)"
fi

IN_ALARM=$(aws cloudwatch describe-alarms --alarm-name-prefix "$PREFIX" --state-value ALARM --query 'MetricAlarms | length(@)' --output text --region "$REGION" 2>/dev/null || echo 0)
if [[ "$IN_ALARM" -eq 0 ]]; then
  pass "All CloudWatch alarms are in OK state"
else
  fail "$IN_ALARM alarm(s) currently in ALARM state"
fi

LG_COUNT=$(aws logs describe-log-groups --log-group-name-prefix "/aws/lambda/${PREFIX}" --query 'logGroups | length(@)' --output text --region "$REGION" 2>/dev/null || echo 0)
if [[ "$LG_COUNT" -ge 6 ]]; then
  pass "Lambda log groups: $LG_COUNT present"
else
  warn "Lambda log groups: $LG_COUNT (created on first invocation if missing)"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════"
echo "  Results: ${PASS} PASS  |  ${WARN} WARN  |  ${FAIL} FAIL"
echo "════════════════════════════════════════════════════════"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
