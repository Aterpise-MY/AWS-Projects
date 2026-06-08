#!/usr/bin/env bash
# =============================================================================
# deploy.sh — Scalable Web App with ALB & Auto Scaling (AWS CLI)
# Region: us-east-1
# =============================================================================
set -euo pipefail

# =============================================================================
# CONFIGURATION — edit these before running
# =============================================================================
REGION="us-east-1"
VPC_ID="vpc-xxxxxxxxxxxxxxxxx"          # Your existing VPC
SUBNET_IDS=("subnet-xxxxxxxxxxxxxxxxx" "subnet-yyyyyyyyyyyyyyyyy")  # Min 2 AZs
KEY_PAIR_NAME="your-key-pair-name"      # Must already exist in the region
AMI_ID=""                               # Auto-resolved below if left blank
ENVIRONMENT="production"

APP_NAME="WebApp"
SG_NAME="WebAppSG"
LT_NAME="WebAppTemplate"
ALB_NAME="WebAppALB"
TG_NAME="WebAppTG"
ASG_NAME="WebAppASG"

INSTANCE_TYPE="t3.medium"
ASG_DESIRED=2
ASG_MIN=1
ASG_MAX=4

SCALE_OUT_CPU=60
SCALE_IN_CPU=40

# Comma-separated subnet string for ALB (requires >=2 subnets)
SUBNET_CSV=$(IFS=,; echo "${SUBNET_IDS[*]}")

# =============================================================================
# HELPERS
# =============================================================================
log()  { echo "[$(date '+%H:%M:%S')] $*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }

# Verify required tools
for cmd in aws jq; do
  command -v "$cmd" &>/dev/null || die "'$cmd' is not installed."
done

# Verify AWS credentials are active
aws sts get-caller-identity --region "$REGION" --output json &>/dev/null \
  || die "AWS credentials not configured or invalid."

log "Starting deployment in region: $REGION"

# =============================================================================
# 1. RESOLVE LATEST AMAZON LINUX 2 AMI (ap-southeast-1 → us-east-1)
#    The task specified ap-southeast-1 as the AMI source; we resolve the
#    equivalent image in our target region (us-east-1) so the AMI ID is valid.
# =============================================================================
if [[ -z "$AMI_ID" ]]; then
  log "Resolving latest Amazon Linux 2 AMI in $REGION..."
  AMI_ID=$(aws ec2 describe-images \
    --region "$REGION" \
    --owners amazon \
    --filters \
      "Name=name,Values=amzn2-ami-hvm-2.*-x86_64-gp2" \
      "Name=state,Values=available" \
    --query "sort_by(Images, &CreationDate)[-1].ImageId" \
    --output text)
  [[ -z "$AMI_ID" || "$AMI_ID" == "None" ]] && die "Could not resolve AMI ID."
  log "Resolved AMI: $AMI_ID"
fi

# =============================================================================
# 2. SECURITY GROUP
#    Allow inbound SSH (22), HTTP (80), HTTPS (443); allow all outbound.
# =============================================================================
log "Creating Security Group: $SG_NAME..."
SG_ID=$(aws ec2 create-security-group \
  --region "$REGION" \
  --group-name "$SG_NAME" \
  --description "WebApp SG — SSH, HTTP, HTTPS" \
  --vpc-id "$VPC_ID" \
  --query "GroupId" \
  --output text)

aws ec2 create-tags --region "$REGION" \
  --resources "$SG_ID" \
  --tags "Key=Name,Value=$SG_NAME" "Key=Environment,Value=$ENVIRONMENT"

# Authorise inbound rules in a single call
aws ec2 authorize-security-group-ingress \
  --region "$REGION" \
  --group-id "$SG_ID" \
  --ip-permissions \
    "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=0.0.0.0/0,Description=SSH}]" \
    "IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=0.0.0.0/0,Description=HTTP}]" \
    "IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=0.0.0.0/0,Description=HTTPS}]"

log "Security Group created: $SG_ID"

# =============================================================================
# 3. USER DATA — Install Apache, serve a basic HTML page
# =============================================================================
USER_DATA=$(base64 <<'USERDATA'
#!/bin/bash
yum update -y
yum install -y httpd
systemctl enable httpd
systemctl start httpd

# Gather instance metadata (IMDSv2)
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id)
AZ=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/placement/availability-zone)

cat > /var/www/html/index.html <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>WebApp — Production</title>
  <style>
    body { font-family: sans-serif; text-align: center; padding: 60px;
           background: #f0f4f8; color: #333; }
    .card { display: inline-block; background: white; border-radius: 8px;
            padding: 40px 60px; box-shadow: 0 4px 16px rgba(0,0,0,.1); }
    h1 { color: #e8821a; }
    code { background: #eee; padding: 2px 6px; border-radius: 4px; }
  </style>
</head>
<body>
  <div class="card">
    <h1>Hello from AWS!</h1>
    <p>Instance: <code>$INSTANCE_ID</code></p>
    <p>Availability Zone: <code>$AZ</code></p>
    <p>Environment: <strong>production</strong></p>
  </div>
</body>
</html>
EOF
USERDATA
)

# =============================================================================
# 4. LAUNCH TEMPLATE
# =============================================================================
log "Creating Launch Template: $LT_NAME..."

LT_ID=$(aws ec2 create-launch-template \
  --region "$REGION" \
  --launch-template-name "$LT_NAME" \
  --version-description "v1-initial" \
  --tag-specifications \
    "ResourceType=launch-template,Tags=[{Key=Name,Value=$LT_NAME},{Key=Environment,Value=$ENVIRONMENT}]" \
  --launch-template-data "{
    \"ImageId\": \"$AMI_ID\",
    \"InstanceType\": \"$INSTANCE_TYPE\",
    \"KeyName\": \"$KEY_PAIR_NAME\",
    \"SecurityGroupIds\": [\"$SG_ID\"],
    \"UserData\": \"$USER_DATA\",
    \"Monitoring\": {\"Enabled\": true},
    \"TagSpecifications\": [
      {
        \"ResourceType\": \"instance\",
        \"Tags\": [
          {\"Key\": \"Name\", \"Value\": \"$APP_NAME-instance\"},
          {\"Key\": \"Environment\", \"Value\": \"$ENVIRONMENT\"}
        ]
      },
      {
        \"ResourceType\": \"volume\",
        \"Tags\": [
          {\"Key\": \"Name\", \"Value\": \"$APP_NAME-volume\"},
          {\"Key\": \"Environment\", \"Value\": \"$ENVIRONMENT\"}
        ]
      }
    ]
  }" \
  --query "LaunchTemplate.LaunchTemplateId" \
  --output text)

log "Launch Template created: $LT_ID"

# =============================================================================
# 5. TARGET GROUP
#    Instance-type target, HTTP on port 80, health-check on /
# =============================================================================
log "Creating Target Group: $TG_NAME..."

TG_ARN=$(aws elbv2 create-target-group \
  --region "$REGION" \
  --name "$TG_NAME" \
  --protocol HTTP \
  --port 80 \
  --vpc-id "$VPC_ID" \
  --target-type instance \
  --health-check-protocol HTTP \
  --health-check-path "/" \
  --health-check-interval-seconds 30 \
  --health-check-timeout-seconds 5 \
  --healthy-threshold-count 2 \
  --unhealthy-threshold-count 3 \
  --matcher "HttpCode=200" \
  --query "TargetGroups[0].TargetGroupArn" \
  --output text)

aws elbv2 add-tags \
  --region "$REGION" \
  --resource-arns "$TG_ARN" \
  --tags "Key=Name,Value=$TG_NAME" "Key=Environment,Value=$ENVIRONMENT"

log "Target Group created: $TG_ARN"

# =============================================================================
# 6. APPLICATION LOAD BALANCER (internet-facing, >=2 AZs)
# =============================================================================
log "Creating ALB: $ALB_NAME (this may take ~1-2 minutes)..."

ALB_ARN=$(aws elbv2 create-load-balancer \
  --region "$REGION" \
  --name "$ALB_NAME" \
  --subnets $SUBNET_CSV \
  --security-groups "$SG_ID" \
  --scheme internet-facing \
  --type application \
  --ip-address-type ipv4 \
  --tags "Key=Name,Value=$ALB_NAME" "Key=Environment,Value=$ENVIRONMENT" \
  --query "LoadBalancers[0].LoadBalancerArn" \
  --output text)

# Wait until the ALB is active before creating the listener
log "Waiting for ALB to become active..."
aws elbv2 wait load-balancer-available \
  --region "$REGION" \
  --load-balancer-arns "$ALB_ARN"

log "ALB active: $ALB_ARN"

# =============================================================================
# 7. HTTP LISTENER (port 80 → forward to Target Group)
# =============================================================================
log "Creating HTTP listener on port 80..."

LISTENER_ARN=$(aws elbv2 create-listener \
  --region "$REGION" \
  --load-balancer-arn "$ALB_ARN" \
  --protocol HTTP \
  --port 80 \
  --default-actions "Type=forward,TargetGroupArn=$TG_ARN" \
  --query "Listeners[0].ListenerArn" \
  --output text)

log "Listener created: $LISTENER_ARN"

# =============================================================================
# 8. AUTO SCALING GROUP
#    Links the Launch Template and registers with the ALB Target Group.
# =============================================================================
log "Creating Auto Scaling Group: $ASG_NAME..."

# Build the subnet list as a comma-separated string (same format as ALB)
aws autoscaling create-auto-scaling-group \
  --region "$REGION" \
  --auto-scaling-group-name "$ASG_NAME" \
  --launch-template "LaunchTemplateId=$LT_ID,Version=\$Latest" \
  --min-size "$ASG_MIN" \
  --max-size "$ASG_MAX" \
  --desired-capacity "$ASG_DESIRED" \
  --target-group-arns "$TG_ARN" \
  --health-check-type "ELB" \
  --health-check-grace-period 120 \
  --vpc-zone-identifier "$SUBNET_CSV" \
  --tags \
    "Key=Name,Value=$APP_NAME-asg-instance,PropagateAtLaunch=true,ResourceId=$ASG_NAME,ResourceType=auto-scaling-group" \
    "Key=Environment,Value=$ENVIRONMENT,PropagateAtLaunch=true,ResourceId=$ASG_NAME,ResourceType=auto-scaling-group"

log "Auto Scaling Group created: $ASG_NAME"

# =============================================================================
# 9. SCALING POLICIES — Target Tracking on CPU utilisation
#    Scale OUT when average CPU > 60 %, scale IN when < 40 %
# =============================================================================
log "Attaching scale-out policy (CPU > ${SCALE_OUT_CPU}%)..."

SCALE_OUT_POLICY_ARN=$(aws autoscaling put-scaling-policy \
  --region "$REGION" \
  --auto-scaling-group-name "$ASG_NAME" \
  --policy-name "${ASG_NAME}-ScaleOut" \
  --policy-type "TargetTrackingScaling" \
  --target-tracking-configuration "{
    \"PredefinedMetricSpecification\": {
      \"PredefinedMetricType\": \"ASGAverageCPUUtilization\"
    },
    \"TargetValue\": $SCALE_OUT_CPU,
    \"DisableScaleIn\": true
  }" \
  --query "PolicyARN" \
  --output text)

log "Scale-out policy ARN: $SCALE_OUT_POLICY_ARN"

log "Attaching scale-in policy (CPU < ${SCALE_IN_CPU}%)..."

SCALE_IN_POLICY_ARN=$(aws autoscaling put-scaling-policy \
  --region "$REGION" \
  --auto-scaling-group-name "$ASG_NAME" \
  --policy-name "${ASG_NAME}-ScaleIn" \
  --policy-type "TargetTrackingScaling" \
  --target-tracking-configuration "{
    \"PredefinedMetricSpecification\": {
      \"PredefinedMetricType\": \"ASGAverageCPUUtilization\"
    },
    \"TargetValue\": $SCALE_IN_CPU,
    \"DisableScaleIn\": false
  }" \
  --query "PolicyARN" \
  --output text)

log "Scale-in policy ARN: $SCALE_IN_POLICY_ARN"

# =============================================================================
# 10. OUTPUT — Retrieve and print the ALB DNS name
# =============================================================================
ALB_DNS=$(aws elbv2 describe-load-balancers \
  --region "$REGION" \
  --load-balancer-arns "$ALB_ARN" \
  --query "LoadBalancers[0].DNSName" \
  --output text)

echo ""
echo "============================================================"
echo "  Deployment complete!"
echo "============================================================"
echo "  Region          : $REGION"
echo "  Security Group  : $SG_ID"
echo "  Launch Template : $LT_ID  ($LT_NAME)"
echo "  Target Group    : $TG_ARN"
echo "  ALB ARN         : $ALB_ARN"
echo "  ALB DNS         : http://$ALB_DNS"
echo "  ASG             : $ASG_NAME  (desired=$ASG_DESIRED, min=$ASG_MIN, max=$ASG_MAX)"
echo "============================================================"
echo ""
echo "  NOTE: Allow 2-3 minutes for instances to pass health checks"
echo "        before the ALB begins forwarding traffic."
echo ""
