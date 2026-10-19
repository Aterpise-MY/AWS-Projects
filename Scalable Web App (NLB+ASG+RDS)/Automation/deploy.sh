#!/usr/bin/env bash
# deploy.sh — Manual AWS CLI deployment for the Scalable Web App with NLB & Auto Scaling.
# Run each section in order. Variables at the top must be set before running.
# Tested with AWS CLI v2.

set -euo pipefail

###############################################################################
# CONFIGURATION — edit these before running
###############################################################################
PROJECT_NAME="scalable-webapp"
ENVIRONMENT="prod"
REGION="us-east-1"
VPC_CIDR="10.0.0.0/16"
PUBLIC_SUBNET_1_CIDR="10.0.1.0/24"
PUBLIC_SUBNET_2_CIDR="10.0.2.0/24"
PRIVATE_SUBNET_1_CIDR="10.0.3.0/24"
PRIVATE_SUBNET_2_CIDR="10.0.4.0/24"
AZ_1="us-east-1a"
AZ_2="us-east-1b"
AMI_ID="ami-XXXXXXXXXXXXXXXXX"       # Replace: Amazon Linux 2023 or Ubuntu AMI for your region
INSTANCE_TYPE="t3.medium"
KEY_PAIR_NAME="your-key-pair"        # Replace: existing EC2 key pair name
ASG_MIN=2
ASG_MAX=6
ASG_DESIRED=2
CPU_HIGH_THRESHOLD=70
CPU_LOW_THRESHOLD=30
ALARM_EMAIL="your@email.com"         # Replace: receives CloudWatch alarm notifications
WEB_SERVER="nginx"                   # "nginx" or "apache"

###############################################################################
# SECTION 1 — Verify Credentials
###############################################################################
echo "==> Section 1: Verifying AWS credentials..."
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text --region "$REGION")
echo "    Account ID : $ACCOUNT_ID"
echo "    Identity   : $(aws sts get-caller-identity --query Arn --output text --region "$REGION")"

###############################################################################
# SECTION 2 — VPC & Networking
###############################################################################
echo "==> Section 2: Creating VPC and networking..."

VPC_ID=$(aws ec2 create-vpc \
  --cidr-block "$VPC_CIDR" \
  --region "$REGION" \
  --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=${PROJECT_NAME}-${ENVIRONMENT}-vpc},{Key=Project,Value=$PROJECT_NAME},{Key=Environment,Value=$ENVIRONMENT},{Key=ManagedBy,Value=cli}]" \
  --query 'Vpc.VpcId' --output text)
echo "    VPC ID: $VPC_ID"

aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames --region "$REGION"
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support --region "$REGION"

PUB_SUBNET_1=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" --cidr-block "$PUBLIC_SUBNET_1_CIDR" --availability-zone "$AZ_1" \
  --region "$REGION" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${PROJECT_NAME}-${ENVIRONMENT}-public-1}]" \
  --query 'Subnet.SubnetId' --output text)

PUB_SUBNET_2=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" --cidr-block "$PUBLIC_SUBNET_2_CIDR" --availability-zone "$AZ_2" \
  --region "$REGION" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${PROJECT_NAME}-${ENVIRONMENT}-public-2}]" \
  --query 'Subnet.SubnetId' --output text)

PRIV_SUBNET_1=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" --cidr-block "$PRIVATE_SUBNET_1_CIDR" --availability-zone "$AZ_1" \
  --region "$REGION" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${PROJECT_NAME}-${ENVIRONMENT}-private-1}]" \
  --query 'Subnet.SubnetId' --output text)

PRIV_SUBNET_2=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" --cidr-block "$PRIVATE_SUBNET_2_CIDR" --availability-zone "$AZ_2" \
  --region "$REGION" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${PROJECT_NAME}-${ENVIRONMENT}-private-2}]" \
  --query 'Subnet.SubnetId' --output text)

echo "    Public subnets : $PUB_SUBNET_1, $PUB_SUBNET_2"
echo "    Private subnets: $PRIV_SUBNET_1, $PRIV_SUBNET_2"

# Internet Gateway
IGW_ID=$(aws ec2 create-internet-gateway \
  --region "$REGION" \
  --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=${PROJECT_NAME}-${ENVIRONMENT}-igw}]" \
  --query 'InternetGateway.InternetGatewayId' --output text)
aws ec2 attach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" --region "$REGION"
echo "    Internet Gateway: $IGW_ID"

# Elastic IPs for NAT Gateways
EIP_1=$(aws ec2 allocate-address --domain vpc --region "$REGION" --query 'AllocationId' --output text)
EIP_2=$(aws ec2 allocate-address --domain vpc --region "$REGION" --query 'AllocationId' --output text)

# NAT Gateways (one per AZ)
NAT_GW_1=$(aws ec2 create-nat-gateway \
  --subnet-id "$PUB_SUBNET_1" --allocation-id "$EIP_1" \
  --region "$REGION" \
  --tag-specifications "ResourceType=natgateway,Tags=[{Key=Name,Value=${PROJECT_NAME}-${ENVIRONMENT}-nat-1}]" \
  --query 'NatGateway.NatGatewayId' --output text)

NAT_GW_2=$(aws ec2 create-nat-gateway \
  --subnet-id "$PUB_SUBNET_2" --allocation-id "$EIP_2" \
  --region "$REGION" \
  --tag-specifications "ResourceType=natgateway,Tags=[{Key=Name,Value=${PROJECT_NAME}-${ENVIRONMENT}-nat-2}]" \
  --query 'NatGateway.NatGatewayId' --output text)

echo "    Waiting for NAT Gateways to become available..."
aws ec2 wait nat-gateway-available --nat-gateway-ids "$NAT_GW_1" "$NAT_GW_2" --region "$REGION"
echo "    NAT Gateways: $NAT_GW_1, $NAT_GW_2"

# Route tables
PUB_RT=$(aws ec2 create-route-table --vpc-id "$VPC_ID" --region "$REGION" \
  --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${PROJECT_NAME}-${ENVIRONMENT}-public-rt}]" \
  --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route --route-table-id "$PUB_RT" --destination-cidr-block "0.0.0.0/0" \
  --gateway-id "$IGW_ID" --region "$REGION" > /dev/null
aws ec2 associate-route-table --route-table-id "$PUB_RT" --subnet-id "$PUB_SUBNET_1" --region "$REGION" > /dev/null
aws ec2 associate-route-table --route-table-id "$PUB_RT" --subnet-id "$PUB_SUBNET_2" --region "$REGION" > /dev/null

PRIV_RT_1=$(aws ec2 create-route-table --vpc-id "$VPC_ID" --region "$REGION" \
  --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${PROJECT_NAME}-${ENVIRONMENT}-private-rt-1}]" \
  --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route --route-table-id "$PRIV_RT_1" --destination-cidr-block "0.0.0.0/0" \
  --nat-gateway-id "$NAT_GW_1" --region "$REGION" > /dev/null
aws ec2 associate-route-table --route-table-id "$PRIV_RT_1" --subnet-id "$PRIV_SUBNET_1" --region "$REGION" > /dev/null

PRIV_RT_2=$(aws ec2 create-route-table --vpc-id "$VPC_ID" --region "$REGION" \
  --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${PROJECT_NAME}-${ENVIRONMENT}-private-rt-2}]" \
  --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route --route-table-id "$PRIV_RT_2" --destination-cidr-block "0.0.0.0/0" \
  --nat-gateway-id "$NAT_GW_2" --region "$REGION" > /dev/null
aws ec2 associate-route-table --route-table-id "$PRIV_RT_2" --subnet-id "$PRIV_SUBNET_2" --region "$REGION" > /dev/null

echo "    Route tables: $PUB_RT, $PRIV_RT_1, $PRIV_RT_2"
aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'Subnets[*].{ID:SubnetId,CIDR:CidrBlock,AZ:AvailabilityZone}' \
  --output table --region "$REGION"

###############################################################################
# SECTION 3 — Security Groups
###############################################################################
echo "==> Section 3: Creating security groups..."

NLB_SG=$(aws ec2 create-security-group \
  --group-name "${PROJECT_NAME}-${ENVIRONMENT}-nlb-sg" \
  --description "Allow HTTP/HTTPS from internet to NLB" \
  --vpc-id "$VPC_ID" --region "$REGION" \
  --query 'GroupId' --output text)

aws ec2 authorize-security-group-ingress --group-id "$NLB_SG" \
  --protocol tcp --port 80 --cidr "0.0.0.0/0" --region "$REGION" > /dev/null
aws ec2 authorize-security-group-ingress --group-id "$NLB_SG" \
  --protocol tcp --port 443 --cidr "0.0.0.0/0" --region "$REGION" > /dev/null

EC2_SG=$(aws ec2 create-security-group \
  --group-name "${PROJECT_NAME}-${ENVIRONMENT}-ec2-sg" \
  --description "Allow HTTP from NLB only" \
  --vpc-id "$VPC_ID" --region "$REGION" \
  --query 'GroupId' --output text)

aws ec2 authorize-security-group-ingress --group-id "$EC2_SG" \
  --protocol tcp --port 80 --source-group "$NLB_SG" --region "$REGION" > /dev/null

echo "    NLB SG: $NLB_SG"
echo "    EC2 SG: $EC2_SG"
aws ec2 describe-security-groups --group-ids "$NLB_SG" "$EC2_SG" \
  --query 'SecurityGroups[*].{ID:GroupId,Name:GroupName}' --output table --region "$REGION"

###############################################################################
# SECTION 4 — IAM Role & Instance Profile
###############################################################################
echo "==> Section 4: Creating IAM role and instance profile..."

TRUST_POLICY='{
  "Version":"2012-10-17",
  "Statement":[{
    "Effect":"Allow",
    "Principal":{"Service":"ec2.amazonaws.com"},
    "Action":"sts:AssumeRole"
  }]
}'

ROLE_ARN=$(aws iam create-role \
  --role-name "${PROJECT_NAME}-${ENVIRONMENT}-ec2-role" \
  --assume-role-policy-document "$TRUST_POLICY" \
  --query 'Role.Arn' --output text)

aws iam attach-role-policy \
  --role-name "${PROJECT_NAME}-${ENVIRONMENT}-ec2-role" \
  --policy-arn "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"

aws iam create-instance-profile \
  --instance-profile-name "${PROJECT_NAME}-${ENVIRONMENT}-ec2-profile" > /dev/null

aws iam add-role-to-instance-profile \
  --instance-profile-name "${PROJECT_NAME}-${ENVIRONMENT}-ec2-profile" \
  --role-name "${PROJECT_NAME}-${ENVIRONMENT}-ec2-role"

# Allow propagation
sleep 10

echo "    Role ARN: $ROLE_ARN"
aws iam get-instance-profile \
  --instance-profile-name "${PROJECT_NAME}-${ENVIRONMENT}-ec2-profile" \
  --query 'InstanceProfile.{Name:InstanceProfileName,Roles:Roles[*].RoleName}' --output table

###############################################################################
# SECTION 5 — Launch Template
###############################################################################
echo "==> Section 5: Creating launch template..."

# Write the user data script
USER_DATA_FILE=$(mktemp /tmp/userdata.XXXXXX.sh)

if [ "$WEB_SERVER" = "nginx" ]; then
cat > "$USER_DATA_FILE" <<'USERDATA'
#!/bin/bash
set -e
yum update -y 2>/dev/null || apt-get update -y
if command -v yum &>/dev/null; then
  yum install -y nginx
else
  apt-get install -y nginx
fi
systemctl enable nginx
systemctl start nginx
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id)
AZ=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/placement/availability-zone)
cat > /usr/share/nginx/html/index.html <<HTML
<!DOCTYPE html><html><head><title>Scalable Web App</title></head>
<body><h1>Scalable Web App</h1>
<p>Instance ID: $INSTANCE_ID</p><p>Availability Zone: $AZ</p>
<p>Web Server: Nginx</p></body></html>
HTML
systemctl restart nginx
USERDATA
else
cat > "$USER_DATA_FILE" <<'USERDATA'
#!/bin/bash
set -e
yum update -y 2>/dev/null || apt-get update -y
if command -v yum &>/dev/null; then
  yum install -y httpd
  systemctl enable httpd && systemctl start httpd
else
  apt-get install -y apache2
  systemctl enable apache2 && systemctl start apache2
fi
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id)
AZ=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/placement/availability-zone)
cat > /var/www/html/index.html <<HTML
<!DOCTYPE html><html><head><title>Scalable Web App</title></head>
<body><h1>Scalable Web App</h1>
<p>Instance ID: $INSTANCE_ID</p><p>Availability Zone: $AZ</p>
<p>Web Server: Apache</p></body></html>
HTML
if command -v yum &>/dev/null; then systemctl restart httpd; else systemctl restart apache2; fi
USERDATA
fi

USER_DATA_B64=$(base64 < "$USER_DATA_FILE")
rm -f "$USER_DATA_FILE"

INSTANCE_PROFILE_ARN="arn:aws:iam::${ACCOUNT_ID}:instance-profile/${PROJECT_NAME}-${ENVIRONMENT}-ec2-profile"

LT_ID=$(aws ec2 create-launch-template \
  --launch-template-name "${PROJECT_NAME}-${ENVIRONMENT}-lt" \
  --region "$REGION" \
  --launch-template-data "{
    \"ImageId\": \"$AMI_ID\",
    \"InstanceType\": \"$INSTANCE_TYPE\",
    \"KeyName\": \"$KEY_PAIR_NAME\",
    \"SecurityGroupIds\": [\"$EC2_SG\"],
    \"IamInstanceProfile\": {\"Arn\": \"$INSTANCE_PROFILE_ARN\"},
    \"UserData\": \"$USER_DATA_B64\",
    \"Monitoring\": {\"Enabled\": true},
    \"MetadataOptions\": {
      \"HttpEndpoint\": \"enabled\",
      \"HttpTokens\": \"required\",
      \"HttpPutResponseHopLimit\": 1
    },
    \"TagSpecifications\": [{
      \"ResourceType\": \"instance\",
      \"Tags\": [
        {\"Key\":\"Name\",\"Value\":\"${PROJECT_NAME}-${ENVIRONMENT}-web\"},
        {\"Key\":\"Project\",\"Value\":\"$PROJECT_NAME\"},
        {\"Key\":\"Environment\",\"Value\":\"$ENVIRONMENT\"},
        {\"Key\":\"ManagedBy\",\"Value\":\"cli\"}
      ]
    }]
  }" \
  --query 'LaunchTemplate.LaunchTemplateId' --output text)

echo "    Launch Template ID: $LT_ID"
aws ec2 describe-launch-templates --launch-template-ids "$LT_ID" \
  --query 'LaunchTemplates[*].{ID:LaunchTemplateId,Name:LaunchTemplateName,Version:LatestVersionNumber}' \
  --output table --region "$REGION"

###############################################################################
# SECTION 6 — NLB & Target Group
###############################################################################
echo "==> Section 6: Creating NLB, target group, and listener..."

NLB_OUTPUT=$(aws elbv2 create-load-balancer \
  --name "${PROJECT_NAME}-${ENVIRONMENT}-nlb" \
  --type network \
  --scheme internet-facing \
  --subnets "$PUB_SUBNET_1" "$PUB_SUBNET_2" \
  --region "$REGION" \
  --tags "Key=Project,Value=$PROJECT_NAME" "Key=Environment,Value=$ENVIRONMENT" "Key=ManagedBy,Value=cli")

NLB_ARN=$(echo "$NLB_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['LoadBalancers'][0]['LoadBalancerArn'])")
NLB_DNS=$(echo "$NLB_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['LoadBalancers'][0]['DNSName'])")

TG_ARN=$(aws elbv2 create-target-group \
  --name "${PROJECT_NAME}-${ENVIRONMENT}-tg" \
  --protocol TCP \
  --port 80 \
  --vpc-id "$VPC_ID" \
  --target-type instance \
  --health-check-protocol TCP \
  --health-check-port "80" \
  --health-check-interval-seconds 30 \
  --healthy-threshold-count 3 \
  --unhealthy-threshold-count 3 \
  --region "$REGION" \
  --query 'TargetGroups[0].TargetGroupArn' --output text)

aws elbv2 create-listener \
  --load-balancer-arn "$NLB_ARN" \
  --protocol TCP \
  --port 80 \
  --default-actions "Type=forward,TargetGroupArn=$TG_ARN" \
  --region "$REGION" > /dev/null

echo "    NLB ARN: $NLB_ARN"
echo "    NLB DNS: $NLB_DNS"
echo "    Target Group ARN: $TG_ARN"

###############################################################################
# SECTION 7 — Auto Scaling Group
###############################################################################
echo "==> Section 7: Creating Auto Scaling Group..."

aws autoscaling create-auto-scaling-group \
  --auto-scaling-group-name "${PROJECT_NAME}-${ENVIRONMENT}-asg" \
  --launch-template "LaunchTemplateId=$LT_ID,Version=\$Latest" \
  --min-size "$ASG_MIN" \
  --max-size "$ASG_MAX" \
  --desired-capacity "$ASG_DESIRED" \
  --vpc-zone-identifier "${PRIV_SUBNET_1},${PRIV_SUBNET_2}" \
  --target-group-arns "$TG_ARN" \
  --health-check-type ELB \
  --health-check-grace-period 300 \
  --tags "Key=Name,Value=${PROJECT_NAME}-${ENVIRONMENT}-web,PropagateAtLaunch=true" \
         "Key=Project,Value=${PROJECT_NAME},PropagateAtLaunch=true" \
         "Key=Environment,Value=${ENVIRONMENT},PropagateAtLaunch=true" \
         "Key=ManagedBy,Value=cli,PropagateAtLaunch=true" \
  --region "$REGION"

echo "    ASG created: ${PROJECT_NAME}-${ENVIRONMENT}-asg"
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "${PROJECT_NAME}-${ENVIRONMENT}-asg" \
  --query 'AutoScalingGroups[*].{Name:AutoScalingGroupName,Min:MinSize,Max:MaxSize,Desired:DesiredCapacity}' \
  --output table --region "$REGION"

###############################################################################
# SECTION 8 — Scaling Policies & CloudWatch Alarms
###############################################################################
echo "==> Section 8: Creating scaling policies and CloudWatch alarms..."

# SNS topic
SNS_ARN=$(aws sns create-topic --name "${PROJECT_NAME}-${ENVIRONMENT}-alarms" \
  --region "$REGION" --query 'TopicArn' --output text)
aws sns subscribe --topic-arn "$SNS_ARN" --protocol email \
  --notification-endpoint "$ALARM_EMAIL" --region "$REGION" > /dev/null
echo "    SNS Topic: $SNS_ARN"
echo "    *** Check $ALARM_EMAIL and confirm the subscription before alarms will fire ***"

SCALE_OUT_ARN=$(aws autoscaling put-scaling-policy \
  --auto-scaling-group-name "${PROJECT_NAME}-${ENVIRONMENT}-asg" \
  --policy-name "${PROJECT_NAME}-${ENVIRONMENT}-scale-out" \
  --adjustment-type ChangeInCapacity \
  --scaling-adjustment 1 \
  --cooldown 300 \
  --policy-type SimpleScaling \
  --region "$REGION" \
  --query 'PolicyARN' --output text)

SCALE_IN_ARN=$(aws autoscaling put-scaling-policy \
  --auto-scaling-group-name "${PROJECT_NAME}-${ENVIRONMENT}-asg" \
  --policy-name "${PROJECT_NAME}-${ENVIRONMENT}-scale-in" \
  --adjustment-type ChangeInCapacity \
  --scaling-adjustment -1 \
  --cooldown 300 \
  --policy-type SimpleScaling \
  --region "$REGION" \
  --query 'PolicyARN' --output text)

# High CPU alarm → scale out
aws cloudwatch put-metric-alarm \
  --alarm-name "${PROJECT_NAME}-${ENVIRONMENT}-cpu-high" \
  --alarm-description "Scale out when CPU > ${CPU_HIGH_THRESHOLD}% for 2 minutes" \
  --namespace "AWS/EC2" \
  --metric-name CPUUtilization \
  --statistic Average \
  --period 60 \
  --evaluation-periods 2 \
  --threshold "$CPU_HIGH_THRESHOLD" \
  --comparison-operator GreaterThanThreshold \
  --dimensions "Name=AutoScalingGroupName,Value=${PROJECT_NAME}-${ENVIRONMENT}-asg" \
  --alarm-actions "$SCALE_OUT_ARN" \
  --region "$REGION"

# Low CPU alarm → scale in
aws cloudwatch put-metric-alarm \
  --alarm-name "${PROJECT_NAME}-${ENVIRONMENT}-cpu-low" \
  --alarm-description "Scale in when CPU < ${CPU_LOW_THRESHOLD}% for 2 minutes" \
  --namespace "AWS/EC2" \
  --metric-name CPUUtilization \
  --statistic Average \
  --period 60 \
  --evaluation-periods 2 \
  --threshold "$CPU_LOW_THRESHOLD" \
  --comparison-operator LessThanThreshold \
  --dimensions "Name=AutoScalingGroupName,Value=${PROJECT_NAME}-${ENVIRONMENT}-asg" \
  --alarm-actions "$SCALE_IN_ARN" \
  --region "$REGION"

# Unhealthy host alarm → SNS
TG_SUFFIX=$(echo "$TG_ARN" | sed 's|.*:||' | sed 's|targetgroup/|targetgroup/|')
NLB_SUFFIX=$(echo "$NLB_ARN" | sed 's|.*:loadbalancer/||')

aws cloudwatch put-metric-alarm \
  --alarm-name "${PROJECT_NAME}-${ENVIRONMENT}-unhealthy-hosts" \
  --alarm-description "Alert when NLB has unhealthy targets" \
  --namespace "AWS/NetworkELB" \
  --metric-name UnHealthyHostCount \
  --statistic Maximum \
  --period 60 \
  --evaluation-periods 2 \
  --threshold 1 \
  --comparison-operator GreaterThanOrEqualToThreshold \
  --dimensions "Name=LoadBalancer,Value=$NLB_SUFFIX" "Name=TargetGroup,Value=$TG_SUFFIX" \
  --alarm-actions "$SNS_ARN" \
  --region "$REGION"

aws cloudwatch describe-alarms \
  --alarm-names "${PROJECT_NAME}-${ENVIRONMENT}-cpu-high" \
                "${PROJECT_NAME}-${ENVIRONMENT}-cpu-low" \
                "${PROJECT_NAME}-${ENVIRONMENT}-unhealthy-hosts" \
  --query 'MetricAlarms[*].{Name:AlarmName,State:StateValue,Threshold:Threshold}' \
  --output table --region "$REGION"

###############################################################################
# SECTION 9 — WAF (optional)
###############################################################################
echo "==> Section 9: Creating WAFv2 Web ACL..."

WAF_ACL_ID=$(aws wafv2 create-web-acl \
  --name "${PROJECT_NAME}-${ENVIRONMENT}-waf" \
  --scope REGIONAL \
  --region "$REGION" \
  --default-action '{"Allow":{}}' \
  --rules '[
    {
      "Name":"AWSManagedRulesCommonRuleSet",
      "Priority":1,
      "OverrideAction":{"None":{}},
      "Statement":{"ManagedRuleGroupStatement":{"VendorName":"AWS","Name":"AWSManagedRulesCommonRuleSet"}},
      "VisibilityConfig":{"SampledRequestsEnabled":true,"CloudWatchMetricsEnabled":true,"MetricName":"CommonRules"}
    },
    {
      "Name":"AWSManagedRulesKnownBadInputsRuleSet",
      "Priority":2,
      "OverrideAction":{"None":{}},
      "Statement":{"ManagedRuleGroupStatement":{"VendorName":"AWS","Name":"AWSManagedRulesKnownBadInputsRuleSet"}},
      "VisibilityConfig":{"SampledRequestsEnabled":true,"CloudWatchMetricsEnabled":true,"MetricName":"BadInputsRules"}
    }
  ]' \
  --visibility-config "SampledRequestsEnabled=true,CloudWatchMetricsEnabled=true,MetricName=${PROJECT_NAME}-waf" \
  --query 'Summary.Id' --output text)

WAF_ACL_ARN="arn:aws:wafv2:${REGION}:${ACCOUNT_ID}:regional/webacl/${PROJECT_NAME}-${ENVIRONMENT}-waf/${WAF_ACL_ID}"

aws wafv2 associate-web-acl \
  --web-acl-arn "$WAF_ACL_ARN" \
  --resource-arn "$NLB_ARN" \
  --region "$REGION"

aws wafv2 list-web-acls --scope REGIONAL --region "$REGION" \
  --query 'WebACLs[*].{Name:Name,ID:Id}' --output table

###############################################################################
# SUMMARY
###############################################################################
echo ""
echo "============================================================"
echo " Deployment Complete!"
echo "============================================================"
echo " NLB DNS Name : $NLB_DNS"
echo " Test command : curl http://$NLB_DNS"
echo " Load test    : ab -n 10000 -c 100 http://$NLB_DNS/"
echo ""
echo " Watch ASG scaling:"
echo "   aws autoscaling describe-auto-scaling-groups \\"
echo "     --auto-scaling-group-names ${PROJECT_NAME}-${ENVIRONMENT}-asg \\"
echo "     --query 'AutoScalingGroups[*].Instances[*].InstanceId' \\"
echo "     --region $REGION"
echo "============================================================"

###############################################################################
# CLEANUP — run this section to tear down ALL resources (reverse order)
###############################################################################
# Uncomment and run ONLY when you want to destroy the environment.
#
# echo "==> Cleanup: Tearing down resources..."
#
# # WAF
# aws wafv2 disassociate-web-acl --resource-arn "$NLB_ARN" --region "$REGION"
# aws wafv2 delete-web-acl --name "${PROJECT_NAME}-${ENVIRONMENT}-waf" \
#   --scope REGIONAL --id "$WAF_ACL_ID" \
#   --lock-token "$(aws wafv2 get-web-acl --name "${PROJECT_NAME}-${ENVIRONMENT}-waf" \
#     --scope REGIONAL --id "$WAF_ACL_ID" --region "$REGION" --query 'LockToken' --output text)" \
#   --region "$REGION"
#
# # CloudWatch alarms
# aws cloudwatch delete-alarms \
#   --alarm-names "${PROJECT_NAME}-${ENVIRONMENT}-cpu-high" \
#                 "${PROJECT_NAME}-${ENVIRONMENT}-cpu-low" \
#                 "${PROJECT_NAME}-${ENVIRONMENT}-unhealthy-hosts" \
#   --region "$REGION"
#
# # Scaling policies (deleted with ASG, but explicit for clarity)
# aws autoscaling delete-policy --auto-scaling-group-name "${PROJECT_NAME}-${ENVIRONMENT}-asg" \
#   --policy-name "${PROJECT_NAME}-${ENVIRONMENT}-scale-out" --region "$REGION"
# aws autoscaling delete-policy --auto-scaling-group-name "${PROJECT_NAME}-${ENVIRONMENT}-asg" \
#   --policy-name "${PROJECT_NAME}-${ENVIRONMENT}-scale-in" --region "$REGION"
#
# # ASG (set to 0 first to terminate instances, then delete)
# aws autoscaling update-auto-scaling-group \
#   --auto-scaling-group-name "${PROJECT_NAME}-${ENVIRONMENT}-asg" \
#   --min-size 0 --max-size 0 --desired-capacity 0 --region "$REGION"
# echo "Waiting for instances to terminate..."
# sleep 60
# aws autoscaling delete-auto-scaling-group \
#   --auto-scaling-group-name "${PROJECT_NAME}-${ENVIRONMENT}-asg" \
#   --force-delete --region "$REGION"
#
# # NLB listener, target group, and NLB
# LISTENER_ARN=$(aws elbv2 describe-listeners --load-balancer-arn "$NLB_ARN" \
#   --query 'Listeners[0].ListenerArn' --output text --region "$REGION")
# aws elbv2 delete-listener --listener-arn "$LISTENER_ARN" --region "$REGION"
# aws elbv2 delete-target-group --target-group-arn "$TG_ARN" --region "$REGION"
# aws elbv2 delete-load-balancer --load-balancer-arn "$NLB_ARN" --region "$REGION"
# echo "Waiting for NLB deletion..."
# aws elbv2 wait load-balancers-deleted --load-balancer-arns "$NLB_ARN" --region "$REGION"
#
# # Launch template
# aws ec2 delete-launch-template --launch-template-id "$LT_ID" --region "$REGION"
#
# # NAT Gateways
# aws ec2 delete-nat-gateway --nat-gateway-id "$NAT_GW_1" --region "$REGION"
# aws ec2 delete-nat-gateway --nat-gateway-id "$NAT_GW_2" --region "$REGION"
# echo "Waiting for NAT Gateway deletion (this takes 1-2 minutes)..."
# sleep 90
#
# # Release Elastic IPs
# aws ec2 release-address --allocation-id "$EIP_1" --region "$REGION"
# aws ec2 release-address --allocation-id "$EIP_2" --region "$REGION"
#
# # Detach and delete IGW
# aws ec2 detach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" --region "$REGION"
# aws ec2 delete-internet-gateway --internet-gateway-id "$IGW_ID" --region "$REGION"
#
# # Delete subnets
# for subnet in "$PUB_SUBNET_1" "$PUB_SUBNET_2" "$PRIV_SUBNET_1" "$PRIV_SUBNET_2"; do
#   aws ec2 delete-subnet --subnet-id "$subnet" --region "$REGION"
# done
#
# # Delete route tables
# for rt in "$PUB_RT" "$PRIV_RT_1" "$PRIV_RT_2"; do
#   aws ec2 delete-route-table --route-table-id "$rt" --region "$REGION"
# done
#
# # Delete security groups
# aws ec2 delete-security-group --group-id "$EC2_SG" --region "$REGION"
# aws ec2 delete-security-group --group-id "$NLB_SG" --region "$REGION"
#
# # Delete VPC
# aws ec2 delete-vpc --vpc-id "$VPC_ID" --region "$REGION"
#
# # IAM cleanup
# aws iam remove-role-from-instance-profile \
#   --instance-profile-name "${PROJECT_NAME}-${ENVIRONMENT}-ec2-profile" \
#   --role-name "${PROJECT_NAME}-${ENVIRONMENT}-ec2-role"
# aws iam delete-instance-profile --instance-profile-name "${PROJECT_NAME}-${ENVIRONMENT}-ec2-profile"
# aws iam detach-role-policy --role-name "${PROJECT_NAME}-${ENVIRONMENT}-ec2-role" \
#   --policy-arn "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
# aws iam delete-role --role-name "${PROJECT_NAME}-${ENVIRONMENT}-ec2-role"
#
# # SNS topic
# aws sns delete-topic --topic-arn "$SNS_ARN" --region "$REGION"
#
# echo "==> Cleanup complete."
