#!/bin/bash

################################################################################
# Quick Status Check - Fast Health Overview
# Purpose: Get a quick status without full diagnostics
################################################################################

set -o pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Hard-coded resource IDs (verified via AWS API MCP)
ALB_DNS="multitier-webapp-alb-586845017.us-east-1.elb.amazonaws.com"
ALB_ARN="arn:aws:elasticloadbalancing:us-east-1:022499047467:loadbalancer/app/multitier-webapp-alb/c79e421ca2439822"
TG_ARN="arn:aws:elasticloadbalancing:us-east-1:022499047467:targetgroup/app-20260609083540939900000002/fbe5b05c969bbad6"
ASG_NAME="multitier-webapp-asg-20260609085459110200000003"
RDS_ID="multitier-webapp-mysql"
BASTION_ID="i-0e2318d36aa053bfc"

# Helper functions
log_success() { echo -e "${GREEN}✓${NC} $1"; }
log_failure() { echo -e "${RED}✗${NC} $1"; }
log_warning() { echo -e "${YELLOW}⚠${NC} $1"; }
log_info() { echo "ℹ $1"; }

get_terraform_output() {
    cd "$PROJECT_DIR" || return 1
    terraform output -json 2>/dev/null | jq -r ".$1" 2>/dev/null
}

# Check ALB
check_alb() {
    echo -e "\n${BLUE}=== Application Load Balancer ===${NC}"

    if [ -z "$ALB_DNS" ] || [ "$ALB_DNS" = "null" ]; then
        log_failure "ALB not found"
        return
    fi

    STATE=$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" --query 'LoadBalancers[0].State.Code' --output text --region us-east-1 2>/dev/null)
    log_info "State: $STATE"
    log_info "DNS: $ALB_DNS"

    HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://$ALB_DNS" --connect-timeout 5 2>/dev/null)
    if [ "$HTTP_STATUS" = "200" ]; then
        log_success "HTTP $HTTP_STATUS - Active"
    elif [ "$HTTP_STATUS" = "502" ] || [ "$HTTP_STATUS" = "503" ]; then
        log_warning "HTTP $HTTP_STATUS - No healthy targets (ASG not deployed)"
    else
        log_warning "HTTP $HTTP_STATUS"
    fi
}

# Check ASG
check_asg() {
    echo -e "\n${BLUE}=== Auto Scaling Group ===${NC}"

    log_info "ASG Name: $ASG_NAME"

    ASG_JSON=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG_NAME" --region us-east-1 2>/dev/null)
    ASG_COUNT=$(echo "$ASG_JSON" | jq '.AutoScalingGroups | length')

    if [ "$ASG_COUNT" = "0" ]; then
        log_failure "❌ ASG NOT DEPLOYED"
        log_warning "Auto Scaling Group does not exist"
        return
    fi

    DESIRED=$(echo "$ASG_JSON" | jq '.AutoScalingGroups[0].DesiredCapacity')
    MIN=$(echo "$ASG_JSON" | jq '.AutoScalingGroups[0].MinSize')
    MAX=$(echo "$ASG_JSON" | jq '.AutoScalingGroups[0].MaxSize')
    IN_SERVICE=$(echo "$ASG_JSON" | jq '[.AutoScalingGroups[0].Instances[] | select(.LifecycleState == "InService")] | length')
    PENDING=$(echo "$ASG_JSON" | jq '[.AutoScalingGroups[0].Instances[] | select(.LifecycleState == "Pending")] | length')

    log_info "Capacity: Min=$MIN, Desired=$DESIRED, Max=$MAX"
    log_info "Instances: In Service=$IN_SERVICE, Pending=$PENDING"

    if [ "$IN_SERVICE" -ge "$DESIRED" ]; then
        log_success "All desired instances in service"
    else
        log_warning "$IN_SERVICE/$DESIRED instances in service"
    fi
}

# Check Targets
check_targets() {
    echo -e "\n${BLUE}=== Target Group Health ===${NC}"

    HEALTH_JSON=$(aws elbv2 describe-target-health --target-group-arn "$TG_ARN" --region us-east-1 2>/dev/null)

    HEALTHY=$(echo "$HEALTH_JSON" | jq '[.TargetHealthDescriptions[] | select(.TargetHealth.State == "healthy")] | length')
    UNHEALTHY=$(echo "$HEALTH_JSON" | jq '[.TargetHealthDescriptions[] | select(.TargetHealth.State == "unhealthy")] | length')
    INITIAL=$(echo "$HEALTH_JSON" | jq '[.TargetHealthDescriptions[] | select(.TargetHealth.State == "initial")] | length')
    TOTAL=$((HEALTHY + UNHEALTHY + INITIAL))

    log_info "Total Targets: $TOTAL"
    log_info "Healthy: $HEALTHY, Unhealthy: $UNHEALTHY, Initial: $INITIAL"

    if [ "$TOTAL" = "0" ]; then
        log_failure "No targets registered (ASG not deployed)"
    elif [ "$HEALTHY" -gt 0 ]; then
        log_success "At least one healthy target"
    elif [ "$INITIAL" -gt 0 ]; then
        log_warning "Instances initializing..."
    else
        log_failure "No healthy targets"
    fi
}

# Check RDS
check_rds() {
    echo -e "\n${BLUE}=== RDS Database ===${NC}"

    RDS_JSON=$(aws rds describe-db-instances --db-instance-identifier "$RDS_ID" --region us-east-1 2>/dev/null)

    if [ -z "$RDS_JSON" ]; then
        log_failure "RDS not found"
        return
    fi

    STATUS=$(echo "$RDS_JSON" | jq -r '.DBInstances[0].DBInstanceStatus')
    MULTI_AZ=$(echo "$RDS_JSON" | jq -r '.DBInstances[0].MultiAZ')
    ENGINE=$(echo "$RDS_JSON" | jq -r '.DBInstances[0].Engine')

    log_info "Status: $STATUS, Multi-AZ: $MULTI_AZ, Engine: $ENGINE"

    if [ "$STATUS" = "available" ]; then
        log_success "Database available"
    elif [ "$STATUS" = "modifying" ]; then
        log_warning "Database modifying (Multi-AZ being enabled)"
    else
        log_failure "Database status: $STATUS"
    fi
}

# Check Instances
check_instances() {
    echo -e "\n${BLUE}=== EC2 Instances ===${NC}"

    # Check Bastion
    BASTION_STATE=$(aws ec2 describe-instances --instance-ids "$BASTION_ID" --query 'Reservations[0].Instances[0].State.Name' --output text --region us-east-1 2>/dev/null)

    if [ "$BASTION_STATE" = "running" ]; then
        log_success "Bastion host running"
    else
        log_failure "Bastion host not running"
    fi

    # Check Web Tier
    ASG_JSON=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG_NAME" --region us-east-1 2>/dev/null)
    ASG_COUNT=$(echo "$ASG_JSON" | jq '.AutoScalingGroups | length')

    if [ "$ASG_COUNT" = "0" ]; then
        log_failure "Web tier instances not deployed (ASG missing)"
        return
    fi

    INSTANCES=$(echo "$ASG_JSON" | jq -r '.AutoScalingGroups[0].Instances[*].InstanceId' | grep -v '^$')

    RUNNING=0
    STOPPED=0

    for ID in $INSTANCES; do
        STATE=$(aws ec2 describe-instances --instance-ids "$ID" --query 'Reservations[0].Instances[0].State.Name' --output text --region us-east-1 2>/dev/null)
        if [ "$STATE" = "running" ]; then
            ((RUNNING++))
        else
            ((STOPPED++))
        fi
    done

    if [ -z "$INSTANCES" ]; then
        log_warning "No web tier instances running"
        return
    fi

    log_info "Running: $RUNNING, Stopped: $STOPPED"

    if [ "$STOPPED" -eq 0 ] && [ "$RUNNING" -gt 0 ]; then
        log_success "All web tier instances running"
    else
        log_warning "$RUNNING running, $STOPPED not running"
    fi
}

# Main
main() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}Quick Status Check${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo -e "Time: $(date)"
    echo -e ""

    # Verify AWS credentials
    if ! aws sts get-caller-identity &>/dev/null; then
        log_failure "AWS credentials invalid"
        exit 1
    fi

    check_alb
    check_asg
    check_targets
    check_instances
    check_rds

    echo -e "\n${BLUE}========================================${NC}"
    echo -e "${BLUE}Status Check Complete${NC}"
    echo -e "${BLUE}========================================${NC}\n"
}

main
