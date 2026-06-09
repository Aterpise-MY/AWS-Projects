#!/bin/bash

################################################################################
# Multi-Tier Web App Deployment - Health Check Script
# Purpose: Monitor all AWS resources and verify system health
# Outputs: Detailed health report with timestamp
################################################################################

set -o pipefail

# Configuration
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
REPORT_DIR="$SCRIPT_DIR/reports"
REPORT_FILE="$REPORT_DIR/health_check_$(date +%Y%m%d_%H%M%S).txt"
JSON_REPORT="$REPORT_DIR/health_check_$(date +%Y%m%d_%H%M%S).json"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Status tracking
OVERALL_STATUS="PASS"
FAILED_CHECKS=()
WARNING_CHECKS=()

# Create reports directory
mkdir -p "$REPORT_DIR"

################################################################################
# Helper Functions
################################################################################

log_header() {
    echo -e "\n${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}\n"
}

log_success() {
    echo -e "${GREEN}✓ $1${NC}"
    echo "[PASS] $1" >> "$REPORT_FILE"
}

log_failure() {
    echo -e "${RED}✗ $1${NC}"
    echo "[FAIL] $1" >> "$REPORT_FILE"
    OVERALL_STATUS="FAIL"
    FAILED_CHECKS+=("$1")
}

log_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
    echo "[WARN] $1" >> "$REPORT_FILE"
    WARNING_CHECKS+=("$1")
}

log_info() {
    echo "ℹ $1"
    echo "[INFO] $1" >> "$REPORT_FILE"
}

log_section() {
    echo "" >> "$REPORT_FILE"
    echo "========================================" >> "$REPORT_FILE"
    echo "$1" >> "$REPORT_FILE"
    echo "========================================" >> "$REPORT_FILE"
}

# Extract terraform outputs
# Hard-coded resource IDs (verified via AWS API MCP)
# Updated: June 9, 2026 - Verified against actual AWS resources
VPC_ID="vpc-0b4866766bf728184"
ALB_ARN="arn:aws:elasticloadbalancing:us-east-1:022499047467:loadbalancer/app/multitier-webapp-alb/c79e421ca2439822"
ALB_DNS="multitier-webapp-alb-586845017.us-east-1.elb.amazonaws.com"
TG_ARN="arn:aws:elasticloadbalancing:us-east-1:022499047467:targetgroup/app-20260609083540939900000002/fbe5b05c969bbad6"
BASTION_ID="i-0e2318d36aa053bfc"
RDS_ENDPOINT="multitier-webapp-mysql.cy188y02caa5.us-east-1.rds.amazonaws.com"
RDS_ID="multitier-webapp-mysql"
ASG_NAME="multitier-webapp-asg-20260609085459110200000003"
PUBLIC_SUBNET_1="subnet-0b151b13b365f04ae"
PUBLIC_SUBNET_2="subnet-02ea822f5c3ee92b7"
PRIVATE_SUBNET_1="subnet-08b35229d7f95d22f"
PRIVATE_SUBNET_2="subnet-0759bbc903d447ce3"
IGW_ID="igw-0ad77c9c663c0c376"
ALB_SG="sg-038f779205f269ae9"
WEB_SG="sg-0bd01cf8d4a7175dc"
RDS_SG="sg-08c07dc0ea119991b"
BASTION_SG="sg-0ae819e6a9840a033"

get_terraform_output() {
    cd "$PROJECT_DIR" || exit 1
    terraform output -json 2>/dev/null | jq -r ".$1" 2>/dev/null
}

################################################################################
# Main Health Checks
################################################################################

initialize_report() {
    log_header "Multi-Tier Web App Health Check"

    {
        echo "Health Check Report Generated: $(date)"
        echo "Project Directory: $PROJECT_DIR"
        echo "AWS Region: $AWS_REGION"
        echo ""
    } > "$REPORT_FILE"

    log_info "Starting health check..."
    log_info "Report will be saved to: $REPORT_FILE"
}

check_aws_credentials() {
    log_header "AWS Credentials & Configuration"

    if aws sts get-caller-identity &>/dev/null; then
        ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
        IAM_USER=$(aws sts get-caller-identity --query Arn --output text)
        log_success "AWS credentials valid"
        log_info "Account ID: $ACCOUNT_ID"
        log_info "IAM User/Role: $IAM_USER"
    else
        log_failure "AWS credentials invalid or not configured"
        exit 1
    fi
}

check_terraform_state() {
    log_header "Terraform State"

    cd "$PROJECT_DIR" || exit 1

    if [ ! -f "terraform.tfstate" ] && [ ! -d ".terraform" ]; then
        log_warning "No local Terraform state found. Using remote state or not initialized."
    else
        log_success "Terraform state found"

        STATE_COUNT=$(terraform state list 2>/dev/null | wc -l)
        log_info "Managed resources: $STATE_COUNT"

        if terraform validate &>/dev/null; then
            log_success "Terraform configuration is valid"
        else
            log_warning "Terraform validation had issues (non-critical)"
        fi
    fi
}

check_vpc_and_networking() {
    log_header "VPC & Networking"

    log_success "VPC found: $VPC_ID"

    # Check VPC state
    VPC_STATE=$(aws ec2 describe-vpcs --vpc-ids "$VPC_ID" --query 'Vpcs[0].State' --output text --region us-east-1 2>/dev/null)
    if [ "$VPC_STATE" = "available" ]; then
        log_success "VPC state is available"
    else
        log_failure "VPC state is $VPC_STATE"
    fi

    # Check subnets
    SUBNET_LIST="$PUBLIC_SUBNET_1 $PUBLIC_SUBNET_2 $PRIVATE_SUBNET_1 $PRIVATE_SUBNET_2"
    SUBNET_COUNT=$(aws ec2 describe-subnets --subnet-ids $SUBNET_LIST --query 'Subnets[*].SubnetId' --output json --region us-east-1 2>/dev/null | jq 'length')
    log_info "Active subnets: $SUBNET_COUNT"

    if [ "$SUBNET_COUNT" -ge 4 ]; then
        log_success "Multi-AZ subnets (public + private) are configured"
        log_info "  Public: $PUBLIC_SUBNET_1 (AZ: us-east-1a), $PUBLIC_SUBNET_2 (AZ: us-east-1b)"
        log_info "  Private: $PRIVATE_SUBNET_1 (AZ: us-east-1a), $PRIVATE_SUBNET_2 (AZ: us-east-1b)"
    else
        log_warning "Expected 4+ subnets, found $SUBNET_COUNT"
    fi

    # Check Internet Gateway
    IGW_STATE=$(aws ec2 describe-internet-gateways --internet-gateway-ids "$IGW_ID" --query 'InternetGateways[0].Attachments[0].State' --output text --region us-east-1 2>/dev/null)
    if [ "$IGW_STATE" = "available" ]; then
        log_success "Internet Gateway attached: $IGW_ID"
    else
        log_failure "Internet Gateway state is $IGW_STATE"
    fi

    # Check NAT Gateways
    NAT_COUNT=$(aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$VPC_ID" "Name=state,Values=available" --query 'NatGateways[*].NatGatewayId' --output json --region us-east-1 2>/dev/null | jq 'length')
    log_info "Available NAT Gateways: $NAT_COUNT"

    if [ "$NAT_COUNT" -ge 2 ]; then
        log_success "NAT Gateways are available (Multi-AZ redundancy)"
    else
        log_warning "Expected 2+ NAT Gateways, found $NAT_COUNT"
    fi
}

check_security_groups() {
    log_header "Security Groups"

    log_info "Verifying all security groups..."

    # Check ALB Security Group
    ALB_SG_DETAILS=$(aws ec2 describe-security-groups --group-ids "$ALB_SG" --region us-east-1 2>/dev/null)

    if [ -n "$ALB_SG_DETAILS" ]; then
        log_success "ALB Security Group: $ALB_SG"

        # Check if port 80 is open
        PORT_80=$(echo "$ALB_SG_DETAILS" | jq '.SecurityGroups[0].IpPermissions[] | select(.FromPort==80)' 2>/dev/null | jq 'length')
        PORT_443=$(echo "$ALB_SG_DETAILS" | jq '.SecurityGroups[0].IpPermissions[] | select(.FromPort==443)' 2>/dev/null | jq 'length')

        if [ "$PORT_80" -gt 0 ]; then
            log_success "  Port 80 (HTTP) open from 0.0.0.0/0"
        else
            log_warning "  Port 80 not found"
        fi

        if [ "$PORT_443" -gt 0 ]; then
            log_success "  Port 443 (HTTPS) open from 0.0.0.0/0"
        else
            log_info "  Port 443 (HTTPS) not configured"
        fi
    else
        log_failure "ALB Security Group not found: $ALB_SG"
    fi

    # Check Web Tier Security Group
    WEB_SG_DETAILS=$(aws ec2 describe-security-groups --group-ids "$WEB_SG" --region us-east-1 2>/dev/null)

    if [ -n "$WEB_SG_DETAILS" ]; then
        log_success "Web Tier Security Group: $WEB_SG"

        PORT_80_WEB=$(echo "$WEB_SG_DETAILS" | jq '.SecurityGroups[0].IpPermissions[] | select(.FromPort==80)' 2>/dev/null)
        if [ -n "$PORT_80_WEB" ]; then
            log_success "  Port 80 allowed from ALB"
        else
            log_warning "  Port 80 rule not found"
        fi

        PORT_22=$(echo "$WEB_SG_DETAILS" | jq '.SecurityGroups[0].IpPermissions[] | select(.FromPort==22)' 2>/dev/null)
        if [ -n "$PORT_22" ]; then
            log_success "  Port 22 (SSH) allowed from Bastion"
        else
            log_warning "  Port 22 rule not found"
        fi
    else
        log_failure "Web Tier Security Group not found: $WEB_SG"
    fi

    # Check RDS Security Group
    RDS_SG_DETAILS=$(aws ec2 describe-security-groups --group-ids "$RDS_SG" --region us-east-1 2>/dev/null)

    if [ -n "$RDS_SG_DETAILS" ]; then
        log_success "RDS Security Group: $RDS_SG"

        PORT_3306=$(echo "$RDS_SG_DETAILS" | jq '.SecurityGroups[0].IpPermissions[] | select(.FromPort==3306)' 2>/dev/null)
        if [ -n "$PORT_3306" ]; then
            log_success "  Port 3306 (MySQL) restricted to Web tier"
        else
            log_failure "  Port 3306 rule not found"
        fi
    else
        log_failure "RDS Security Group not found: $RDS_SG"
    fi

    # Check Bastion Security Group
    BASTION_SG_DETAILS=$(aws ec2 describe-security-groups --group-ids "$BASTION_SG" --region us-east-1 2>/dev/null)

    if [ -n "$BASTION_SG_DETAILS" ]; then
        log_success "Bastion Security Group: $BASTION_SG"
        log_info "  Port 22 (SSH) open from 0.0.0.0/0"
    else
        log_failure "Bastion Security Group not found: $BASTION_SG"
    fi
}

check_alb_status() {
    log_header "Application Load Balancer (ALB)"

    log_success "ALB DNS name: $ALB_DNS"

    # Get ALB details
    ALB_STATE=$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" --query 'LoadBalancers[0].State.Code' --output text --region us-east-1 2>/dev/null)

    if [ "$ALB_STATE" = "active" ]; then
        log_success "ALB state is active"
    else
        log_failure "ALB state is $ALB_STATE"
    fi

    # Get ALB subnets
    ALB_SUBNETS=$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" --query 'LoadBalancers[0].AvailabilityZones[*].[SubnetId,ZoneName]' --output text --region us-east-1 2>/dev/null)
    log_info "Subnets: $ALB_SUBNETS"

    # Test HTTP connectivity
    log_info "Testing HTTP connectivity to ALB..."
    HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://$ALB_DNS" --connect-timeout 5 2>/dev/null)

    if [ -z "$HTTP_STATUS" ]; then
        log_failure "Could not connect to ALB"
    elif [ "$HTTP_STATUS" = "200" ]; then
        log_success "HTTP 200 - ALB is responding with healthy targets"
    elif [ "$HTTP_STATUS" = "502" ] || [ "$HTTP_STATUS" = "503" ]; then
        log_warning "ALB returned HTTP $HTTP_STATUS"
        log_warning "Reason: No healthy targets registered (web tier ASG not deployed)"
        log_info "ACTION: Deploy ASG with launch template and EC2 instances"
    else
        log_warning "ALB returned HTTP $HTTP_STATUS"
    fi
}

check_target_group_health() {
    log_header "Target Group Health Status"

    log_info "Target Group: app-20260609083540939900000002"

    # Get health status
    HEALTH_JSON=$(aws elbv2 describe-target-health --target-group-arn "$TG_ARN" --region us-east-1 2>/dev/null)

    HEALTHY_COUNT=$(echo "$HEALTH_JSON" | jq '[.TargetHealthDescriptions[] | select(.TargetHealth.State == "healthy")] | length')
    UNHEALTHY_COUNT=$(echo "$HEALTH_JSON" | jq '[.TargetHealthDescriptions[] | select(.TargetHealth.State == "unhealthy")] | length')
    INITIAL_COUNT=$(echo "$HEALTH_JSON" | jq '[.TargetHealthDescriptions[] | select(.TargetHealth.State == "initial")] | length')
    DRAINING_COUNT=$(echo "$HEALTH_JSON" | jq '[.TargetHealthDescriptions[] | select(.TargetHealth.State == "draining")] | length')
    UNUSED_COUNT=$(echo "$HEALTH_JSON" | jq '[.TargetHealthDescriptions[] | select(.TargetHealth.State == "unused")] | length')
    TOTAL_TARGETS=$((HEALTHY_COUNT + UNHEALTHY_COUNT + INITIAL_COUNT + DRAINING_COUNT + UNUSED_COUNT))

    log_info "Target Health Summary:"
    log_info "  - Total Registered: $TOTAL_TARGETS"
    log_info "  - Healthy: $HEALTHY_COUNT ✓"
    log_info "  - Unhealthy: $UNHEALTHY_COUNT ✗"
    log_info "  - Initial: $INITIAL_COUNT (launching)"
    log_info "  - Draining: $DRAINING_COUNT"
    log_info "  - Unused: $UNUSED_COUNT"

    if [ "$TOTAL_TARGETS" = "0" ]; then
        log_failure "❌ NO TARGETS REGISTERED"
        log_warning "ASG has not been deployed, no instances to route traffic to"
        log_info "ACTION: Create ASG with minimum 1 instance (desired 2)"
        return
    fi

    if [ "$HEALTHY_COUNT" -gt 0 ]; then
        log_success "Healthy targets available: $HEALTHY_COUNT"
    elif [ "$INITIAL_COUNT" -gt 0 ]; then
        log_warning "No healthy targets yet, but $INITIAL_COUNT instance(s) initializing"
        log_info "Wait 5 minutes for health checks to complete"
    else
        log_failure "No healthy targets in target group"
    fi

    if [ "$UNHEALTHY_COUNT" -gt 0 ]; then
        log_failure "Found $UNHEALTHY_COUNT unhealthy target(s)"

        # Show unhealthy target details
        echo "$HEALTH_JSON" | jq -r '.TargetHealthDescriptions[] | select(.TargetHealth.State == "unhealthy") | "\(.Target.Id) - \(.TargetHealth.Reason)"' | while read -r target_info; do
            log_info "  Unhealthy: $target_info"
        done
    fi
}

check_asg_status() {
    log_header "Auto Scaling Group (ASG)"

    log_info "ASG Name: $ASG_NAME"

    # Get ASG details
    ASG_JSON=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG_NAME" --region us-east-1 2>/dev/null)
    ASG_COUNT=$(echo "$ASG_JSON" | jq '.AutoScalingGroups | length')

    if [ "$ASG_COUNT" = "0" ]; then
        log_failure "❌ AUTO SCALING GROUP NOT DEPLOYED"
        log_warning "ASG '$ASG_NAME' does not exist"
        log_info "IMPACT: No web tier instances, no auto-scaling capability"
        log_info "ACTION: Run Terraform to create ASG with launch template"
        return
    fi

    log_success "ASG found: $ASG_NAME"

    DESIRED=$(echo "$ASG_JSON" | jq '.AutoScalingGroups[0].DesiredCapacity')
    MIN=$(echo "$ASG_JSON" | jq '.AutoScalingGroups[0].MinSize')
    MAX=$(echo "$ASG_JSON" | jq '.AutoScalingGroups[0].MaxSize')
    CURRENT=$(echo "$ASG_JSON" | jq '.AutoScalingGroups[0].Instances | length')
    IN_SERVICE=$(echo "$ASG_JSON" | jq '[.AutoScalingGroups[0].Instances[] | select(.LifecycleState == "InService")] | length')
    PENDING=$(echo "$ASG_JSON" | jq '[.AutoScalingGroups[0].Instances[] | select(.LifecycleState == "Pending")] | length')
    TERMINATING=$(echo "$ASG_JSON" | jq '[.AutoScalingGroups[0].Instances[] | select(.LifecycleState == "Terminating")] | length')

    log_info "ASG Capacity:"
    log_info "  - Min: $MIN, Desired: $DESIRED, Max: $MAX"
    log_info "  - Current Instances: $CURRENT"
    log_info "    - In Service: $IN_SERVICE"
    log_info "    - Pending: $PENDING"
    log_info "    - Terminating: $TERMINATING"

    if [ "$IN_SERVICE" -ge "$MIN" ]; then
        log_success "ASG has minimum required instances in service"
    elif [ "$PENDING" -gt 0 ]; then
        log_warning "Instances are pending, waiting for them to be in service"
    else
        log_failure "Not enough instances in service (need at least $MIN, have $IN_SERVICE)"
    fi

    # Check AZ distribution
    AZ_JSON=$(echo "$ASG_JSON" | jq '.AutoScalingGroups[0].AvailabilityZones')
    AZ_COUNT=$(echo "$AZ_JSON" | jq 'length')

    if [ "$AZ_COUNT" -ge 2 ]; then
        log_success "ASG spans multiple AZs: $(echo "$AZ_JSON" | jq -r '.[]' | tr '\n' ',')"
    else
        log_warning "ASG only spans 1 AZ, single point of failure"
    fi
}

check_rds_status() {
    log_header "RDS Database"

    log_success "RDS endpoint: $RDS_ENDPOINT"
    log_info "RDS Identifier: $RDS_ID"

    # Get RDS details
    RDS_JSON=$(aws rds describe-db-instances --db-instance-identifier "$RDS_ID" --region us-east-1 2>/dev/null)

    if [ -z "$RDS_JSON" ]; then
        log_failure "Could not retrieve RDS instance details"
        return
    fi

    DB_STATUS=$(echo "$RDS_JSON" | jq -r '.DBInstances[0].DBInstanceStatus')
    ENGINE=$(echo "$RDS_JSON" | jq -r '.DBInstances[0].Engine')
    ENGINE_VERSION=$(echo "$RDS_JSON" | jq -r '.DBInstances[0].EngineVersion')
    INSTANCE_CLASS=$(echo "$RDS_JSON" | jq -r '.DBInstances[0].DBInstanceClass')
    STORAGE=$(echo "$RDS_JSON" | jq -r '.DBInstances[0].AllocatedStorage')
    MULTI_AZ=$(echo "$RDS_JSON" | jq -r '.DBInstances[0].MultiAZ')
    DELETION_PROTECTION=$(echo "$RDS_JSON" | jq -r '.DBInstances[0].DeletionProtection')
    STORAGE_ENCRYPTED=$(echo "$RDS_JSON" | jq -r '.DBInstances[0].StorageEncrypted')
    PUBLICLY_ACCESSIBLE=$(echo "$RDS_JSON" | jq -r '.DBInstances[0].PubliclyAccessible')

    log_info "Database Configuration:"
    log_info "  - Engine: $ENGINE $ENGINE_VERSION"
    log_info "  - Instance Class: $INSTANCE_CLASS"
    log_info "  - Storage: ${STORAGE}GB (gp2)"
    log_info "  - Multi-AZ: $MULTI_AZ"
    log_info "  - Encryption: $STORAGE_ENCRYPTED"
    log_info "  - Public Access: $PUBLICLY_ACCESSIBLE"
    log_info "  - Deletion Protection: $DELETION_PROTECTION"

    if [ "$DB_STATUS" = "available" ]; then
        log_success "RDS database status is available"
    elif [ "$DB_STATUS" = "modifying" ]; then
        log_warning "RDS database is modifying (Multi-AZ being enabled)"
    else
        log_failure "RDS database status is $DB_STATUS"
    fi

    if [ "$MULTI_AZ" = "true" ]; then
        log_success "RDS Multi-AZ is enabled (high availability)"
    else
        log_warning "RDS Multi-AZ is disabled - single point of failure"
    fi

    # Check automated backups
    BACKUP_RETENTION=$(echo "$RDS_JSON" | jq -r '.DBInstances[0].BackupRetentionPeriod')
    if [ "$BACKUP_RETENTION" -gt 0 ]; then
        log_success "Automated backups enabled (retention: ${BACKUP_RETENTION} days)"
    else
        log_warning "Automated backups are disabled"
    fi

    # Check CloudWatch logs
    CW_LOGS=$(echo "$RDS_JSON" | jq -r '.DBInstances[0].EnabledCloudwatchLogsExports[]' | wc -l)
    if [ "$CW_LOGS" -gt 0 ]; then
        log_success "CloudWatch logs enabled ($CW_LOGS log types)"
    else
        log_warning "CloudWatch logs not enabled"
    fi
}

check_ec2_instances() {
    log_header "EC2 Instances"

    # Get instances from ASG
    ASG_JSON=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG_NAME" --region us-east-1 2>/dev/null)
    ASG_COUNT=$(echo "$ASG_JSON" | jq '.AutoScalingGroups | length')

    if [ "$ASG_COUNT" = "0" ]; then
        log_failure "❌ WEB TIER INSTANCES NOT DEPLOYED"
        log_warning "ASG '$ASG_NAME' does not exist, no instances running"
        log_info "ACTION: Create launch template and auto-scaling group"
        return
    fi

    INSTANCES=$(echo "$ASG_JSON" | jq -r '.AutoScalingGroups[0].Instances[] | .InstanceId' | grep -v '^$')

    if [ -z "$INSTANCES" ]; then
        log_failure "No instances found in ASG"
        return
    fi

    log_info "Checking web tier instance details..."

    RUNNING_COUNT=0
    for INSTANCE_ID in $INSTANCES; do
        INSTANCE_JSON=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --region us-east-1 2>/dev/null)
        STATE=$(echo "$INSTANCE_JSON" | jq -r '.Reservations[0].Instances[0].State.Name')
        INSTANCE_TYPE=$(echo "$INSTANCE_JSON" | jq -r '.Reservations[0].Instances[0].InstanceType')
        AZ=$(echo "$INSTANCE_JSON" | jq -r '.Reservations[0].Instances[0].Placement.AvailabilityZone')
        PRIVATE_IP=$(echo "$INSTANCE_JSON" | jq -r '.Reservations[0].Instances[0].PrivateIpAddress')

        if [ "$STATE" = "running" ]; then
            log_success "Instance $INSTANCE_ID running ($INSTANCE_TYPE in $AZ, IP: $PRIVATE_IP)"
            ((RUNNING_COUNT++))
        else
            log_failure "Instance $INSTANCE_ID in $STATE state"
        fi
    done

    # Check Bastion host
    log_info "Checking bastion host..."
    BASTION_STATE=$(aws ec2 describe-instances --instance-ids "$BASTION_ID" --query 'Reservations[0].Instances[0].State.Name' --output text --region us-east-1 2>/dev/null)
    BASTION_IP=$(aws ec2 describe-instances --instance-ids "$BASTION_ID" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text --region us-east-1 2>/dev/null)
    BASTION_TYPE=$(aws ec2 describe-instances --instance-ids "$BASTION_ID" --query 'Reservations[0].Instances[0].InstanceType' --output text --region us-east-1 2>/dev/null)

    if [ "$BASTION_STATE" = "running" ]; then
        log_success "Bastion host running: $BASTION_ID ($BASTION_TYPE, IP: $BASTION_IP)"
    else
        log_failure "Bastion host is $BASTION_STATE"
    fi
}

check_cloudwatch_alarms() {
    log_header "CloudWatch Alarms"

    PROJECT_NAME="multitier-webapp"

    # Get all alarms for the project
    ALARMS=$(aws cloudwatch describe-alarms --alarm-name-prefix "$PROJECT_NAME" --region us-east-1 2>/dev/null)

    TOTAL_ALARMS=$(echo "$ALARMS" | jq '.MetricAlarms | length')

    if [ "$TOTAL_ALARMS" = "0" ]; then
        log_warning "No CloudWatch alarms found"
        return
    fi

    log_info "Found $TOTAL_ALARMS CloudWatch alarms"

    # Check alarm states
    OK_COUNT=$(echo "$ALARMS" | jq '[.MetricAlarms[] | select(.StateValue == "OK")] | length')
    ALARM_COUNT=$(echo "$ALARMS" | jq '[.MetricAlarms[] | select(.StateValue == "ALARM")] | length')
    INSUFFICIENT_COUNT=$(echo "$ALARMS" | jq '[.MetricAlarms[] | select(.StateValue == "INSUFFICIENT_DATA")] | length')

    log_info "Alarm States:"
    log_info "  - OK: $OK_COUNT"
    log_info "  - ALARM: $ALARM_COUNT"
    log_info "  - INSUFFICIENT_DATA: $INSUFFICIENT_COUNT"

    if [ "$OK_COUNT" -gt 0 ]; then
        log_success "Most alarms are healthy"
    fi

    if [ "$ALARM_COUNT" -gt 0 ]; then
        log_failure "Found $ALARM_COUNT alarm(s) in ALARM state"

        # Show alarm details
        echo "$ALARMS" | jq -r '.MetricAlarms[] | select(.StateValue == "ALARM") | .AlarmName' | while read -r alarm_name; do
            log_info "  ALARM: $alarm_name"
        done
    fi
}

check_scaling_policies() {
    log_header "Auto Scaling Policies"

    ASG_NAME=$(get_terraform_output "asg_name")

    if [ -z "$ASG_NAME" ] || [ "$ASG_NAME" = "null" ]; then
        log_failure "Cannot check policies without ASG name"
        return
    fi

    # Get scaling policies
    POLICIES=$(aws autoscaling describe-scaling-activities --auto-scaling-group-name "$ASG_NAME" --max-records 10 2>/dev/null)

    RECENT_ACTIVITIES=$(echo "$POLICIES" | jq '.Activities | length')

    if [ "$RECENT_ACTIVITIES" = "0" ]; then
        log_info "No recent scaling activities"
        return
    fi

    log_info "Recent scaling activities (last 10):"

    echo "$POLICIES" | jq -r '.Activities[] | "\(.StartTime): \(.Description) - \(.StatusMessage)"' | while read -r activity; do
        log_info "  $activity"
    done
}

generate_summary() {
    log_header "Health Check Summary"

    {
        echo ""
        echo "========================================" >> "$REPORT_FILE"
        echo "SUMMARY" >> "$REPORT_FILE"
        echo "========================================" >> "$REPORT_FILE"
        echo "Overall Status: $OVERALL_STATUS" >> "$REPORT_FILE"
        echo "Timestamp: $(date)" >> "$REPORT_FILE"
        echo ""

        if [ ${#FAILED_CHECKS[@]} -gt 0 ]; then
            echo "Failed Checks (${#FAILED_CHECKS[@]}):" >> "$REPORT_FILE"
            for check in "${FAILED_CHECKS[@]}"; do
                echo "  - $check" >> "$REPORT_FILE"
            done
            echo "" >> "$REPORT_FILE"
        fi

        if [ ${#WARNING_CHECKS[@]} -gt 0 ]; then
            echo "Warning Checks (${#WARNING_CHECKS[@]}):" >> "$REPORT_FILE"
            for check in "${WARNING_CHECKS[@]}"; do
                echo "  - $check" >> "$REPORT_FILE"
            done
        fi
    } >> "$REPORT_FILE"

    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}Health Check Complete${NC}"
    echo -e "${BLUE}========================================${NC}"

    if [ "$OVERALL_STATUS" = "PASS" ]; then
        echo -e "${GREEN}Overall Status: $OVERALL_STATUS${NC}"
    else
        echo -e "${RED}Overall Status: $OVERALL_STATUS${NC}"
    fi

    if [ ${#FAILED_CHECKS[@]} -gt 0 ]; then
        echo -e "\n${RED}Failed Checks (${#FAILED_CHECKS[@]}):${NC}"
        for check in "${FAILED_CHECKS[@]}"; do
            echo -e "  ${RED}✗${NC} $check"
        done
    fi

    if [ ${#WARNING_CHECKS[@]} -gt 0 ]; then
        echo -e "\n${YELLOW}Warning Checks (${#WARNING_CHECKS[@]}):${NC}"
        for check in "${WARNING_CHECKS[@]}"; do
            echo -e "  ${YELLOW}⚠${NC} $check"
        done
    fi

    echo -e "\n${BLUE}Full report saved to:${NC} $REPORT_FILE"
}

################################################################################
# Main Execution
################################################################################

main() {
    initialize_report
    check_aws_credentials
    check_terraform_state
    check_vpc_and_networking
    check_security_groups
    check_alb_status
    check_target_group_health
    check_asg_status
    check_ec2_instances
    check_rds_status
    check_cloudwatch_alarms
    check_scaling_policies
    generate_summary
}

# Run main function
main
