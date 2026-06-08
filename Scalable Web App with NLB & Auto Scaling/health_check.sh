#!/usr/bin/env bash
# health_check.sh — Full architecture health check for the Scalable Web App (NLB + Auto Scaling)
#
# Usage:
#   ./health_check.sh [--project-name NAME] [--environment ENV] [--region REGION]
#
# When run from the project directory, it reads terraform output -json first and
# uses the real deployed ARNs/IDs. Falls back to naming-pattern lookups if
# terraform is unavailable or state does not exist.
#
# Requires: aws CLI v2, jq, curl
# Optional: terraform (for direct output binding)

set -euo pipefail

###############################################################################
# Colour helpers
###############################################################################
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

pass()    { echo -e "  ${GREEN}[PASS]${RESET} $*"; PASS_COUNT=$((PASS_COUNT+1)); }
fail()    { echo -e "  ${RED}[FAIL]${RESET} $*"; FAIL_COUNT=$((FAIL_COUNT+1)); }
warn()    { echo -e "  ${YELLOW}[WARN]${RESET} $*"; WARN_COUNT=$((WARN_COUNT+1)); }
info()    { echo -e "  ${CYAN}[INFO]${RESET} $*"; }
section() { echo -e "\n${BOLD}$*${RESET}"; }

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

###############################################################################
# Parse defaults from prod.tfvars
###############################################################################
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TFVARS="${SCRIPT_DIR}/prod.tfvars"

tfvar() {
  local key="$1" default="${2:-}"
  if [[ -f "$TFVARS" ]]; then
    local val
    # Strip everything up to and including =, then strip surrounding whitespace and quotes.
    # Uses [[:space:]] instead of \s for BSD sed compatibility on macOS.
    val=$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$TFVARS" 2>/dev/null \
          | head -1 \
          | sed 's/.*=[[:space:]]*//' \
          | sed 's/^[[:space:]]*//' \
          | sed 's/[[:space:]]*$//' \
          | sed 's/"//g')
    echo "${val:-$default}"
  else
    echo "$default"
  fi
}

PROJECT_NAME=$(tfvar project_name "scalable-webapp")
ENVIRONMENT=$(tfvar environment  "prod")
REGION=$(tfvar region            "us-east-1")

###############################################################################
# CLI flag overrides
###############################################################################
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-name) PROJECT_NAME="$2"; shift 2;;
    --environment)  ENVIRONMENT="$2";  shift 2;;
    --region)       REGION="$2";       shift 2;;
    *) echo "Unknown flag: $1"; exit 1;;
  esac
done

AWS="aws --region ${REGION} --output json"

###############################################################################
# Load terraform outputs — bind every output to a TF_* variable
# Outputs used (must match outputs.tf exactly):
#   nlb_dns_name        → TF_NLB_DNS
#   nlb_arn             → TF_NLB_ARN
#   asg_name            → TF_ASG_NAME
#   asg_arn             → TF_ASG_ARN
#   launch_template_id  → TF_LT_ID
#   vpc_id              → TF_VPC_ID
#   public_subnet_ids   → TF_PUBLIC_SUBNETS  (JSON array)
#   private_subnet_ids  → TF_PRIVATE_SUBNETS (JSON array)
#   ec2_security_group_id → TF_EC2_SG_ID
#   iam_role_arn        → TF_IAM_ROLE_ARN
#   sns_topic_arn       → TF_SNS_ARN
#   target_group_arn    → TF_TG_ARN
###############################################################################
TF_NLB_DNS=""
TF_NLB_ARN=""
TF_ASG_NAME=""
TF_ASG_ARN=""
TF_LT_ID=""
TF_VPC_ID=""
TF_PUBLIC_SUBNETS="[]"
TF_PRIVATE_SUBNETS="[]"
TF_EC2_SG_ID=""
TF_IAM_ROLE_ARN=""
TF_SNS_ARN=""
TF_TG_ARN=""
TF_LOADED=false

if command -v terraform &>/dev/null && [[ -f "${SCRIPT_DIR}/terraform.tfstate" || -f "${SCRIPT_DIR}/.terraform/terraform.tfstate" ]]; then
  TF_OUT=$(cd "${SCRIPT_DIR}" && terraform output -json 2>/dev/null || echo "{}")
  if [[ "$TF_OUT" != "{}" && -n "$TF_OUT" ]]; then
    TF_NLB_DNS=$(echo        "$TF_OUT" | jq -r '.nlb_dns_name.value        // ""')
    TF_NLB_ARN=$(echo        "$TF_OUT" | jq -r '.nlb_arn.value             // ""')
    TF_ASG_NAME=$(echo       "$TF_OUT" | jq -r '.asg_name.value            // ""')
    TF_ASG_ARN=$(echo        "$TF_OUT" | jq -r '.asg_arn.value             // ""')
    TF_LT_ID=$(echo          "$TF_OUT" | jq -r '.launch_template_id.value  // ""')
    TF_VPC_ID=$(echo         "$TF_OUT" | jq -r '.vpc_id.value              // ""')
    TF_PUBLIC_SUBNETS=$(echo "$TF_OUT" | jq -c '.public_subnet_ids.value   // []')
    TF_PRIVATE_SUBNETS=$(echo "$TF_OUT"| jq -c '.private_subnet_ids.value  // []')
    TF_EC2_SG_ID=$(echo      "$TF_OUT" | jq -r '.ec2_security_group_id.value // ""')
    TF_IAM_ROLE_ARN=$(echo   "$TF_OUT" | jq -r '.iam_role_arn.value        // ""')
    TF_SNS_ARN=$(echo        "$TF_OUT" | jq -r '.sns_topic_arn.value       // ""')
    TF_TG_ARN=$(echo         "$TF_OUT" | jq -r '.target_group_arn.value    // ""')
    TF_LOADED=true
  fi
fi

# Fallback derived names — used only when TF output is unavailable
NLB_NAME="${PROJECT_NAME}-${ENVIRONMENT}-nlb"
ASG_NAME="${TF_ASG_NAME:-${PROJECT_NAME}-${ENVIRONMENT}-asg}"
TG_NAME="${PROJECT_NAME}-${ENVIRONMENT}-tg"
SNS_NAME="${PROJECT_NAME}-${ENVIRONMENT}-alarms"

# CloudWatch alarm prefix — all 5 alarms share this prefix (derived from convention)
# Real alarm names (confirmed via AWS API):
#   scalable-webapp-prod-cpu-high
#   scalable-webapp-prod-cpu-low
#   scalable-webapp-prod-unhealthy-hosts
#   scalable-webapp-prod-healthy-hosts-low
#   scalable-webapp-prod-network-in-high
ALARM_PREFIX="${PROJECT_NAME}-${ENVIRONMENT}"
ALARM_EXPECTED=5

###############################################################################
# Header
###############################################################################
echo -e "\n${BOLD}========================================${RESET}"
echo -e "${BOLD}  Architecture Health Check${RESET}"
echo -e "${BOLD}  Project : ${PROJECT_NAME}${RESET}"
echo -e "${BOLD}  Env     : ${ENVIRONMENT}${RESET}"
echo -e "${BOLD}  Region  : ${REGION}${RESET}"
echo -e "${BOLD}========================================${RESET}"

###############################################################################
# 0. Prerequisites
###############################################################################
section "0. Prerequisites"

for cmd in aws jq curl; do
  if command -v "$cmd" &>/dev/null; then
    pass "$cmd is installed"
  else
    fail "$cmd is NOT installed — install it before running this script"
    exit 1
  fi
done

if $AWS sts get-caller-identity &>/dev/null; then
  ACCOUNT_ID=$($AWS sts get-caller-identity | jq -r '.Account')
  pass "AWS credentials valid (account ${ACCOUNT_ID})"
else
  fail "AWS credentials are not configured or have expired"
  exit 1
fi

if [[ "$TF_LOADED" == "true" ]]; then
  pass "Terraform outputs loaded — using real ARNs from state"
else
  warn "Terraform outputs unavailable — falling back to naming-pattern lookups"
fi

###############################################################################
# 1. Network Load Balancer
# Output used: nlb_arn, nlb_dns_name
###############################################################################
section "1. Network Load Balancer  [outputs: nlb_arn, nlb_dns_name]"

NLB_ARN=""
NLB_DNS=""

if [[ -n "$TF_NLB_ARN" ]]; then
  # Use the ARN directly from terraform output
  NLB_JSON=$($AWS elbv2 describe-load-balancers --load-balancer-arns "${TF_NLB_ARN}" 2>/dev/null \
             || echo '{"LoadBalancers":[]}')
else
  NLB_JSON=$($AWS elbv2 describe-load-balancers --names "${NLB_NAME}" 2>/dev/null \
             || echo '{"LoadBalancers":[]}')
fi

NLB_COUNT=$(echo "$NLB_JSON" | jq '.LoadBalancers | length')

if [[ "$NLB_COUNT" -eq 0 ]]; then
  fail "NLB not found"
else
  NLB_STATE=$(echo "$NLB_JSON" | jq -r '.LoadBalancers[0].State.Code')
  NLB_ARN=$(echo   "$NLB_JSON" | jq -r '.LoadBalancers[0].LoadBalancerArn')
  NLB_DNS=$(echo   "$NLB_JSON" | jq -r '.LoadBalancers[0].DNSName')
  NLB_AZS=$(echo   "$NLB_JSON" | jq -r '[.LoadBalancers[0].AvailabilityZones[].ZoneName] | join(", ")')

  if [[ "$NLB_STATE" == "active" ]]; then
    pass "NLB state: active"
  else
    fail "NLB state: ${NLB_STATE} (expected: active)"
  fi

  # Cross-check DNS against terraform output
  if [[ -n "$TF_NLB_DNS" && "$NLB_DNS" != "$TF_NLB_DNS" ]]; then
    warn "DNS mismatch — terraform output: ${TF_NLB_DNS} | AWS API: ${NLB_DNS}"
  fi

  info "DNS  : ${NLB_DNS}"
  info "AZs  : ${NLB_AZS}"
  info "ARN  : ${NLB_ARN}"

  XZONE=$($AWS elbv2 describe-load-balancer-attributes --load-balancer-arn "${NLB_ARN}" \
    | jq -r '.Attributes[] | select(.Key=="load_balancing.cross_zone.enabled") | .Value')
  if [[ "$XZONE" == "true" ]]; then
    pass "Cross-zone load balancing: enabled"
  else
    warn "Cross-zone load balancing: disabled"
  fi
fi

###############################################################################
# 2. NLB Listeners
###############################################################################
section "2. NLB Listeners"

if [[ -n "${NLB_ARN}" ]]; then
  LISTENERS_JSON=$($AWS elbv2 describe-listeners --load-balancer-arn "${NLB_ARN}")
  LISTENER_COUNT=$(echo "$LISTENERS_JSON" | jq '.Listeners | length')

  if [[ "$LISTENER_COUNT" -eq 0 ]]; then
    fail "No listeners attached to NLB"
  else
    echo "$LISTENERS_JSON" | jq -r '.Listeners[] | "\(.Protocol):\(.Port)"' | while read -r l; do
      pass "Listener active: ${l}"
    done
  fi
else
  warn "Skipping listeners check — NLB ARN unavailable"
fi

###############################################################################
# 3. Target Group & Target Health
# Output used: target_group_arn
###############################################################################
section "3. Target Group & Target Health  [output: target_group_arn]"

TG_ARN=""

if [[ -n "$TF_TG_ARN" ]]; then
  TG_JSON=$($AWS elbv2 describe-target-groups --target-group-arns "${TF_TG_ARN}" 2>/dev/null \
            || echo '{"TargetGroups":[]}')
else
  TG_JSON=$($AWS elbv2 describe-target-groups --names "${TG_NAME}" 2>/dev/null \
            || echo '{"TargetGroups":[]}')
fi

TG_COUNT=$(echo "$TG_JSON" | jq '.TargetGroups | length')

if [[ "$TG_COUNT" -eq 0 ]]; then
  fail "Target group not found"
else
  TG_ARN=$(echo   "$TG_JSON" | jq -r '.TargetGroups[0].TargetGroupArn')
  TG_PORT=$(echo  "$TG_JSON" | jq -r '.TargetGroups[0].Port')
  TG_PROTO=$(echo "$TG_JSON" | jq -r '.TargetGroups[0].Protocol')
  pass "Target group found (${TG_PROTO}:${TG_PORT})"

  # Cross-check ARN against terraform output
  if [[ -n "$TF_TG_ARN" && "$TG_ARN" != "$TF_TG_ARN" ]]; then
    warn "ARN mismatch — terraform: ${TF_TG_ARN} | AWS API: ${TG_ARN}"
  fi

  HEALTH_JSON=$($AWS elbv2 describe-target-health --target-group-arn "${TG_ARN}")
  TOTAL=$(echo    "$HEALTH_JSON" | jq '.TargetHealthDescriptions | length')
  HEALTHY=$(echo  "$HEALTH_JSON" | jq '[.TargetHealthDescriptions[] | select(.TargetHealth.State=="healthy")] | length')
  UNHEALTHY=$(echo "$HEALTH_JSON"| jq '[.TargetHealthDescriptions[] | select(.TargetHealth.State!="healthy")] | length')

  info "Registered targets: ${TOTAL} | Healthy: ${HEALTHY} | Unhealthy: ${UNHEALTHY}"

  if [[ "$TOTAL" -eq 0 ]]; then
    fail "No targets registered in target group"
  elif [[ "$UNHEALTHY" -gt 0 ]]; then
    fail "${UNHEALTHY} unhealthy target(s) — check EC2 web server and security groups"
    echo "$HEALTH_JSON" | jq -r '.TargetHealthDescriptions[] | select(.TargetHealth.State!="healthy") | "    Target \(.Target.Id) → \(.TargetHealth.State): \(.TargetHealth.Description)"'
  else
    pass "All ${HEALTHY} targets are healthy"
  fi
fi

###############################################################################
# 4. Auto Scaling Group
# Output used: asg_name, asg_arn
###############################################################################
section "4. Auto Scaling Group  [outputs: asg_name, asg_arn]"

ASG_JSON=$($AWS autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "${ASG_NAME}" | jq '.AutoScalingGroups[0]')

if [[ "$ASG_JSON" == "null" ]]; then
  fail "ASG '${ASG_NAME}' not found"
else
  # Cross-check ARN
  LIVE_ASG_ARN=$(echo "$ASG_JSON" | jq -r '.AutoScalingGroupARN')
  if [[ -n "$TF_ASG_ARN" && "$LIVE_ASG_ARN" != "$TF_ASG_ARN" ]]; then
    warn "ASG ARN mismatch — terraform: ${TF_ASG_ARN} | AWS API: ${LIVE_ASG_ARN}"
  fi

  ASG_STATUS=$(echo  "$ASG_JSON" | jq -r '.Status // "active"')
  ASG_MIN=$(echo     "$ASG_JSON" | jq -r '.MinSize')
  ASG_MAX=$(echo     "$ASG_JSON" | jq -r '.MaxSize')
  ASG_DESIRED=$(echo "$ASG_JSON" | jq -r '.DesiredCapacity')
  IN_SERVICE=$(echo  "$ASG_JSON" | jq '[.Instances[] | select(.LifecycleState=="InService")] | length')

  info "Min: ${ASG_MIN} | Max: ${ASG_MAX} | Desired: ${ASG_DESIRED} | InService: ${IN_SERVICE}"

  if [[ "$ASG_STATUS" == "Delete in progress" ]]; then
    fail "ASG is being deleted"
  else
    pass "ASG exists and is active"
  fi

  if [[ "$IN_SERVICE" -ge "$ASG_MIN" ]]; then
    pass "InService instances (${IN_SERVICE}) >= minimum (${ASG_MIN})"
  else
    fail "InService instances (${IN_SERVICE}) is below minimum (${ASG_MIN})"
  fi

  if [[ "$IN_SERVICE" -eq "$ASG_DESIRED" ]]; then
    pass "InService count matches desired capacity (${ASG_DESIRED})"
  else
    warn "InService (${IN_SERVICE}) != Desired (${ASG_DESIRED}) — scaling may be in progress"
  fi

  NOT_HEALTHY=$(echo "$ASG_JSON" | jq '[.Instances[] | select(.LifecycleState!="InService")] | length')
  if [[ "$NOT_HEALTHY" -gt 0 ]]; then
    warn "${NOT_HEALTHY} instance(s) not yet InService:"
    echo "$ASG_JSON" | jq -r '.Instances[] | select(.LifecycleState!="InService") | "    \(.InstanceId) → \(.LifecycleState) (\(.HealthStatus))"'
  fi

  REFRESH_JSON=$($AWS autoscaling describe-instance-refreshes \
    --auto-scaling-group-name "${ASG_NAME}" \
    | jq '[.InstanceRefreshes[] | select(.Status | IN("InProgress","Pending","Cancelling"))]')
  if [[ "$(echo "$REFRESH_JSON" | jq 'length')" -gt 0 ]]; then
    warn "An instance refresh is currently in progress"
  else
    pass "No active instance refresh"
  fi
fi

###############################################################################
# 5. Launch Template
# Output used: launch_template_id
###############################################################################
section "5. Launch Template  [output: launch_template_id]"

if [[ -n "$TF_LT_ID" ]]; then
  LT_JSON=$($AWS ec2 describe-launch-templates \
    --launch-template-ids "${TF_LT_ID}" 2>/dev/null || echo '{"LaunchTemplates":[]}')
  LT_COUNT=$(echo "$LT_JSON" | jq '.LaunchTemplates | length')

  if [[ "$LT_COUNT" -eq 0 ]]; then
    fail "Launch template '${TF_LT_ID}' (from terraform output) not found in AWS"
  else
    LT_NAME=$(echo     "$LT_JSON" | jq -r '.LaunchTemplates[0].LaunchTemplateName')
    LT_VERSION=$(echo  "$LT_JSON" | jq -r '.LaunchTemplates[0].LatestVersionNumber')
    LT_DEFAULT=$(echo  "$LT_JSON" | jq -r '.LaunchTemplates[0].DefaultVersionNumber')
    pass "Launch template found: ${LT_NAME}"
    info "Latest version: ${LT_VERSION} | Default version: ${LT_DEFAULT}"
  fi
else
  warn "Launch template ID not available — terraform outputs not loaded"
fi

###############################################################################
# 6. EC2 Security Group
# Output used: ec2_security_group_id
###############################################################################
section "6. EC2 Security Group  [output: ec2_security_group_id]"

if [[ -n "$TF_EC2_SG_ID" ]]; then
  SG_JSON=$($AWS ec2 describe-security-groups \
    --group-ids "${TF_EC2_SG_ID}" 2>/dev/null || echo '{"SecurityGroups":[]}')
  SG_COUNT=$(echo "$SG_JSON" | jq '.SecurityGroups | length')

  if [[ "$SG_COUNT" -eq 0 ]]; then
    fail "EC2 security group '${TF_EC2_SG_ID}' not found in AWS"
  else
    SG_NAME=$(echo "$SG_JSON" | jq -r '.SecurityGroups[0].GroupName')
    INGRESS=$(echo "$SG_JSON" | jq '.SecurityGroups[0].IpPermissions | length')
    pass "EC2 security group exists: ${SG_NAME} (${TF_EC2_SG_ID})"
    info "Ingress rules: ${INGRESS}"

    # Verify port 80 ingress exists
    HAS_80=$(echo "$SG_JSON" | jq '[.SecurityGroups[0].IpPermissions[] | select(.FromPort==80 and .ToPort==80)] | length')
    if [[ "$HAS_80" -gt 0 ]]; then
      pass "Port 80 ingress rule present"
    else
      warn "No port 80 ingress rule found in EC2 security group"
    fi
  fi
else
  warn "EC2 security group ID not available — terraform outputs not loaded"
fi

###############################################################################
# 7. IAM Role
# Output used: iam_role_arn
###############################################################################
section "7. IAM Role  [output: iam_role_arn]"

if [[ -n "$TF_IAM_ROLE_ARN" ]]; then
  ROLE_NAME=$(echo "$TF_IAM_ROLE_ARN" | sed 's|.*/||')
  ROLE_JSON=$($AWS iam get-role --role-name "${ROLE_NAME}" 2>/dev/null || echo '{}')
  ROLE_EXISTS=$(echo "$ROLE_JSON" | jq -r '.Role.RoleName // ""')

  if [[ -z "$ROLE_EXISTS" ]]; then
    fail "IAM role '${ROLE_NAME}' not found in AWS"
  else
    pass "IAM role exists: ${ROLE_NAME}"

    # Verify SSM policy is attached
    POLICIES=$($AWS iam list-attached-role-policies --role-name "${ROLE_NAME}" \
      | jq -r '[.AttachedPolicies[].PolicyName] | join(", ")')
    info "Attached policies: ${POLICIES}"

    HAS_SSM=$(echo "$POLICIES" | grep -c "AmazonSSMManagedInstanceCore" || true)
    if [[ "$HAS_SSM" -gt 0 ]]; then
      pass "AmazonSSMManagedInstanceCore policy attached"
    else
      warn "AmazonSSMManagedInstanceCore not attached — SSM Session Manager may not work"
    fi
  fi
else
  warn "IAM role ARN not available — terraform outputs not loaded"
fi

###############################################################################
# 8. EC2 Instances
###############################################################################
section "8. EC2 Instances"

EC2_JSON=$($AWS ec2 describe-instances \
  --filters \
    "Name=tag:Project,Values=${PROJECT_NAME}" \
    "Name=tag:Environment,Values=${ENVIRONMENT}" \
    "Name=instance-state-name,Values=running,pending" \
  | jq '[.Reservations[].Instances[]]')

EC2_TOTAL=$(echo   "$EC2_JSON" | jq 'length')
EC2_RUNNING=$(echo "$EC2_JSON" | jq '[.[] | select(.State.Name=="running")] | length')

if [[ "$EC2_TOTAL" -eq 0 ]]; then
  fail "No EC2 instances found with project/environment tags"
else
  pass "EC2 instances found: ${EC2_TOTAL} (running: ${EC2_RUNNING})"
  echo "$EC2_JSON" | jq -r '.[] | "    \(.InstanceId) | \(.InstanceType) | \(.Placement.AvailabilityZone) | \(.State.Name)"'
fi

AZ_COUNT=$(echo "$EC2_JSON" | jq '[.[].Placement.AvailabilityZone] | unique | length')
if [[ "$AZ_COUNT" -ge 2 ]]; then
  pass "Instances spread across ${AZ_COUNT} availability zones"
elif [[ "$EC2_TOTAL" -ge 2 ]]; then
  warn "All instances are in a single AZ — check subnet configuration"
fi

###############################################################################
# 9. CloudWatch Alarms
# Uses --alarm-name-prefix for reliable detection regardless of exact name order.
# Expected alarms (5 total):
#   cpu-high          → OK when idle, triggers scale-out at >70% CPU
#   cpu-low           → ALARM when idle (no traffic); min_size=2 prevents scale-in below 2
#   unhealthy-hosts   → should be OK once targets are healthy
#   healthy-hosts-low → should be OK once targets pass health checks
#   network-in-high   → OK unless >1 GB/5 min of inbound traffic
###############################################################################
section "9. CloudWatch Alarms"

ALARMS_JSON=$($AWS cloudwatch describe-alarms \
  --alarm-name-prefix "${ALARM_PREFIX}" | jq '.MetricAlarms')

ALARM_TOTAL=$(echo "$ALARMS_JSON" | jq 'length')

if [[ "$ALARM_TOTAL" -eq 0 ]]; then
  fail "No CloudWatch alarms found with prefix '${ALARM_PREFIX}' — check deployment"
else
  if [[ "$ALARM_TOTAL" -ge "$ALARM_EXPECTED" ]]; then
    pass "Found ${ALARM_TOTAL} CloudWatch alarms (expected ${ALARM_EXPECTED})"
  else
    warn "Found ${ALARM_TOTAL} of ${ALARM_EXPECTED} expected alarms — some may be missing"
  fi

  IN_ALARM=$(echo "$ALARMS_JSON" | jq '[.[] | select(.StateValue=="ALARM")] | length')
  OK_COUNT=$(echo "$ALARMS_JSON" | jq '[.[] | select(.StateValue=="OK")] | length')
  INSUF=$(echo    "$ALARMS_JSON" | jq '[.[] | select(.StateValue=="INSUFFICIENT_DATA")] | length')

  # cpu-low ALARM is expected on idle instances — not a real failure
  UNEXPECTED_ALARM=$(echo "$ALARMS_JSON" | jq \
    '[.[] | select(.StateValue=="ALARM" and (.AlarmName | endswith("cpu-low") | not))] | length')

  if [[ "$UNEXPECTED_ALARM" -gt 0 ]]; then
    fail "${UNEXPECTED_ALARM} unexpected alarm(s) firing:"
    echo "$ALARMS_JSON" | jq -r \
      '.[] | select(.StateValue=="ALARM" and (.AlarmName | endswith("cpu-low") | not)) |
       "    [ALARM] \(.AlarmName): \(.StateReason)"'
  else
    pass "No unexpected alarms firing"
  fi

  [[ "$IN_ALARM" -gt 0 ]] && info "ALARM (expected: cpu-low when idle): ${IN_ALARM}"
  [[ "$OK_COUNT" -gt 0 ]] && info "OK                                 : ${OK_COUNT}"
  [[ "$INSUF"    -gt 0 ]] && info "INSUFFICIENT_DATA (new NLB — resolves in ~2 min): ${INSUF}"

  echo ""
  echo "$ALARMS_JSON" | jq -r '.[] | "    \(.StateValue | if .=="ALARM" then "[ALARM]" elif .=="OK" then "[OK]   " else "[INSUF]" end) \(.AlarmName)"'
fi

###############################################################################
# 10. Scaling Policies
###############################################################################
section "10. Scaling Policies"

POLICIES_JSON=$($AWS autoscaling describe-policies \
  --auto-scaling-group-name "${ASG_NAME}" 2>/dev/null \
  || echo '{"ScalingPolicies":[]}')
POLICY_COUNT=$(echo "$POLICIES_JSON" | jq '.ScalingPolicies | length')

if [[ "$POLICY_COUNT" -ge 2 ]]; then
  pass "Scaling policies attached: ${POLICY_COUNT}"
  echo "$POLICIES_JSON" | jq -r '.ScalingPolicies[] | "    \(.PolicyName) → adjustment: \(.ScalingAdjustment)"'
else
  warn "Expected 2 scaling policies (scale-out, scale-in), found: ${POLICY_COUNT}"
fi

###############################################################################
# 11. NAT Gateways
# Output used: vpc_id
###############################################################################
section "11. NAT Gateways  [output: vpc_id]"

# Prefer VPC ID from terraform output; fall back to tag-based lookup
VPC_ID="${TF_VPC_ID}"
if [[ -z "$VPC_ID" ]]; then
  VPC_ID=$($AWS ec2 describe-vpcs \
    --filters "Name=tag:Project,Values=${PROJECT_NAME}" \
    | jq -r '.Vpcs[0].VpcId // ""')
fi

if [[ -n "$VPC_ID" ]]; then
  NAT_JSON=$($AWS ec2 describe-nat-gateways \
    --filter "Name=vpc-id,Values=${VPC_ID}" "Name=state,Values=available" \
    | jq '.NatGateways')
  NAT_COUNT=$(echo "$NAT_JSON" | jq 'length')

  if [[ "$NAT_COUNT" -ge 2 ]]; then
    pass "NAT Gateways available: ${NAT_COUNT} (one per AZ — HA configuration)"
  elif [[ "$NAT_COUNT" -eq 1 ]]; then
    warn "Only 1 NAT Gateway found — single point of failure for private subnet egress"
  else
    fail "No available NAT Gateways in VPC ${VPC_ID} — private instances cannot reach the internet"
  fi
else
  fail "VPC ID could not be determined — cannot check NAT Gateways"
fi

###############################################################################
# 12. VPC & Subnets
# Output used: vpc_id, public_subnet_ids, private_subnet_ids
###############################################################################
section "12. VPC & Subnets  [outputs: vpc_id, public_subnet_ids, private_subnet_ids]"

if [[ -n "$VPC_ID" ]]; then
  VPC_JSON=$($AWS ec2 describe-vpcs --vpc-ids "${VPC_ID}" | jq '.Vpcs[0]')
  VPC_CIDR=$(echo  "$VPC_JSON" | jq -r '.CidrBlock')
  VPC_STATE=$(echo "$VPC_JSON" | jq -r '.State')

  if [[ "$VPC_STATE" == "available" ]]; then
    pass "VPC ${VPC_ID} (${VPC_CIDR}) is available"
  else
    fail "VPC ${VPC_ID} state: ${VPC_STATE}"
  fi

  # Validate subnets from terraform output against what exists in AWS
  PUB_COUNT=$(echo "$TF_PUBLIC_SUBNETS"  | jq 'length')
  PRI_COUNT=$(echo "$TF_PRIVATE_SUBNETS" | jq 'length')

  if [[ "$PUB_COUNT" -ge 2 ]]; then
    pass "Public subnets in terraform output: ${PUB_COUNT}"
  else
    warn "Expected 2 public subnets in terraform output, found: ${PUB_COUNT}"
  fi

  if [[ "$PRI_COUNT" -ge 2 ]]; then
    pass "Private subnets in terraform output: ${PRI_COUNT}"
  else
    warn "Expected 2 private subnets in terraform output, found: ${PRI_COUNT}"
  fi

  # Confirm all output subnets actually exist in AWS
  ALL_SUBNETS=$(echo "${TF_PUBLIC_SUBNETS} ${TF_PRIVATE_SUBNETS}" \
    | jq -s 'add | unique | map(select(. != null)) | join(",")')
  ALL_SUBNETS="${ALL_SUBNETS//\"/}"

  if [[ -n "$ALL_SUBNETS" && "$ALL_SUBNETS" != "," ]]; then
    LIVE_SUBNET_COUNT=$($AWS ec2 describe-subnets \
      --filters "Name=vpc-id,Values=${VPC_ID}" \
      | jq '.Subnets | length')
    info "Total subnets in VPC: ${LIVE_SUBNET_COUNT}"
    if [[ "$LIVE_SUBNET_COUNT" -ge 4 ]]; then
      pass "Subnet count correct (expected 4+, found ${LIVE_SUBNET_COUNT})"
    else
      warn "Expected at least 4 subnets, found ${LIVE_SUBNET_COUNT}"
    fi
  fi
else
  fail "VPC ID not available — cannot check subnets"
fi

###############################################################################
# 13. SNS Topic & Subscription
# Output used: sns_topic_arn
###############################################################################
section "13. SNS Topic & Subscription  [output: sns_topic_arn]"

SNS_ARN="${TF_SNS_ARN}"

if [[ -z "$SNS_ARN" ]]; then
  SNS_JSON=$($AWS sns list-topics | jq --arg name "$SNS_NAME" \
    '[.Topics[] | select(.TopicArn | endswith(":"+$name))]')
  SNS_ARN=$(echo "$SNS_JSON" | jq -r '.[0].TopicArn // ""')
fi

if [[ -z "$SNS_ARN" ]]; then
  fail "SNS topic not found"
else
  pass "SNS topic exists: ${SNS_ARN}"

  SUB_JSON=$($AWS sns list-subscriptions-by-topic --topic-arn "${SNS_ARN}")
  SUB_CONFIRMED=$(echo "$SUB_JSON" | jq '[.Subscriptions[] | select(.SubscriptionArn != "PendingConfirmation")] | length')
  SUB_PENDING=$(echo   "$SUB_JSON" | jq '[.Subscriptions[] | select(.SubscriptionArn == "PendingConfirmation")] | length')

  if [[ "$SUB_CONFIRMED" -gt 0 ]]; then
    pass "SNS subscription confirmed: ${SUB_CONFIRMED}"
  else
    warn "No confirmed SNS subscriptions — alarm emails will not be delivered. Confirm via email."
  fi
  [[ "$SUB_PENDING" -gt 0 ]] && warn "Pending confirmation: ${SUB_PENDING} subscription(s)"
fi

###############################################################################
# 14. HTTP Endpoint Reachability
###############################################################################
section "14. HTTP Endpoint Reachability"

NLB_DNS_CHECK="${NLB_DNS:-${TF_NLB_DNS}}"

if [[ -n "${NLB_DNS_CHECK}" ]]; then
  info "Testing HTTP → http://${NLB_DNS_CHECK}/"
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
    "http://${NLB_DNS_CHECK}/" 2>/dev/null || echo "000")

  if [[ "$HTTP_CODE" == "200" ]]; then
    pass "HTTP 200 — web server is responding"
  elif [[ "$HTTP_CODE" == "000" ]]; then
    fail "Connection failed (timeout or refused) — DNS may not have propagated, or no healthy targets"
  else
    warn "HTTP ${HTTP_CODE} response (expected 200)"
  fi
else
  warn "Skipping HTTP check — NLB DNS unavailable"
fi

###############################################################################
# Summary
###############################################################################
echo ""
echo -e "${BOLD}========================================${RESET}"
echo -e "${BOLD}  Health Check Summary${RESET}"
echo -e "${BOLD}========================================${RESET}"
echo -e "  ${GREEN}PASS${RESET}: ${PASS_COUNT}"
echo -e "  ${YELLOW}WARN${RESET}: ${WARN_COUNT}"
echo -e "  ${RED}FAIL${RESET}: ${FAIL_COUNT}"
echo ""

if [[ "$FAIL_COUNT" -eq 0 && "$WARN_COUNT" -eq 0 ]]; then
  echo -e "${GREEN}${BOLD}All checks passed — architecture is healthy.${RESET}"
elif [[ "$FAIL_COUNT" -eq 0 ]]; then
  echo -e "${YELLOW}${BOLD}Architecture is running with ${WARN_COUNT} warning(s). Review warnings above.${RESET}"
else
  echo -e "${RED}${BOLD}${FAIL_COUNT} check(s) failed. Investigate the FAIL items above.${RESET}"
fi
echo ""

exit $FAIL_COUNT
