#!/usr/bin/env bash
# =============================================================================
# health_check.sh — Post-deploy infrastructure health check
#
# Required env vars (exported from Terraform outputs in CI):
#   TF_OUT_USER_POOL_ID      Cognito User Pool ID
#   TF_OUT_RDS_ENDPOINT      RDS writer endpoint (used to derive DB identifier)
#   TF_OUT_API_GATEWAY_URL   API Gateway invoke URL
#   AWS_REGION               e.g. us-east-1
#   ENVIRONMENT              dev | staging | prod
# =============================================================================

set -euo pipefail
FAIL=0

log()  { echo "[health] $*"; }
pass() { echo "[health] PASS — $*"; }
fail() { echo "[health] FAIL — $*"; FAIL=1; }

# ── 1. Cognito User Pool ──────────────────────────────────────────────────────
log "Checking Cognito User Pool ${TF_OUT_USER_POOL_ID} …"
POOL_STATUS=$(aws cognito-idp describe-user-pool \
  --user-pool-id "$TF_OUT_USER_POOL_ID" \
  --query "UserPool.Status" --output text 2>/dev/null || echo "ERROR")

if [ "$POOL_STATUS" = "Enabled" ] || [ "$POOL_STATUS" = "None" ]; then
  pass "Cognito User Pool status: ${POOL_STATUS}"
else
  fail "Cognito User Pool status unexpected: ${POOL_STATUS}"
fi

# ── 2. RDS Instance ───────────────────────────────────────────────────────────
# Derive identifier from endpoint hostname (first segment before the first dot)
DB_ID=$(echo "$TF_OUT_RDS_ENDPOINT" | cut -d. -f1)
log "Checking RDS instance ${DB_ID} …"
DB_STATUS=$(aws rds describe-db-instances \
  --db-instance-identifier "$DB_ID" \
  --query "DBInstances[0].DBInstanceStatus" --output text 2>/dev/null || echo "ERROR")

if [ "$DB_STATUS" = "available" ]; then
  pass "RDS status: available"
else
  fail "RDS status unexpected: ${DB_STATUS}"
fi

# ── 3. Lambda Functions ───────────────────────────────────────────────────────
for FN in saas-users saas-orders saas-auth; do
  log "Checking Lambda function ${FN} …"
  FN_STATE=$(aws lambda get-function \
    --function-name "$FN" \
    --query "Configuration.State" --output text 2>/dev/null || echo "ERROR")

  if [ "$FN_STATE" = "Active" ]; then
    pass "Lambda ${FN}: Active"
  else
    fail "Lambda ${FN} state: ${FN_STATE}"
  fi
done

# ── 4. API Gateway reachability ───────────────────────────────────────────────
if [ -n "${TF_OUT_API_GATEWAY_URL:-}" ]; then
  log "Checking API Gateway ${TF_OUT_API_GATEWAY_URL} …"
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    --max-time 10 "${TF_OUT_API_GATEWAY_URL}/users" || echo "000")

  # 401/403 = gateway is up but requires auth — that is healthy
  if [[ "$HTTP_CODE" =~ ^(200|201|401|403|404)$ ]]; then
    pass "API Gateway responded HTTP ${HTTP_CODE}"
  else
    fail "API Gateway returned HTTP ${HTTP_CODE} (expected 2xx/401/403)"
  fi
else
  log "Skipping API Gateway check — TF_OUT_API_GATEWAY_URL not set"
fi

# ── Result ────────────────────────────────────────────────────────────────────
echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "All health checks PASSED for environment: ${ENVIRONMENT}"
  exit 0
else
  echo "One or more health checks FAILED for environment: ${ENVIRONMENT}"
  exit 1
fi
