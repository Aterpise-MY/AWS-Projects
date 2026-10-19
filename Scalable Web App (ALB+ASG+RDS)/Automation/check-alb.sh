#!/usr/bin/env bash
# Check whether the WebApp ALB is up and serving traffic over HTTPS, and that
# the RDS database tier behind it is in the expected state.
#
# Usage:
#   ./check-alb.sh [HOSTNAME]
#
# HOSTNAME is the name the certificate is issued for (var.domain_name). It
# defaults to webapp-alb.aterpise.com. The resource names below follow the
# default app_name ("WebApp").
#
# Every AWS call is read-only (describe). The HTTPS request checks the
# certificate: curl runs without -k and with -q, so a ~/.curlrc cannot turn
# the certificate check off.
#
# Requires: aws CLI, python3, curl
set -euo pipefail

ALB_NAME="WebAppALB"
TG_NAME="WebApp-tg"
DB_ID="webapp-db"            # lower(app_name)-db
EC2_SG_NAME="WebApp-ec2-sg"  # <app_name>-ec2-sg
REGION="us-east-1"
DOMAIN_NAME="${1:-webapp-alb.aterpise.com}"

HOSTNAME_RE='^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$'
if [[ ! "$DOMAIN_NAME" =~ $HOSTNAME_RE ]]; then
  echo "Usage: $0 [HOSTNAME]" >&2
  exit 2
fi
NL=$'\n'

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
info "Hostname: $DOMAIN_NAME"
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

# ── 3. Database (RDS for PostgreSQL, Multi-AZ DB instance) ───────────────────
# One DB identifier: a primary plus a synchronous standby in a second AZ.
# The security groups examined are the ones attached to the instance. Expected:
# one ingress rule, TCP 5432 from the EC2 security group by reference.
DB_JSON=$(aws rds describe-db-instances \
  --db-instance-identifier "$DB_ID" \
  --region "$REGION" \
  --query "DBInstances[0]" \
  --output json 2>/dev/null) || { fail "RDS instance \"$DB_ID\" not found"; DB_JSON=""; }

if [[ -n "$DB_JSON" ]]; then
  db_field() { echo "$DB_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print($1)"; }

  DB_STATUS=$(   db_field "d['DBInstanceStatus']")
  DB_MULTI_AZ=$( db_field "d['MultiAZ']")
  DB_PUBLIC=$(   db_field "d['PubliclyAccessible']")
  DB_ENCRYPTED=$(db_field "d['StorageEncrypted']")
  DB_VPC_ID=$(   db_field "d['DBSubnetGroup']['VpcId']")
  DB_SG_IDS=$(   db_field "','.join(g['VpcSecurityGroupId'] for g in d['VpcSecurityGroups'])")

  if [[ "$DB_STATUS" == "available" ]]; then
    ok "RDS instance $DB_ID: $DB_STATUS"
  else
    fail "RDS instance $DB_ID: $DB_STATUS (expected: available)"
  fi

  if [[ "$DB_MULTI_AZ" == "True" ]]; then
    ok "Multi-AZ: on (primary plus synchronous standby)"
  else
    fail "Multi-AZ: off (expected: on)"
  fi

  if [[ "$DB_PUBLIC" == "False" ]]; then
    ok "Publicly accessible: no"
  else
    fail "Publicly accessible: $DB_PUBLIC (expected: False)"
  fi

  if [[ "$DB_ENCRYPTED" == "True" ]]; then
    ok "Storage encrypted: yes"
  else
    fail "Storage encrypted: $DB_ENCRYPTED (expected: True)"
  fi

  # DB security group — ingress only from the EC2 security group.
  EC2_SG_ID=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=$EC2_SG_NAME" "Name=vpc-id,Values=$DB_VPC_ID" \
    --region "$REGION" \
    --query "SecurityGroups[0].GroupId" \
    --output text 2>/dev/null) || EC2_SG_ID=""
  if [[ "$EC2_SG_ID" == "None" ]]; then EC2_SG_ID=""; fi

  if [[ -z "$DB_SG_IDS" ]]; then
    fail "RDS instance has no VPC security group attached"
  elif [[ -z "$EC2_SG_ID" ]]; then
    warn "EC2 security group \"$EC2_SG_NAME\" not found — DB security group ingress not checked"
  else
    SG_JSON=$(aws ec2 describe-security-groups \
      --filters "Name=group-id,Values=$DB_SG_IDS" \
      --region "$REGION" \
      --output json 2>/dev/null) || SG_JSON='{"SecurityGroups":[]}'

    SG_VERDICT=$(echo "$SG_JSON" | python3 -c "
import sys, json
ec2_sg = sys.argv[1]
groups = json.load(sys.stdin)['SecurityGroups']
perms = [p for g in groups for p in g.get('IpPermissions', [])]
def only_ec2(p):
    return (p.get('IpProtocol') == 'tcp' and p.get('FromPort') == 5432 and p.get('ToPort') == 5432
            and not p.get('IpRanges') and not p.get('Ipv6Ranges') and not p.get('PrefixListIds')
            and [u.get('GroupId') for u in p.get('UserIdGroupPairs', [])] == [ec2_sg])
if not groups:
    print('unreadable')
elif not perms:
    print('none')
elif all(only_ec2(p) for p in perms):
    print('ok')
else:
    print('other')
" "$EC2_SG_ID")

    case "$SG_VERDICT" in
      ok)         ok   "DB security group ingress: TCP 5432 from $EC2_SG_NAME ($EC2_SG_ID) only" ;;
      none)       fail "DB security group has no ingress rule — instances cannot reach the database" ;;
      unreadable) warn "DB security group(s) $DB_SG_IDS could not be read — ingress not checked" ;;
      *)          fail "DB security group has ingress other than TCP 5432 from $EC2_SG_NAME ($EC2_SG_ID)" ;;
    esac
  fi
fi

# ── 4. HTTPS reachability, certificate and database status line ──────────────
# The request goes to the hostname: the certificate does not cover the ALB DNS
# name. curl checks the certificate chain and the hostname.
#
# The page carries a boot-time database status line, exactly
#   <p>Database: <strong id="db-status">connected</strong></p>
# or the same with "unreachable". It is a snapshot taken once when the instance
# booted, and one request reads the page of one instance. An instance serves
# the page with "unreachable" first and rewrites it to "connected" only if its
# check succeeds, so for up to about a minute after boot "unreachable" can mean
# that the check has not finished yet.
if [[ "$STATE" == "active" ]]; then
  HTTPS_RC=0
  HTTPS_RESP=$(curl -q -s --max-time 10 -w '\n%{http_code}' "https://$DOMAIN_NAME/" 2>/dev/null) || HTTPS_RC=$?
  HTTP_CODE=${HTTPS_RESP##*"$NL"}
  HTTPS_BODY=${HTTPS_RESP%"$NL"*}

  if [[ "$HTTPS_RC" -eq 0 && "$HTTP_CODE" == "200" ]]; then
    ok "HTTPS GET / → $HTTP_CODE (certificate valid for $DOMAIN_NAME)"

    if grep -qF '<p>Database: <strong id="db-status">connected</strong></p>' <<< "$HTTPS_BODY"; then
      ok "Page reports Database: connected"
    elif grep -qF '<p>Database: <strong id="db-status">unreachable</strong></p>' <<< "$HTTPS_BODY"; then
      fail "Page reports Database: unreachable — normal for about the first minute after an instance boots; if it persists, that instance could not reach the database when it booted"
    else
      warn "No database status line on the page"
    fi
  elif [[ "$HTTPS_RC" -eq 0 ]]; then
    warn "HTTPS GET / → $HTTP_CODE (certificate valid for $DOMAIN_NAME) — database status line not checked"
  elif [[ "$HTTPS_RC" -eq 60 || "$HTTPS_RC" -eq 51 ]]; then
    fail "HTTPS GET / → certificate check failed for $DOMAIN_NAME (curl exit $HTTPS_RC): not trusted, expired, or issued for another name"
  elif [[ "$HTTPS_RC" -eq 6 || "$HTTPS_RC" -eq 7 || "$HTTPS_RC" -eq 28 ]]; then
    warn "HTTPS GET / → no response (timeout or DNS not resolved yet)"
  else
    fail "HTTPS GET / → request failed (curl exit $HTTPS_RC)"
  fi

  # ── 5. Port 80 → 301 redirect to HTTPS ─────────────────────────────────────
  # The HTTP:80 listener carries no application traffic: every request is
  # answered with a permanent redirect to HTTPS on 443.
  REDIRECT=$(curl -q -s -o /dev/null -w '%{http_code} %{redirect_url}' --max-time 5 "http://$DOMAIN_NAME/" 2>/dev/null) || true
  REDIRECT_CODE="${REDIRECT%% *}"
  REDIRECT_URL="${REDIRECT#* }"
  if [[ "$REDIRECT_CODE" == "301" && "$REDIRECT_URL" == https://* ]]; then
    ok "HTTP GET / on port 80 → 301 to $REDIRECT_URL"
  elif [[ -z "$REDIRECT_CODE" || "$REDIRECT_CODE" == "000" ]]; then
    warn "HTTP GET / on port 80 → no response (timeout or DNS not resolved yet)"
  else
    fail "HTTP GET / on port 80 → $REDIRECT_CODE ${REDIRECT_URL:+to $REDIRECT_URL }(expected 301 to https://)"
  fi
else
  info "Skipping HTTPS and port 80 checks — ALB not active yet"
fi

echo ""
