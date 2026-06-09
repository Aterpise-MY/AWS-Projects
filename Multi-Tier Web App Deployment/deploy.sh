#!/bin/bash

#############################################################################
# Multi-Tier Web Application Deployment Script (AWS CLI)
#
# This script deploys a complete multi-tier web application on AWS with:
# - VPC, Subnets, IGW, NAT Gateways
# - Security Groups (ALB, Bastion, Web/App, RDS)
# - Bastion Host, Web/App EC2 instances with Auto Scaling
# - Application Load Balancer
# - RDS MySQL database
# - Auto Scaling Policies with CloudWatch Alarms
#
# Usage: bash deploy.sh
#############################################################################

set -e
set -o pipefail

# Color output for better readability
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ============================================================================
# CONFIGURATION - Update these variables before deployment
# ============================================================================

REGION="us-east-1"
PROJECT="multitier-webapp"
ENV="production"
VPC_CIDR="10.0.0.0/16"

# REQUIRED: Replace with your EC2 Key Pair name
KEY_PAIR_NAME="your-key-pair-name"

# SSH CIDR - WARNING: 0.0.0.0/0 is insecure in production
ALLOWED_SSH_CIDR="0.0.0.0/0"

# Database Configuration
DB_USERNAME="admin"
DB_PASSWORD="ChangeMe123!@#"
DB_INSTANCE_CLASS="db.t3.medium"
DB_ALLOCATED_STORAGE="20"

# Auto Scaling Configuration
ASG_MIN=1
ASG_MAX=4
ASG_DESIRED=2

# CPU Scaling Thresholds
CPU_SCALE_OUT_THRESHOLD=60
CPU_SCALE_IN_THRESHOLD=40

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# ============================================================================
# PRE-FLIGHT CHECKS
# ============================================================================

log_info "Starting deployment..."
log_info "Region: $REGION, Project: $PROJECT, Environment: $ENV"

# Check AWS CLI is installed
if ! command -v aws &> /dev/null; then
    log_error "AWS CLI is not installed. Please install it first."
    exit 1
fi

# Check key pair exists
if ! aws ec2 describe-key-pairs --key-names "$KEY_PAIR_NAME" --region "$REGION" &> /dev/null; then
    log_error "Key pair '$KEY_PAIR_NAME' not found in region $REGION"
    log_info "Create a key pair with: aws ec2 create-key-pair --key-name $KEY_PAIR_NAME --region $REGION"
    exit 1
fi

log_success "Pre-flight checks passed"

# ============================================================================
# 1. VPC CREATION
# ============================================================================

log_info "Creating VPC..."
VPC=$(aws ec2 create-vpc --cidr-block "$VPC_CIDR" --region "$REGION" --query 'Vpc.VpcId' --output text)
log_success "VPC created: $VPC"

aws ec2 modify-vpc-attribute --vpc-id "$VPC" --enable-dns-hostnames --region "$REGION"
aws ec2 modify-vpc-attribute --vpc-id "$VPC" --enable-dns-support --region "$REGION"
aws ec2 create-tags --resources "$VPC" --tags "Key=Name,Value=$PROJECT-vpc" "Key=Environment,Value=$ENV" "Key=Project,Value=$PROJECT" "Key=ManagedBy,Value=awscli" --region "$REGION"

# ============================================================================
# 2. SUBNETS CREATION
# ============================================================================

log_info "Creating subnets..."

# Get availability zones
AZ1=$(aws ec2 describe-availability-zones --region "$REGION" --query 'AvailabilityZones[0].ZoneName' --output text)
AZ2=$(aws ec2 describe-availability-zones --region "$REGION" --query 'AvailabilityZones[1].ZoneName' --output text)
log_info "Using AZs: $AZ1, $AZ2"

# Public Subnets
PUBLIC_SUBNET_1=$(aws ec2 create-subnet --vpc-id "$VPC" --cidr-block "10.0.1.0/24" --availability-zone "$AZ1" --region "$REGION" --query 'Subnet.SubnetId' --output text)
PUBLIC_SUBNET_2=$(aws ec2 create-subnet --vpc-id "$VPC" --cidr-block "10.0.2.0/24" --availability-zone "$AZ2" --region "$REGION" --query 'Subnet.SubnetId' --output text)
log_success "Public Subnets created: $PUBLIC_SUBNET_1, $PUBLIC_SUBNET_2"

# Private Subnets
PRIVATE_SUBNET_1=$(aws ec2 create-subnet --vpc-id "$VPC" --cidr-block "10.0.3.0/24" --availability-zone "$AZ1" --region "$REGION" --query 'Subnet.SubnetId' --output text)
PRIVATE_SUBNET_2=$(aws ec2 create-subnet --vpc-id "$VPC" --cidr-block "10.0.4.0/24" --availability-zone "$AZ2" --region "$REGION" --query 'Subnet.SubnetId' --output text)
log_success "Private Subnets created: $PRIVATE_SUBNET_1, $PRIVATE_SUBNET_2"

# Tag subnets
for i in 1 2; do
    eval "SUBNET=\$PUBLIC_SUBNET_$i"
    aws ec2 create-tags --resources "$SUBNET" --tags "Key=Name,Value=$PROJECT-public-subnet-$i" "Key=Type,Value=Public" --region "$REGION"
done

for i in 1 2; do
    eval "SUBNET=\$PRIVATE_SUBNET_$i"
    aws ec2 create-tags --resources "$SUBNET" --tags "Key=Name,Value=$PROJECT-private-subnet-$i" "Key=Type,Value=Private" --region "$REGION"
done

# ============================================================================
# 3. INTERNET GATEWAY
# ============================================================================

log_info "Creating Internet Gateway..."
IGW=$(aws ec2 create-internet-gateway --region "$REGION" --query 'InternetGateway.InternetGatewayId' --output text)
log_success "Internet Gateway created: $IGW"

aws ec2 attach-internet-gateway --vpc-id "$VPC" --internet-gateway-id "$IGW" --region "$REGION"
aws ec2 create-tags --resources "$IGW" --tags "Key=Name,Value=$PROJECT-igw" --region "$REGION"

# ============================================================================
# 4. ELASTIC IPs AND NAT GATEWAYS
# ============================================================================

log_info "Creating Elastic IPs and NAT Gateways..."

EIP_1=$(aws ec2 allocate-address --domain vpc --region "$REGION" --query 'AllocationId' --output text)
EIP_2=$(aws ec2 allocate-address --domain vpc --region "$REGION" --query 'AllocationId' --output text)
log_success "Elastic IPs allocated: $EIP_1, $EIP_2"

# Enable public IP assignment on public subnets
aws ec2 modify-subnet-attribute --subnet-id "$PUBLIC_SUBNET_1" --map-public-ip-on-launch --region "$REGION"
aws ec2 modify-subnet-attribute --subnet-id "$PUBLIC_SUBNET_2" --map-public-ip-on-launch --region "$REGION"

NAT_GW_1=$(aws ec2 create-nat-gateway --subnet-id "$PUBLIC_SUBNET_1" --allocation-id "$EIP_1" --region "$REGION" --query 'NatGateway.NatGatewayId' --output text)
NAT_GW_2=$(aws ec2 create-nat-gateway --subnet-id "$PUBLIC_SUBNET_2" --allocation-id "$EIP_2" --region "$REGION" --query 'NatGateway.NatGatewayId' --output text)
log_success "NAT Gateways created: $NAT_GW_1, $NAT_GW_2"

# Wait for NAT Gateways to be available
log_info "Waiting for NAT Gateways to be available..."
aws ec2 wait nat-gateway-available --nat-gateway-ids "$NAT_GW_1" "$NAT_GW_2" --region "$REGION"
log_success "NAT Gateways are available"

# ============================================================================
# 5. ROUTE TABLES
# ============================================================================

log_info "Creating and configuring route tables..."

# Public Route Table
PUBLIC_RT=$(aws ec2 create-route-table --vpc-id "$VPC" --region "$REGION" --query 'RouteTable.RouteTableId' --output text)
log_success "Public Route Table created: $PUBLIC_RT"

aws ec2 create-route --route-table-id "$PUBLIC_RT" --destination-cidr-block "0.0.0.0/0" --gateway-id "$IGW" --region "$REGION"
aws ec2 associate-route-table --subnet-id "$PUBLIC_SUBNET_1" --route-table-id "$PUBLIC_RT" --region "$REGION"
aws ec2 associate-route-table --subnet-id "$PUBLIC_SUBNET_2" --route-table-id "$PUBLIC_RT" --region "$REGION"
aws ec2 create-tags --resources "$PUBLIC_RT" --tags "Key=Name,Value=$PROJECT-public-rt" --region "$REGION"

# Private Route Tables (one per AZ for HA)
PRIVATE_RT_1=$(aws ec2 create-route-table --vpc-id "$VPC" --region "$REGION" --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route --route-table-id "$PRIVATE_RT_1" --destination-cidr-block "0.0.0.0/0" --nat-gateway-id "$NAT_GW_1" --region "$REGION"
aws ec2 associate-route-table --subnet-id "$PRIVATE_SUBNET_1" --route-table-id "$PRIVATE_RT_1" --region "$REGION"
aws ec2 create-tags --resources "$PRIVATE_RT_1" --tags "Key=Name,Value=$PROJECT-private-rt-1" --region "$REGION"
log_success "Private Route Table 1 created: $PRIVATE_RT_1"

PRIVATE_RT_2=$(aws ec2 create-route-table --vpc-id "$VPC" --region "$REGION" --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route --route-table-id "$PRIVATE_RT_2" --destination-cidr-block "0.0.0.0/0" --nat-gateway-id "$NAT_GW_2" --region "$REGION"
aws ec2 associate-route-table --subnet-id "$PRIVATE_SUBNET_2" --route-table-id "$PRIVATE_RT_2" --region "$REGION"
aws ec2 create-tags --resources "$PRIVATE_RT_2" --tags "Key=Name,Value=$PROJECT-private-rt-2" --region "$REGION"
log_success "Private Route Table 2 created: $PRIVATE_RT_2"

# ============================================================================
# 6. SECURITY GROUPS
# ============================================================================

log_info "Creating Security Groups..."

# ALB Security Group
ALB_SG=$(aws ec2 create-security-group --group-name "$PROJECT-alb-sg" --description "Security group for ALB" --vpc-id "$VPC" --region "$REGION" --query 'GroupId' --output text)
log_success "ALB Security Group created: $ALB_SG"

aws ec2 authorize-security-group-ingress --group-id "$ALB_SG" --protocol tcp --port 80 --cidr 0.0.0.0/0 --region "$REGION"
aws ec2 authorize-security-group-ingress --group-id "$ALB_SG" --protocol tcp --port 443 --cidr 0.0.0.0/0 --region "$REGION"
aws ec2 authorize-security-group-egress --group-id "$ALB_SG" --protocol -1 --cidr 0.0.0.0/0 --region "$REGION"
aws ec2 create-tags --resources "$ALB_SG" --tags "Key=Name,Value=$PROJECT-alb-sg" --region "$REGION"

# Bastion Security Group
BASTION_SG=$(aws ec2 create-security-group --group-name "$PROJECT-bastion-sg" --description "Security group for Bastion" --vpc-id "$VPC" --region "$REGION" --query 'GroupId' --output text)
log_success "Bastion Security Group created: $BASTION_SG"

aws ec2 authorize-security-group-ingress --group-id "$BASTION_SG" --protocol tcp --port 22 --cidr "$ALLOWED_SSH_CIDR" --region "$REGION"
aws ec2 authorize-security-group-egress --group-id "$BASTION_SG" --protocol -1 --cidr 0.0.0.0/0 --region "$REGION"
aws ec2 create-tags --resources "$BASTION_SG" --tags "Key=Name,Value=$PROJECT-bastion-sg" --region "$REGION"

# Web/App Security Group
WEBAPP_SG=$(aws ec2 create-security-group --group-name "$PROJECT-web-app-sg" --description "Security group for Web/App EC2" --vpc-id "$VPC" --region "$REGION" --query 'GroupId' --output text)
log_success "Web/App Security Group created: $WEBAPP_SG"

aws ec2 authorize-security-group-ingress --group-id "$WEBAPP_SG" --protocol tcp --port 80 --source-group "$ALB_SG" --region "$REGION"
aws ec2 authorize-security-group-ingress --group-id "$WEBAPP_SG" --protocol tcp --port 22 --source-group "$BASTION_SG" --region "$REGION"
aws ec2 authorize-security-group-egress --group-id "$WEBAPP_SG" --protocol -1 --cidr 0.0.0.0/0 --region "$REGION"
aws ec2 create-tags --resources "$WEBAPP_SG" --tags "Key=Name,Value=$PROJECT-web-app-sg" --region "$REGION"

# RDS Security Group
RDS_SG=$(aws ec2 create-security-group --group-name "$PROJECT-rds-sg" --description "Security group for RDS" --vpc-id "$VPC" --region "$REGION" --query 'GroupId' --output text)
log_success "RDS Security Group created: $RDS_SG"

aws ec2 authorize-security-group-ingress --group-id "$RDS_SG" --protocol tcp --port 3306 --source-group "$WEBAPP_SG" --region "$REGION"
aws ec2 create-tags --resources "$RDS_SG" --tags "Key=Name,Value=$PROJECT-rds-sg" --region "$REGION"

# ============================================================================
# 7. BASTION HOST
# ============================================================================

log_info "Creating Bastion Host..."

# Get latest Amazon Linux 2 AMI
AMI_ID=$(aws ec2 describe-images --owners amazon --filters "Name=name,Values=amzn2-ami-hvm-*-x86_64-gp2" "Name=state,Values=available" --region "$REGION" --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' --output text)
log_info "Using AMI: $AMI_ID"

BASTION=$(aws ec2 run-instances --image-id "$AMI_ID" --instance-type t3.micro --key-name "$KEY_PAIR_NAME" --security-group-ids "$BASTION_SG" --subnet-id "$PUBLIC_SUBNET_1" --region "$REGION" --query 'Instances[0].InstanceId' --output text)
log_success "Bastion Host created: $BASTION"

aws ec2 create-tags --resources "$BASTION" --tags "Key=Name,Value=$PROJECT-bastion" "Key=Role,Value=Bastion" --region "$REGION"

# Wait for bastion to be running
log_info "Waiting for Bastion Host to be running..."
aws ec2 wait instance-running --instance-ids "$BASTION" --region "$REGION"
log_success "Bastion Host is running"

# Get bastion public IP
BASTION_IP=$(aws ec2 describe-instances --instance-ids "$BASTION" --region "$REGION" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
log_success "Bastion public IP: $BASTION_IP"

# ============================================================================
# 8. APPLICATION LOAD BALANCER
# ============================================================================

log_info "Creating Application Load Balancer..."

ALB=$(aws elbv2 create-load-balancer --name "$PROJECT-alb" --subnets "$PUBLIC_SUBNET_1" "$PUBLIC_SUBNET_2" --security-groups "$ALB_SG" --scheme internet-facing --type application --region "$REGION" --query 'LoadBalancers[0].LoadBalancerArn' --output text)
log_success "ALB created: $ALB"

ALB_DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB" --region "$REGION" --query 'LoadBalancers[0].DNSName' --output text)
log_success "ALB DNS: $ALB_DNS"

# ============================================================================
# 9. TARGET GROUP
# ============================================================================

log_info "Creating Target Group..."

TG=$(aws elbv2 create-target-group --name "$PROJECT-tg" --protocol HTTP --port 80 --vpc-id "$VPC" --health-check-enabled --health-check-protocol HTTP --health-check-path "/health" --health-check-interval-seconds 30 --health-check-timeout-seconds 5 --healthy-threshold-count 2 --unhealthy-threshold-count 3 --region "$REGION" --query 'TargetGroups[0].TargetGroupArn' --output text)
log_success "Target Group created: $TG"

# ============================================================================
# 10. ALB LISTENER
# ============================================================================

log_info "Creating ALB Listener..."

LISTENER=$(aws elbv2 create-listener --load-balancer-arn "$ALB" --protocol HTTP --port 80 --default-actions Type=forward,TargetGroupArn="$TG" --region "$REGION" --query 'Listeners[0].ListenerArn' --output text)
log_success "Listener created: $LISTENER"

# ============================================================================
# 11. RDS DB SUBNET GROUP
# ============================================================================

log_info "Creating RDS DB Subnet Group..."

DB_SUBNET_GROUP=$(aws rds create-db-subnet-group --db-subnet-group-name "$PROJECT-db-subnet-group" --db-subnet-group-description "DB subnet group for $PROJECT" --subnet-ids "$PRIVATE_SUBNET_1" "$PRIVATE_SUBNET_2" --region "$REGION" --query 'DBSubnetGroup.DBSubnetGroupName' --output text)
log_success "DB Subnet Group created: $DB_SUBNET_GROUP"

aws rds add-tags-to-resource --resource-name "arn:aws:rds:$REGION:$(aws sts get-caller-identity --query Account --output text):subgrp:$DB_SUBNET_GROUP" --tags "Key=Name,Value=$PROJECT-db-subnet-group" --region "$REGION"

# ============================================================================
# 12. RDS MYSQL INSTANCE
# ============================================================================

log_info "Creating RDS MySQL instance (this may take 5-10 minutes)..."

RDS=$(aws rds create-db-instance \
    --db-instance-identifier "$PROJECT-mysql" \
    --engine mysql \
    --engine-version "8.0.35" \
    --db-instance-class "$DB_INSTANCE_CLASS" \
    --allocated-storage "$DB_ALLOCATED_STORAGE" \
    --storage-type gp2 \
    --storage-encrypted \
    --master-username "$DB_USERNAME" \
    --master-user-password "$DB_PASSWORD" \
    --db-name "appdb" \
    --db-subnet-group-name "$DB_SUBNET_GROUP" \
    --vpc-security-group-ids "$RDS_SG" \
    --publicly-accessible false \
    --multi-az \
    --backup-retention-period 7 \
    --backup-window "03:00-04:00" \
    --preferred-maintenance-window "sun:04:00-sun:05:00" \
    --enable-cloudwatch-logs-exports '["error","general","slowquery"]' \
    --deletion-protection \
    --region "$REGION" \
    --query 'DBInstance.DBInstanceIdentifier' \
    --output text)
log_success "RDS instance created: $RDS"

aws rds add-tags-to-resource --resource-name "arn:aws:rds:$REGION:$(aws sts get-caller-identity --query Account --output text):db:$RDS" --tags "Key=Name,Value=$PROJECT-mysql" --region "$REGION"

# ============================================================================
# 13. LAUNCH TEMPLATE
# ============================================================================

log_info "Creating Launch Template..."

# User data script
USER_DATA=$(cat << 'EOF'
#!/bin/bash
yum update -y
yum install -y httpd mysql
systemctl start httpd
systemctl enable httpd

# Health check page
cat > /var/www/html/health << 'HEALTH'
OK
HEALTH

# Index page with instance metadata
INSTANCE_ID=$(ec2-metadata --instance-id | cut -d " " -f 2)
AVAILABILITY_ZONE=$(ec2-metadata --availability-zone | cut -d " " -f 2)
INSTANCE_TYPE=$(ec2-metadata --instance-type | cut -d " " -f 2)
LOCAL_IPV4=$(ec2-metadata --local-ipv4 | cut -d " " -f 2)

cat > /var/www/html/index.html << 'HTML'
<!DOCTYPE html>
<html>
<head>
    <title>Multi-Tier Web App</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 40px; background: #f0f0f0; }
        .container { background: white; padding: 20px; border-radius: 5px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }
        h1 { color: #333; }
        .info { margin: 15px 0; padding: 10px; background: #f9f9f9; border-left: 4px solid #0066cc; }
        .label { font-weight: bold; color: #0066cc; }
    </style>
</head>
<body>
    <div class="container">
        <h1>✓ Multi-Tier Web Application Deployed</h1>
        <p>Instance is running successfully via Auto Scaling Group</p>
        <div class="info">
            <div class="label">Instance ID:</div>
            <div>INSTANCE_ID_PLACEHOLDER</div>
        </div>
    </div>
</body>
</html>
HTML

chmod 644 /var/www/html/index.html /var/www/html/health
EOF
)

# Encode user data in base64
USER_DATA_B64=$(echo "$USER_DATA" | base64 -w 0)

LAUNCH_TEMPLATE=$(aws ec2 create-launch-template \
    --launch-template-name "$PROJECT-lt" \
    --version-description "Launch template for $PROJECT" \
    --launch-template-data "{
        \"ImageId\": \"$AMI_ID\",
        \"InstanceType\": \"t3.medium\",
        \"KeyName\": \"$KEY_PAIR_NAME\",
        \"SecurityGroupIds\": [\"$WEBAPP_SG\"],
        \"UserData\": \"$USER_DATA_B64\",
        \"Monitoring\": {\"Enabled\": true},
        \"TagSpecifications\": [{
            \"ResourceType\": \"instance\",
            \"Tags\": [{\"Key\": \"Name\", \"Value\": \"$PROJECT-asg-instance\"}]
        }]
    }" \
    --region "$REGION" \
    --query 'LaunchTemplate.LaunchTemplateId' \
    --output text)
log_success "Launch Template created: $LAUNCH_TEMPLATE"

# ============================================================================
# 14. AUTO SCALING GROUP
# ============================================================================

log_info "Creating Auto Scaling Group..."

ASG=$(aws autoscaling create-auto-scaling-group \
    --auto-scaling-group-name "$PROJECT-asg" \
    --launch-template "LaunchTemplateId=$LAUNCH_TEMPLATE,Version=\$Latest" \
    --min-size "$ASG_MIN" \
    --max-size "$ASG_MAX" \
    --desired-capacity "$ASG_DESIRED" \
    --availability-zones "$AZ1" "$AZ2" \
    --vpc-zone-identifier "$PRIVATE_SUBNET_1,$PRIVATE_SUBNET_2" \
    --target-group-arns "$TG" \
    --health-check-type ELB \
    --health-check-grace-period 300 \
    --tags "Key=Name,Value=$PROJECT-asg-instance,PropagateAtLaunch=true" "Key=Environment,Value=$ENV,PropagateAtLaunch=true" \
    --region "$REGION")
log_success "Auto Scaling Group created: $PROJECT-asg"

log_info "Waiting for ASG instances to be healthy..."
sleep 30

# ============================================================================
# 15. AUTO SCALING POLICIES AND CLOUDWATCH ALARMS
# ============================================================================

log_info "Creating Auto Scaling Policies..."

SCALE_OUT_POLICY=$(aws autoscaling put-scaling-policy \
    --auto-scaling-group-name "$PROJECT-asg" \
    --policy-name "$PROJECT-scale-out" \
    --policy-type TargetTrackingScaling \
    --target-tracking-configuration "
        TargetValue=$CPU_SCALE_OUT_THRESHOLD,
        PredefinedMetricSpecification={
            PredefinedMetricType=ASGAverageCPUUtilization
        },
        ScaleOutCooldown=300,
        ScaleInCooldown=300
    " \
    --region "$REGION" \
    --query 'PolicyARN' \
    --output text)
log_success "Scale Out Policy created"

# Alternative: Create step scaling with alarms for more control
log_info "Creating CloudWatch Alarms..."

# High CPU Alarm
aws cloudwatch put-metric-alarm \
    --alarm-name "$PROJECT-cpu-high" \
    --alarm-description "Alarm when CPU exceeds $CPU_SCALE_OUT_THRESHOLD%" \
    --metric-name CPUUtilization \
    --namespace AWS/EC2 \
    --statistic Average \
    --period 60 \
    --threshold "$CPU_SCALE_OUT_THRESHOLD" \
    --comparison-operator GreaterThanThreshold \
    --evaluation-periods 2 \
    --dimensions "Name=AutoScalingGroupName,Value=$PROJECT-asg" \
    --region "$REGION"
log_success "CPU High Alarm created"

# Low CPU Alarm
aws cloudwatch put-metric-alarm \
    --alarm-name "$PROJECT-cpu-low" \
    --alarm-description "Alarm when CPU falls below $CPU_SCALE_IN_THRESHOLD%" \
    --metric-name CPUUtilization \
    --namespace AWS/EC2 \
    --statistic Average \
    --period 300 \
    --threshold "$CPU_SCALE_IN_THRESHOLD" \
    --comparison-operator LessThanThreshold \
    --evaluation-periods 2 \
    --dimensions "Name=AutoScalingGroupName,Value=$PROJECT-asg" \
    --region "$REGION"
log_success "CPU Low Alarm created"

# ============================================================================
# WAIT FOR RDS AND DISPLAY SUMMARY
# ============================================================================

log_info "Waiting for RDS instance to be available (this may take several minutes)..."
aws rds wait db-instance-available --db-instances "$RDS" --region "$REGION"
log_success "RDS instance is available"

# Get RDS endpoint
RDS_ENDPOINT=$(aws rds describe-db-instances --db-instance-identifier "$RDS" --region "$REGION" --query 'DBInstances[0].Endpoint.Address' --output text)
RDS_PORT=$(aws rds describe-db-instances --db-instance-identifier "$RDS" --region "$REGION" --query 'DBInstances[0].Endpoint.Port' --output text)

# ============================================================================
# DEPLOYMENT SUMMARY
# ============================================================================

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}DEPLOYMENT COMPLETE!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${BLUE}Infrastructure Summary:${NC}"
echo "  Project: $PROJECT"
echo "  Environment: $ENV"
echo "  Region: $REGION"
echo ""
echo -e "${BLUE}VPC & Networking:${NC}"
echo "  VPC ID: $VPC"
echo "  Public Subnets: $PUBLIC_SUBNET_1, $PUBLIC_SUBNET_2"
echo "  Private Subnets: $PRIVATE_SUBNET_1, $PRIVATE_SUBNET_2"
echo ""
echo -e "${BLUE}Access Points:${NC}"
echo "  ALB DNS: http://$ALB_DNS"
echo "  Bastion IP: $BASTION_IP (SSH: ssh -i your-key.pem ec2-user@$BASTION_IP)"
echo ""
echo -e "${BLUE}Database:${NC}"
echo "  RDS Endpoint: $RDS_ENDPOINT:$RDS_PORT"
echo "  Database: appdb"
echo "  Username: $DB_USERNAME"
echo "  (Store password in secure location)"
echo ""
echo -e "${BLUE}Auto Scaling:${NC}"
echo "  ASG Name: $PROJECT-asg"
echo "  Min: $ASG_MIN, Max: $ASG_MAX, Desired: $ASG_DESIRED"
echo "  CPU Scale-out: >$CPU_SCALE_OUT_THRESHOLD%"
echo "  CPU Scale-in: <$CPU_SCALE_IN_THRESHOLD%"
echo ""
echo -e "${YELLOW}Allow 3-5 minutes for ALB health checks and instance registration.${NC}"
echo ""

# ============================================================================
# CLEANUP (COMMENTED OUT FOR SAFETY)
# ============================================================================

# To destroy all resources, use these commands in reverse dependency order:
# aws autoscaling delete-auto-scaling-group --auto-scaling-group-name "$PROJECT-asg" --force-delete --region "$REGION"
# aws ec2 delete-launch-template --launch-template-id "$LAUNCH_TEMPLATE" --region "$REGION"
# aws elbv2 delete-load-balancer --load-balancer-arn "$ALB" --region "$REGION"
# aws elbv2 delete-target-group --target-group-arn "$TG" --region "$REGION"
# aws rds delete-db-instance --db-instance-identifier "$RDS" --skip-final-snapshot --delete-automated-backups --region "$REGION"
# aws rds delete-db-subnet-group --db-subnet-group-name "$DB_SUBNET_GROUP" --region "$REGION"
# aws ec2 terminate-instances --instance-ids "$BASTION" --region "$REGION"
# aws ec2 delete-security-group --group-id "$ALB_SG" --region "$REGION"
# aws ec2 delete-security-group --group-id "$BASTION_SG" --region "$REGION"
# aws ec2 delete-security-group --group-id "$WEBAPP_SG" --region "$REGION"
# aws ec2 delete-security-group --group-id "$RDS_SG" --region "$REGION"
# aws ec2 delete-route-table --route-table-id "$PUBLIC_RT" --region "$REGION"
# aws ec2 delete-route-table --route-table-id "$PRIVATE_RT_1" --region "$REGION"
# aws ec2 delete-route-table --route-table-id "$PRIVATE_RT_2" --region "$REGION"
# aws ec2 release-address --allocation-id "$EIP_1" --region "$REGION"
# aws ec2 release-address --allocation-id "$EIP_2" --region "$REGION"
# aws ec2 delete-nat-gateway --nat-gateway-id "$NAT_GW_1" --region "$REGION"
# aws ec2 delete-nat-gateway --nat-gateway-id "$NAT_GW_2" --region "$REGION"
# aws ec2 detach-internet-gateway --vpc-id "$VPC" --internet-gateway-id "$IGW" --region "$REGION"
# aws ec2 delete-internet-gateway --internet-gateway-id "$IGW" --region "$REGION"
# aws ec2 delete-subnet --subnet-id "$PUBLIC_SUBNET_1" --region "$REGION"
# aws ec2 delete-subnet --subnet-id "$PUBLIC_SUBNET_2" --region "$REGION"
# aws ec2 delete-subnet --subnet-id "$PRIVATE_SUBNET_1" --region "$REGION"
# aws ec2 delete-subnet --subnet-id "$PRIVATE_SUBNET_2" --region "$REGION"
# aws ec2 delete-vpc --vpc-id "$VPC" --region "$REGION"
