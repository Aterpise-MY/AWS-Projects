#!/bin/bash

################################################################################
# Scaling Report - Analyze Auto Scaling Activity
################################################################################

set -o pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log_success() { echo -e "${GREEN}✓${NC} $1"; }
log_info() { echo "ℹ $1"; }
log_warning() { echo -e "${YELLOW}⚠${NC} $1"; }

get_terraform_output() {
    cd "$PROJECT_DIR" || return 1
    terraform output -json 2>/dev/null | jq -r ".$1" 2>/dev/null
}

# Get current metrics
get_metrics() {
    echo -e "\n${BLUE}=== Current Metrics ===${NC}"

    ASG_NAME=$(get_terraform_output "asg_name")

    if [ -z "$ASG_NAME" ] || [ "$ASG_NAME" = "null" ]; then
        log_warning "ASG not found"
        return
    fi

    ASG_JSON=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG_NAME" 2>/dev/null)

    DESIRED=$(echo "$ASG_JSON" | jq '.AutoScalingGroups[0].DesiredCapacity')
    CURRENT=$(echo "$ASG_JSON" | jq '.AutoScalingGroups[0].Instances | length')
    MIN=$(echo "$ASG_JSON" | jq '.AutoScalingGroups[0].MinSize')
    MAX=$(echo "$ASG_JSON" | jq '.AutoScalingGroups[0].MaxSize')

    log_info "Desired: $DESIRED, Current: $CURRENT, Min: $MIN, Max: $MAX"

    # Get CPU utilization
    echo -e "\n${BLUE}=== CPU Metrics (Last 60 minutes) ===${NC}"

    CPU_JSON=$(aws cloudwatch get-metric-statistics \
        --namespace AWS/EC2 \
        --metric-name CPUUtilization \
        --dimensions Name=AutoScalingGroupName,Value="$ASG_NAME" \
        --start-time "$(date -u -d '60 minutes ago' '+%Y-%m-%dT%H:%M:%S')" \
        --end-time "$(date -u '+%Y-%m-%dT%H:%M:%S')" \
        --period 300 \
        --statistics Average,Maximum 2>/dev/null)

    if [ -z "$CPU_JSON" ] || [ "$(echo "$CPU_JSON" | jq '.Datapoints | length')" = "0" ]; then
        log_warning "No CPU metrics available"
        return
    fi

    AVG_CPU=$(echo "$CPU_JSON" | jq '[.Datapoints[].Average] | add / length' 2>/dev/null)
    MAX_CPU=$(echo "$CPU_JSON" | jq '[.Datapoints[].Maximum] | max' 2>/dev/null)
    MIN_CPU=$(echo "$CPU_JSON" | jq '[.Datapoints[].Maximum] | min' 2>/dev/null)

    log_info "Average CPU: ${AVG_CPU}%"
    log_info "Max CPU: ${MAX_CPU}%"
    log_info "Min CPU: ${MIN_CPU}%"

    # Get target group metrics
    echo -e "\n${BLUE}=== Target Group Metrics ===${NC}"

    TG_ARN=$(get_terraform_output "target_group_arn")

    if [ -n "$TG_ARN" ] && [ "$TG_ARN" != "null" ]; then
        # Extract load balancer name from ARN
        TG_NAME=$(echo "$TG_ARN" | awk -F':' '{print $6}' | sed 's/targetgroup\///')

        # Get request count
        REQ_JSON=$(aws cloudwatch get-metric-statistics \
            --namespace AWS/ApplicationELB \
            --metric-name RequestCount \
            --dimensions Name=TargetGroup,Value="$TG_NAME" Name=LoadBalancer,Value="app/*" \
            --start-time "$(date -u -d '60 minutes ago' '+%Y-%m-%dT%H:%M:%S')" \
            --end-time "$(date -u '+%Y-%m-%dT%H:%M:%S')" \
            --period 300 \
            --statistics Sum 2>/dev/null)

        if [ -n "$REQ_JSON" ] && [ "$(echo "$REQ_JSON" | jq '.Datapoints | length')" != "0" ]; then
            TOTAL_REQUESTS=$(echo "$REQ_JSON" | jq '[.Datapoints[].Sum] | add' 2>/dev/null)
            log_info "Total requests (60 min): $TOTAL_REQUESTS"
        else
            log_warning "No request metrics available"
        fi
    fi
}

# Get recent scaling activities
get_scaling_activities() {
    echo -e "\n${BLUE}=== Recent Scaling Activities ===${NC}"

    ASG_NAME=$(get_terraform_output "asg_name")

    if [ -z "$ASG_NAME" ] || [ "$ASG_NAME" = "null" ]; then
        return
    fi

    ACTIVITIES=$(aws autoscaling describe-scaling-activities \
        --auto-scaling-group-name "$ASG_NAME" \
        --max-records 20 2>/dev/null)

    COUNT=$(echo "$ACTIVITIES" | jq '.Activities | length')

    if [ "$COUNT" = "0" ]; then
        log_info "No scaling activities in the last 24 hours"
        return
    fi

    log_info "Recent activities (last 20):"

    echo "$ACTIVITIES" | jq -r '.Activities[] | "\(.StartTime): [\(.StatusCode)] \(.Description)"' | head -10 | while read -r activity; do
        echo "  $activity"
    done
}

# Get alarm history
get_alarm_history() {
    echo -e "\n${BLUE}=== Alarm History ===${NC}"

    PROJECT_NAME=$(get_terraform_output "asg_name" | sed 's/-asg//')

    ALARMS=$(aws cloudwatch describe-alarms --alarm-name-prefix "$PROJECT_NAME" 2>/dev/null)

    if [ "$(echo "$ALARMS" | jq '.MetricAlarms | length')" = "0" ]; then
        log_warning "No alarms found"
        return
    fi

    # Get alarm history
    FIRST_ALARM=$(echo "$ALARMS" | jq -r '.MetricAlarms[0].AlarmName')

    HISTORY=$(aws cloudwatch describe-alarm-history \
        --alarm-name "$FIRST_ALARM" \
        --max-records 10 \
        --start-date "$(date -u -d '7 days ago' '+%Y-%m-%dT%H:%M:%S')" 2>/dev/null)

    if [ "$(echo "$HISTORY" | jq '.AlarmHistoryItems | length')" = "0" ]; then
        log_info "No recent alarm history"
        return
    fi

    log_info "Recent alarm state changes:"

    echo "$HISTORY" | jq -r '.AlarmHistoryItems[] | "\(.Timestamp): [\(.HistoryItemType)] \(.HistorySummary)"' | head -5 | while read -r item; do
        echo "  $item"
    done
}

# Get scaling policies
get_scaling_policies() {
    echo -e "\n${BLUE}=== Scaling Policies ===${NC}"

    ASG_NAME=$(get_terraform_output "asg_name")

    if [ -z "$ASG_NAME" ] || [ "$ASG_NAME" = "null" ]; then
        return
    fi

    POLICIES=$(aws autoscaling describe-scaling-activities \
        --auto-scaling-group-name "$ASG_NAME" \
        --max-records 1 2>/dev/null)

    # Show current policy configuration
    POLICY_JSON=$(aws autoscaling describe-auto-scaling-groups \
        --auto-scaling-group-names "$ASG_NAME" 2>/dev/null)

    HEALTH_CHECK_TYPE=$(echo "$POLICY_JSON" | jq -r '.AutoScalingGroups[0].HealthCheckType')
    HEALTH_CHECK_GRACE=$(echo "$POLICY_JSON" | jq -r '.AutoScalingGroups[0].HealthCheckGracePeriod')
    TERMINATION_POLICY=$(echo "$POLICY_JSON" | jq -r '.AutoScalingGroups[0].TerminationPolicies[0]')

    log_info "Health Check Type: $HEALTH_CHECK_TYPE"
    log_info "Grace Period: ${HEALTH_CHECK_GRACE}s"
    log_info "Termination Policy: $TERMINATION_POLICY"

    # Get lifecycle hooks if any
    HOOKS=$(echo "$POLICY_JSON" | jq '.AutoScalingGroups[0].LifecycleHooks | length')
    if [ "$HOOKS" -gt 0 ]; then
        log_info "Lifecycle Hooks: $HOOKS"
    fi
}

# Recommendations
get_recommendations() {
    echo -e "\n${BLUE}=== Recommendations ===${NC}"

    ASG_JSON=$(aws autoscaling describe-auto-scaling-groups \
        --auto-scaling-group-names "$(get_terraform_output "asg_name")" 2>/dev/null)

    DESIRED=$(echo "$ASG_JSON" | jq '.AutoScalingGroups[0].DesiredCapacity')
    CURRENT=$(echo "$ASG_JSON" | jq '.AutoScalingGroups[0].Instances | length')
    IN_SERVICE=$(echo "$ASG_JSON" | jq '[.AutoScalingGroups[0].Instances[] | select(.LifecycleState == "InService")] | length')

    if [ "$IN_SERVICE" -lt "$DESIRED" ]; then
        log_warning "Not all desired instances are in service"
        echo "  → Check instance health and CloudWatch logs"
        echo "  → Verify security groups allow ALB health checks"
    fi

    if [ "$DESIRED" -eq "1" ]; then
        log_warning "Only 1 instance desired - no redundancy"
        echo "  → Consider increasing min/desired capacity for HA"
    fi

    # Check CPU
    CPU_JSON=$(aws cloudwatch get-metric-statistics \
        --namespace AWS/EC2 \
        --metric-name CPUUtilization \
        --dimensions Name=AutoScalingGroupName,Value="$(get_terraform_output "asg_name")" \
        --start-time "$(date -u -d '60 minutes ago' '+%Y-%m-%dT%H:%M:%S')" \
        --end-time "$(date -u '+%Y-%m-%dT%H:%M:%S')" \
        --period 300 \
        --statistics Average 2>/dev/null)

    if [ "$(echo "$CPU_JSON" | jq '.Datapoints | length')" != "0" ]; then
        AVG_CPU=$(echo "$CPU_JSON" | jq '[.Datapoints[].Average] | add / length' 2>/dev/null)

        if (( $(echo "$AVG_CPU > 75" | bc -l) )); then
            log_warning "CPU utilization is very high ($AVG_CPU%)"
            echo "  → Consider reducing scale-out threshold or increasing instance type"
        elif (( $(echo "$AVG_CPU < 10" | bc -l) )); then
            log_info "CPU utilization is low ($AVG_CPU%) - Cost optimization opportunity"
            echo "  → Consider using Reserved Instances"
        fi
    fi
}

# Main
main() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}Auto Scaling Report${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo -e "Time: $(date)\n"

    if ! aws sts get-caller-identity &>/dev/null; then
        log_warning "AWS credentials invalid"
        exit 1
    fi

    get_metrics
    get_scaling_activities
    get_alarm_history
    get_scaling_policies
    get_recommendations

    echo -e "\n${BLUE}========================================${NC}"
    echo -e "${BLUE}Scaling Report Complete${NC}"
    echo -e "${BLUE}========================================${NC}\n"
}

main
