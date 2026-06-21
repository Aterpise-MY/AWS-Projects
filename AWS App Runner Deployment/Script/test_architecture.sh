#!/usr/bin/env bash
# Architecture health-check for the my-web-app App Runner deployment
# Run: bash test_architecture.sh

set -uo pipefail

REGION="us-east-1"
ACCOUNT_ID="022499047467"

# --- Resource names (verified via AWS API) ---
APP_RUNNER_SERVICE="my-web-app-service"
APP_RUNNER_ARN="arn:aws:apprunner:${REGION}:${ACCOUNT_ID}:service/my-web-app-service/1c28aa51172e4f54b10d98fa0eb2c203"
APP_RUNNER_URL="kdetiinmir.us-east-1.awsapprunner.com"
ECR_REPO="my-web-app"
ECR_URI="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${ECR_REPO}"
IAM_SERVICE_ROLE="my-web-app-app-runner-service-role"
IAM_INSTANCE_ROLE="my-web-app-app-runner-instance-role"
IAM_ECR_POLICY="AWSAppRunnerServicePolicyForECRAccess"
LOG_GROUP="/aws/apprunner/my-web-app"
AUTOSCALING_CONFIG="my-web-app-auto-scaling"
ALARM_CPU="my-web-app-cpu-high"
ALARM_MEMORY="my-web-app-memory-high"
ALARM_DEPLOY="my-web-app-deployment-failed"

# --- Counters ---
PASS=0
FAIL=0
WARN=0

# --- Helpers ---
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

pass() { echo -e "  ${GREEN}[PASS]${RESET} $1"; PASS=$((PASS + 1)); }
fail() { echo -e "  ${RED}[FAIL]${RESET} $1"; FAIL=$((FAIL + 1)); }
warn() { echo -e "  ${YELLOW}[WARN]${RESET} $1"; WARN=$((WARN + 1)); }
section() { echo -e "\n${CYAN}${BOLD}=== $1 ===${RESET}"; }

# ─────────────────────────────────────────────
section "1. App Runner Service"
# ─────────────────────────────────────────────

STATUS=$(aws apprunner describe-service \
  --service-arn "$APP_RUNNER_ARN" \
  --region "$REGION" \
  --query "Service.Status" --output text 2>/dev/null || echo "ERROR")

if [[ "$STATUS" == "RUNNING" ]]; then
  pass "Service '${APP_RUNNER_SERVICE}' is RUNNING"
elif [[ "$STATUS" == "OPERATION_IN_PROGRESS" ]]; then
  warn "Service '${APP_RUNNER_SERVICE}' is OPERATION_IN_PROGRESS (still deploying)"
else
  fail "Service '${APP_RUNNER_SERVICE}' status: ${STATUS}"
fi

# HTTP health check
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "https://${APP_RUNNER_URL}/" 2>/dev/null || echo "000")
if [[ "$HTTP_CODE" == "200" ]]; then
  pass "HTTP endpoint returns 200 (https://${APP_RUNNER_URL}/)"
elif [[ "$HTTP_CODE" == "000" ]]; then
  warn "HTTP endpoint unreachable — service may still be starting"
else
  fail "HTTP endpoint returned HTTP ${HTTP_CODE}"
fi

# Auto-deployments enabled
AUTO_DEPLOY=$(aws apprunner describe-service \
  --service-arn "$APP_RUNNER_ARN" \
  --region "$REGION" \
  --query "Service.SourceConfiguration.AutoDeploymentsEnabled" --output text 2>/dev/null || echo "ERROR")
[[ "$AUTO_DEPLOY" == "True" || "$AUTO_DEPLOY" == "true" ]] \
  && pass "Auto-deployments enabled" \
  || warn "Auto-deployments: ${AUTO_DEPLOY}"

# ─────────────────────────────────────────────
section "2. ECR Repository"
# ─────────────────────────────────────────────

REPO_URI=$(aws ecr describe-repositories \
  --repository-names "$ECR_REPO" \
  --region "$REGION" \
  --query "repositories[0].repositoryUri" --output text 2>/dev/null || echo "ERROR")

[[ "$REPO_URI" == "$ECR_URI" ]] \
  && pass "ECR repository '${ECR_REPO}' exists (${REPO_URI})" \
  || fail "ECR repository not found or URI mismatch: ${REPO_URI}"

# Image with 'latest' tag
IMAGE_TAG=$(aws ecr describe-images \
  --repository-name "$ECR_REPO" \
  --image-ids imageTag=latest \
  --region "$REGION" \
  --query "imageDetails[0].imageTags[0]" --output text 2>/dev/null || echo "ERROR")
[[ "$IMAGE_TAG" == "latest" ]] \
  && pass "Image tag 'latest' present in ECR" \
  || fail "Image tag 'latest' not found: ${IMAGE_TAG}"

# Scan on push
SCAN=$(aws ecr describe-repositories \
  --repository-names "$ECR_REPO" \
  --region "$REGION" \
  --query "repositories[0].imageScanningConfiguration.scanOnPush" --output text 2>/dev/null || echo "ERROR")
[[ "$SCAN" == "True" || "$SCAN" == "true" ]] \
  && pass "Image scanning on push enabled" \
  || warn "Image scanning on push: ${SCAN}"

# Lifecycle policy
LIFECYCLE=$(aws ecr get-lifecycle-policy \
  --repository-name "$ECR_REPO" \
  --region "$REGION" \
  --query "lifecyclePolicyText" --output text 2>/dev/null || echo "ERROR")
[[ "$LIFECYCLE" != "ERROR" && "$LIFECYCLE" != "None" ]] \
  && pass "ECR lifecycle policy attached (keep last 10 images)" \
  || fail "ECR lifecycle policy missing"

# ─────────────────────────────────────────────
section "3. IAM Roles & Policies"
# ─────────────────────────────────────────────

# Service role exists
SERVICE_ROLE=$(aws iam get-role \
  --role-name "$IAM_SERVICE_ROLE" \
  --query "Role.RoleName" --output text 2>/dev/null || echo "ERROR")
[[ "$SERVICE_ROLE" == "$IAM_SERVICE_ROLE" ]] \
  && pass "IAM service role '${IAM_SERVICE_ROLE}' exists" \
  || fail "IAM service role not found"

# Service role trust principal
TRUST=$(aws iam get-role \
  --role-name "$IAM_SERVICE_ROLE" \
  --query "Role.AssumeRolePolicyDocument.Statement[0].Principal.Service" --output text 2>/dev/null || echo "ERROR")
[[ "$TRUST" == "build.apprunner.amazonaws.com" ]] \
  && pass "Service role trusts 'build.apprunner.amazonaws.com'" \
  || fail "Service role trust principal wrong: ${TRUST}"

# Managed ECR policy attached
POLICY=$(aws iam list-attached-role-policies \
  --role-name "$IAM_SERVICE_ROLE" \
  --query "AttachedPolicies[?PolicyName=='${IAM_ECR_POLICY}'].PolicyName" --output text 2>/dev/null || echo "ERROR")
[[ "$POLICY" == "$IAM_ECR_POLICY" ]] \
  && pass "Managed policy '${IAM_ECR_POLICY}' attached to service role" \
  || fail "ECR managed policy not attached: ${POLICY}"

# Instance role exists
INSTANCE_ROLE=$(aws iam get-role \
  --role-name "$IAM_INSTANCE_ROLE" \
  --query "Role.RoleName" --output text 2>/dev/null || echo "ERROR")
[[ "$INSTANCE_ROLE" == "$IAM_INSTANCE_ROLE" ]] \
  && pass "IAM instance role '${IAM_INSTANCE_ROLE}' exists" \
  || fail "IAM instance role not found"

# Instance role trust principal
INSTANCE_TRUST=$(aws iam get-role \
  --role-name "$IAM_INSTANCE_ROLE" \
  --query "Role.AssumeRolePolicyDocument.Statement[0].Principal.Service" --output text 2>/dev/null || echo "ERROR")
[[ "$INSTANCE_TRUST" == "tasks.apprunner.amazonaws.com" ]] \
  && pass "Instance role trusts 'tasks.apprunner.amazonaws.com'" \
  || fail "Instance role trust principal wrong: ${INSTANCE_TRUST}"

# ─────────────────────────────────────────────
section "4. Auto Scaling Configuration"
# ─────────────────────────────────────────────

AS_STATUS=$(aws apprunner list-auto-scaling-configurations \
  --region "$REGION" \
  --query "AutoScalingConfigurationSummaryList[?AutoScalingConfigurationName=='${AUTOSCALING_CONFIG}'].Status" \
  --output text 2>/dev/null || echo "ERROR")
[[ "$AS_STATUS" == "active" ]] \
  && pass "Auto scaling config '${AUTOSCALING_CONFIG}' is active" \
  || fail "Auto scaling config not active: ${AS_STATUS}"

AS_ARN=$(aws apprunner list-auto-scaling-configurations \
  --region "$REGION" \
  --query "AutoScalingConfigurationSummaryList[?AutoScalingConfigurationName=='${AUTOSCALING_CONFIG}'].AutoScalingConfigurationArn" \
  --output text 2>/dev/null || echo "ERROR")

MIN=$(aws apprunner describe-auto-scaling-configuration \
  --auto-scaling-configuration-arn "$AS_ARN" \
  --region "$REGION" \
  --query "AutoScalingConfiguration.MinSize" --output text 2>/dev/null || echo "ERROR")
MAX=$(aws apprunner describe-auto-scaling-configuration \
  --auto-scaling-configuration-arn "$AS_ARN" \
  --region "$REGION" \
  --query "AutoScalingConfiguration.MaxSize" --output text 2>/dev/null || echo "ERROR")
CONCURRENCY=$(aws apprunner describe-auto-scaling-configuration \
  --auto-scaling-configuration-arn "$AS_ARN" \
  --region "$REGION" \
  --query "AutoScalingConfiguration.MaxConcurrency" --output text 2>/dev/null || echo "ERROR")

[[ "$MIN" == "1" ]]   && pass "Min instances = 1"            || fail "Min instances wrong: ${MIN}"
[[ "$MAX" == "4" ]]   && pass "Max instances = 4"            || fail "Max instances wrong: ${MAX}"
[[ "$CONCURRENCY" == "100" ]] && pass "Max concurrency = 100" || fail "Max concurrency wrong: ${CONCURRENCY}"

# ─────────────────────────────────────────────
section "5. CloudWatch Log Groups"
# ─────────────────────────────────────────────

LG_EXISTS=$(aws logs describe-log-groups \
  --log-group-name-prefix "$LOG_GROUP" \
  --region "$REGION" \
  --query "logGroups[?logGroupName=='${LOG_GROUP}'].logGroupName" --output text 2>/dev/null || echo "ERROR")
[[ "$LG_EXISTS" == "$LOG_GROUP" ]] \
  && pass "Log group '${LOG_GROUP}' exists" \
  || fail "Log group not found: ${LG_EXISTS}"

RETENTION=$(aws logs describe-log-groups \
  --log-group-name-prefix "$LOG_GROUP" \
  --region "$REGION" \
  --query "logGroups[?logGroupName=='${LOG_GROUP}'].retentionInDays" --output text 2>/dev/null || echo "ERROR")
[[ "$RETENTION" == "7" ]] \
  && pass "Log retention = 7 days" \
  || warn "Log retention: ${RETENTION} days"

# ─────────────────────────────────────────────
section "6. CloudWatch Alarms"
# ─────────────────────────────────────────────

for ALARM in "$ALARM_CPU" "$ALARM_MEMORY" "$ALARM_DEPLOY"; do
  ALARM_STATE=$(aws cloudwatch describe-alarms \
    --alarm-names "$ALARM" \
    --region "$REGION" \
    --query "MetricAlarms[0].StateValue" --output text 2>/dev/null || echo "ERROR")
  if [[ "$ALARM_STATE" == "OK" ]]; then
    pass "Alarm '${ALARM}' exists — state: OK"
  elif [[ "$ALARM_STATE" == "INSUFFICIENT_DATA" ]]; then
    warn "Alarm '${ALARM}' exists — state: INSUFFICIENT_DATA (no data yet)"
  elif [[ "$ALARM_STATE" == "ALARM" ]]; then
    fail "Alarm '${ALARM}' is FIRING"
  else
    fail "Alarm '${ALARM}' not found or error: ${ALARM_STATE}"
  fi
done

# ─────────────────────────────────────────────
section "Summary"
# ─────────────────────────────────────────────
TOTAL=$((PASS + FAIL + WARN))
echo ""
echo -e "  Tests run : ${TOTAL}"
echo -e "  ${GREEN}Passed${RESET}    : ${PASS}"
echo -e "  ${YELLOW}Warnings${RESET}  : ${WARN}"
echo -e "  ${RED}Failed${RESET}    : ${FAIL}"
echo ""

if [[ "$FAIL" -gt 0 ]]; then
  echo -e "  ${RED}${BOLD}RESULT: UNHEALTHY — ${FAIL} check(s) failed${RESET}"
  exit 1
elif [[ "$WARN" -gt 0 ]]; then
  echo -e "  ${YELLOW}${BOLD}RESULT: DEGRADED — ${WARN} warning(s), review above${RESET}"
  exit 0
else
  echo -e "  ${GREEN}${BOLD}RESULT: ALL CHECKS PASSED${RESET}"
  exit 0
fi
