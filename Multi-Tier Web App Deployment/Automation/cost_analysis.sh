#!/bin/bash

################################################################################
# Cost Analysis - Estimate AWS Monthly Costs
################################################################################

set -o pipefail

# Colors
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log_info() { echo "ℹ $1"; }

get_terraform_output() {
    cd "$PROJECT_DIR" || return 1
    terraform output -json 2>/dev/null | jq -r ".$1" 2>/dev/null
}

# Pricing data (us-east-1, may vary by region)
EC2_T3_MICRO=0.0104      # per hour
EC2_T3_MEDIUM=0.0416     # per hour
ALB_HOURLY=0.0225         # per hour
ALB_LCU=0.006             # per LCU-hour
NAT_GW_HOURLY=0.045       # per hour per gateway
NAT_GW_DATA=0.045         # per GB processed
RDS_T3_MEDIUM=0.192       # per hour (Multi-AZ)
RDS_STORAGE=0.12          # per GB-month
CLOUDWATCH_LOGS=0.50      # per GB ingested
EBS_GP2=0.12              # per GB-month

# Main calculation
main() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}AWS Cost Analysis${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo -e "Time: $(date)\n"

    # Get infrastructure details
    log_info "Retrieving infrastructure details..."

    ASG_NAME=$(get_terraform_output "asg_name")
    BASTION_ID=$(get_terraform_output "bastion_id")

    # Assumed values (can be customized)
    HOURS_PER_MONTH=730
    BASTION_HOURS=$HOURS_PER_MONTH
    WEB_INSTANCES=2.5  # Average (min=1, max=4, usually 2)
    WEB_HOURS=$HOURS_PER_MONTH
    NAT_GWS=2
    ALB_LCU_HOURS=100  # Estimated based on traffic
    CLOUDWATCH_GB_MONTH=10
    RDS_STORAGE_GB=20
    EBS_STORAGE_GB=100  # 8GB root per instance * 2.5 avg * 4 instances + overhead

    echo -e "${BLUE}=== Cost Breakdown (Monthly) ===${NC}\n"

    # EC2 Compute
    echo -e "${GREEN}EC2 Compute${NC}"
    BASTION_COST=$(echo "$BASTION_HOURS * $EC2_T3_MICRO" | bc)
    WEB_COST=$(echo "$WEB_HOURS * $WEB_INSTANCES * $EC2_T3_MEDIUM" | bc)
    echo "  Bastion (t3.micro, 1x): \$$BASTION_COST"
    echo "  Web Tier (t3.medium, 2.5 avg): \$$WEB_COST"
    EC2_TOTAL=$(echo "$BASTION_COST + $WEB_COST" | bc)
    echo "  EC2 Subtotal: \$$EC2_TOTAL"

    # ALB
    echo -e "\n${GREEN}Application Load Balancer${NC}"
    ALB_HOURLY_COST=$(echo "$HOURS_PER_MONTH * $ALB_HOURLY" | bc)
    ALB_LCU_COST=$(echo "$ALB_LCU_HOURS * $ALB_LCU" | bc)
    ALB_TOTAL=$(echo "$ALB_HOURLY_COST + $ALB_LCU_COST" | bc)
    echo "  Hourly charge: \$$ALB_HOURLY_COST"
    echo "  LCU charge (~100 LCU-hours): \$$ALB_LCU_COST"
    echo "  ALB Subtotal: \$$ALB_TOTAL"

    # NAT Gateways
    echo -e "\n${GREEN}NAT Gateways${NC}"
    NAT_HOURLY=$(echo "$HOURS_PER_MONTH * $NAT_GWS * $NAT_GW_HOURLY" | bc)
    NAT_DATA_COST=$(echo "$NAT_GWS * 10 * $NAT_GW_DATA" | bc)  # Assume 10GB/month per gateway
    NAT_TOTAL=$(echo "$NAT_HOURLY + $NAT_DATA_COST" | bc)
    echo "  Hourly ($NAT_GWS gateways): \$$NAT_HOURLY"
    echo "  Data processing (~10GB/month): \$$NAT_DATA_COST"
    echo "  NAT Gateway Subtotal: \$$NAT_TOTAL"

    # RDS Database
    echo -e "\n${GREEN}RDS Database${NC}"
    RDS_HOURLY_COST=$(echo "$HOURS_PER_MONTH * $RDS_T3_MEDIUM" | bc)
    RDS_STORAGE_COST=$(echo "$RDS_STORAGE_GB * $RDS_STORAGE" | bc)
    RDS_TOTAL=$(echo "$RDS_HOURLY_COST + $RDS_STORAGE_COST" | bc)
    echo "  Instance (db.t3.medium, Multi-AZ): \$$RDS_HOURLY_COST"
    echo "  Storage (${RDS_STORAGE_GB}GB gp2): \$$RDS_STORAGE_COST"
    echo "  RDS Subtotal: \$$RDS_TOTAL"

    # Storage (EBS)
    echo -e "\n${GREEN}Storage (EBS)${NC}"
    EBS_COST=$(echo "$EBS_STORAGE_GB * $EBS_GP2" | bc)
    echo "  EBS gp2 (~${EBS_STORAGE_GB}GB): \$$EBS_COST"

    # CloudWatch
    echo -e "\n${GREEN}CloudWatch & Monitoring${NC}"
    CW_LOGS=$(echo "$CLOUDWATCH_GB_MONTH * $CLOUDWATCH_LOGS" | bc)
    CW_ALARMS=0.10  # 2 alarms * $0.05 each
    CW_TOTAL=$(echo "$CW_LOGS + $CW_ALARMS" | bc)
    echo "  Logs (~${CLOUDWATCH_GB_MONTH}GB/month): \$$CW_LOGS"
    echo "  Alarms (2x): \$$CW_ALARMS"
    echo "  CloudWatch Subtotal: \$$CW_TOTAL"

    # Data Transfer
    echo -e "\n${GREEN}Data Transfer${NC}"
    DT_COST=5.00  # Estimated
    echo "  NAT GW + RDS data transfer: \$$DT_COST"

    # Total
    echo -e "\n${BLUE}=== MONTHLY TOTAL ===${NC}"
    TOTAL=$(echo "$EC2_TOTAL + $ALB_TOTAL + $NAT_TOTAL + $RDS_TOTAL + $EBS_COST + $CW_TOTAL + $DT_COST" | bc)
    echo -e "  ${YELLOW}\$${TOTAL}${NC}/month"

    # Annual
    ANNUAL=$(echo "$TOTAL * 12" | bc)
    echo -e "  ${YELLOW}\$${ANNUAL}${NC}/year\n"

    # Summary table
    echo -e "${BLUE}=== Cost Summary Table ===${NC}"
    printf "%-30s %10s %10s\n" "Component" "Monthly" "Annual"
    printf "%-30s %10s %10s\n" "---" "---" "---"
    printf "%-30s %10s %10s\n" "EC2 Compute" "\$$EC2_TOTAL" "\$$(echo "$EC2_TOTAL * 12" | bc)"
    printf "%-30s %10s %10s\n" "Load Balancer" "\$$ALB_TOTAL" "\$$(echo "$ALB_TOTAL * 12" | bc)"
    printf "%-30s %10s %10s\n" "NAT Gateways" "\$$NAT_TOTAL" "\$$(echo "$NAT_TOTAL * 12" | bc)"
    printf "%-30s %10s %10s\n" "RDS Database" "\$$RDS_TOTAL" "\$$(echo "$RDS_TOTAL * 12" | bc)"
    printf "%-30s %10s %10s\n" "Storage (EBS)" "\$$EBS_COST" "\$$(echo "$EBS_COST * 12" | bc)"
    printf "%-30s %10s %10s\n" "CloudWatch" "\$$CW_TOTAL" "\$$(echo "$CW_TOTAL * 12" | bc)"
    printf "%-30s %10s %10s\n" "Data Transfer" "\$$DT_COST" "\$$(echo "$DT_COST * 12" | bc)"
    printf "%-30s %10s %10s\n" "TOTAL" "\$${TOTAL}" "\$${ANNUAL}"

    # Cost optimization recommendations
    echo -e "\n${BLUE}=== Cost Optimization Recommendations ===${NC}"
    echo "1. Use Reserved Instances (RI) for Web tier - Save 30-40%"
    echo "   Savings: ~\$$(echo "$EC2_TOTAL * 0.35" | bc)/month = \$$(echo "$EC2_TOTAL * 0.35 * 12" | bc)/year"
    echo ""
    echo "2. Use RDS Reserved Capacity - Save 20-30%"
    echo "   Savings: ~\$$(echo "$RDS_TOTAL * 0.25" | bc)/month = \$$(echo "$RDS_TOTAL * 0.25 * 12" | bc)/year"
    echo ""
    echo "3. Reduce EC2 instance count during off-peak hours"
    echo "   Potential: ~\$$(echo "$WEB_COST * 0.15" | bc)/month (15% reduction)"
    echo ""
    echo "4. Use S3 Lifecycle Policies for RDS snapshots"
    echo "   Potential: ~\$2-5/month"
    echo ""
    echo "5. Monitor CloudWatch costs (current logs: ${CLOUDWATCH_GB_MONTH}GB/month)"
    echo "   Reduce if not needed: Save \$$(echo "$CLOUDWATCH_GB_MONTH * 0.50 * 0.5" | bc)/month"

    # Cost breakdown
    echo -e "\n${BLUE}=== Cost Distribution ===${NC}"
    RDS_PERCENT=$(echo "scale=1; $RDS_TOTAL * 100 / $TOTAL" | bc)
    EC2_PERCENT=$(echo "scale=1; $EC2_TOTAL * 100 / $TOTAL" | bc)
    ALB_PERCENT=$(echo "scale=1; $ALB_TOTAL * 100 / $TOTAL" | bc)
    NAT_PERCENT=$(echo "scale=1; $NAT_TOTAL * 100 / $TOTAL" | bc)
    OTHER_PERCENT=$(echo "scale=1; ($EBS_COST + $CW_TOTAL + $DT_COST) * 100 / $TOTAL" | bc)

    echo "RDS Database: $RDS_PERCENT%"
    echo "EC2 Compute:  $EC2_PERCENT%"
    echo "ALB:          $ALB_PERCENT%"
    echo "NAT GW:       $NAT_PERCENT%"
    echo "Other:        $OTHER_PERCENT%"

    echo -e "\n${BLUE}========================================${NC}"
    echo -e "${BLUE}Cost Analysis Complete${NC}"
    echo -e "${BLUE}========================================${NC}\n"

    echo "Note: This is an estimate based on typical usage patterns."
    echo "Actual costs may vary based on:"
    echo "  - Traffic patterns (ALB LCU consumption)"
    echo "  - Data transfer volumes"
    echo "  - CloudWatch logs retention"
    echo "  - Actual instance scaling behavior"
    echo ""
    echo "For accurate costs, use AWS Cost Explorer or Pricing Calculator:"
    echo "  https://calculator.aws/"
}

main
