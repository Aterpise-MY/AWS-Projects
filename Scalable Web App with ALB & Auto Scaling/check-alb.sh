#!/usr/bin/env bash
# Check whether the WebApp ALB is up and serving traffic.
set -euo pipefail

ALB_NAME="WebAppALB"
TG_NAME="WebApp-tg"
REGION="us-east-1"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

ok()   { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn() { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
fail() { echo -e "${RED}[FAIL]${RESET}  $*"; }
info() { echo -e "${CYAN}[INFO]${RESET}  $*"; }

echo ""
info "Checking ALB: $ALB_NAME  (region: $REGION)"
echo "────────────────────────────────────────────"

# ── 1. ALB state ─────────────────────────────────────────────────────────────
ALB_JSON=$(aws elbv2 describe-load-balancers \
  --names "$ALB_NAME" \
  --region "$REGION" \
  --query "LoadBalancers[0]" \
  --output json 2>/dev/null) || { fail "ALB \"$ALB_NAME\" not found (not deployed yet?)"; echo ""; exit 1; }

STATE=$(echo "$ALB_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['State']['Code'])")
DNS=$(echo  "$ALB_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['DNSName'])")

if [[ "$STATE" == "active" ]]; then
  ok "ALB state: $STATE"
elif [[ "$STATE" == "provisioning" ]]; then
  warn "ALB state: $STATE — still starting up, check again in a minute"
else
  fail "ALB state: $STATE"
fi

info "DNS: $DNS"

# ── 2. Target group healthy count ────────────────────────────────────────────
TG_ARN=$(aws elbv2 describe-target-groups \
  --names "$TG_NAME" \
  --region "$REGION" \
  --query "TargetGroups[0].TargetGroupArn" \
  --output text 2>/dev/null) || { warn "Target group \"$TG_NAME\" not found"; TG_ARN=""; }

if [[ -n "$TG_ARN" ]]; then
  HEALTH_JSON=$(aws elbv2 describe-target-health \
    --target-group-arn "$TG_ARN" \
    --region "$REGION" \
    --output json)

  HEALTHY=$(  echo "$HEALTH_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin)['TargetHealthDescriptions']; print(sum(1 for t in d if t['TargetHealth']['State']=='healthy'))")
  TOTAL=$(    echo "$HEALTH_JSON" | python3 -c "import sys,json; print(len(json.load(sys.stdin)['TargetHealthDescriptions']))")
  UNHEALTHY=$(echo "$HEALTH_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin)['TargetHealthDescriptions']; print(sum(1 for t in d if t['TargetHealth']['State']=='unhealthy'))")

  if [[ "$HEALTHY" -gt 0 ]]; then
    ok "Target group: $HEALTHY/$TOTAL instances healthy"
  elif [[ "$TOTAL" -gt 0 ]]; then
    warn "Target group: $HEALTHY/$TOTAL healthy  ($UNHEALTHY unhealthy — instances may still be initialising)"
  else
    warn "Target group: no registered targets yet"
  fi
fi

# ── 3. HTTP reachability ──────────────────────────────────────────────────────
if [[ "$STATE" == "active" ]]; then
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://$DNS" 2>/dev/null || echo "000")
  if [[ "$HTTP_CODE" == "200" ]]; then
    ok "HTTP GET / → $HTTP_CODE"
  elif [[ "$HTTP_CODE" == "000" ]]; then
    warn "HTTP GET / → no response (timeout or DNS not resolved yet)"
  else
    warn "HTTP GET / → $HTTP_CODE"
  fi
else
  info "Skipping HTTP check — ALB not active yet"
fi

echo ""
