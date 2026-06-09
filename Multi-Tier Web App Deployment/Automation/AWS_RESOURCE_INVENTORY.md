# AWS Resource Inventory - Multi-Tier Web App Deployment

**Generated:** June 9, 2026  
**Status:** DEPLOYMENT INCOMPLETE ⚠️  
**Region:** us-east-1

---

## 📊 Deployment Status Summary

| Component | Status | Count | Resource IDs |
|-----------|--------|-------|--------------|
| VPC | ✅ Active | 1 | vpc-0b4866766bf728184 |
| Public Subnets | ✅ Active | 2 | subnet-0b151b13b365f04ae, subnet-02ea822f5c3ee92b7 |
| Private Subnets | ✅ Active | 2 | subnet-08b35229d7f95d22f, subnet-0759bbc903d447ce3 |
| Internet Gateway | ✅ Active | 1 | igw-0ad77c9c663c0c376 |
| NAT Gateways | ✅ Active | 2 | nat-0b1b9884040ef525f, nat-0356ae06f8c341844 |
| ALB | ✅ Active | 1 | arn:aws:elasticloadbalancing:us-east-1:022499047467:loadbalancer/app/multitier-webapp-alb/c79e421ca2439822 |
| Target Group | ✅ Active | 1 | arn:aws:elasticloadbalancing:us-east-1:022499047467:targetgroup/app-20260609083540939900000002/fbe5b05c969bbad6 |
| Bastion Instance | ✅ Running | 1 | i-0e2318d36aa053bfc (t3.micro) |
| RDS Database | ⚠️ Modifying | 1 | multitier-webapp-mysql (db.t3.medium) |
| **Auto Scaling Group** | ❌ **MISSING** | 0 | multitier-webapp-asg |
| **Web Tier EC2 Instances** | ❌ **MISSING** | 0 | None |
| **Launch Template** | ❌ **MISSING** | 0 | None |
| **CloudWatch Alarms** | ❌ **MISSING** | 0 | None |
| Security Groups | ✅ Active | 5 | sg-038f779205f269ae9, sg-0bd01cf8d4a7175dc, sg-08c07dc0ea119991b, sg-0ae819e6a9840a033, sg-0c29fde7d93a94c59 |

---

## ✅ ACTIVE RESOURCES

### 1. VPC
```
VPC ID:           vpc-0b4866766bf728184
CIDR Block:       10.0.0.0/16
State:            available
DNS Hostnames:    Enabled
DNS Support:      Enabled
Tags:             
  - Name: multitier-webapp-vpc
  - Environment: production
  - Project: multitier-webapp
  - ManagedBy: terraform
```

### 2. Public Subnets (2x)

**Public Subnet A (AZ: us-east-1a)**
```
Subnet ID:          subnet-0b151b13b365f04ae
CIDR Block:         10.0.0.0/18
Availability Zone:  us-east-1a
State:              available
Map Public IP:      Yes
Available IPs:      16,377
Tags:
  - Name: multitier-webapp-public-subnet-1
```

**Public Subnet B (AZ: us-east-1b)**
```
Subnet ID:          subnet-02ea822f5c3ee92b7
CIDR Block:         10.0.64.0/18
Availability Zone:  us-east-1b
State:              available
Map Public IP:      Yes
Available IPs:      16,377
Tags:
  - Name: multitier-webapp-public-subnet-2
```

### 3. Private Subnets (2x)

**Private Subnet A (AZ: us-east-1a)**
```
Subnet ID:          subnet-08b35229d7f95d22f
CIDR Block:         10.0.128.0/18
Availability Zone:  us-east-1a
State:              available
Map Public IP:      No
Available IPs:      16,378
Tags:
  - Name: multitier-webapp-private-subnet-1
```

**Private Subnet B (AZ: us-east-1b)**
```
Subnet ID:          subnet-0759bbc903d447ce3
CIDR Block:         10.0.192.0/18
Availability Zone:  us-east-1b
State:              available
Map Public IP:      No
Available IPs:      16,378
Tags:
  - Name: multitier-webapp-private-subnet-2
```

### 4. Internet Gateway
```
IGW ID:     igw-0ad77c9c663c0c376
VPC ID:     vpc-0b4866766bf728184
State:      available
Attachment: Active
Tags:
  - Name: multitier-webapp-igw
  - Environment: production
  - Project: multitier-webapp
  - ManagedBy: terraform
```

### 5. NAT Gateways (2x)

**NAT Gateway 1 (AZ: us-east-1a)**
```
NAT GW ID:              nat-0b1b9884040ef525f
Public IP:              100.30.7.243
Allocation ID:          eipalloc-00542cd4e01fd8e35
Subnet:                 subnet-0b151b13b365f04ae
Private IP:             10.0.32.8
State:                  available
Network Interface:      eni-0273d8667e272100b
Tags:
  - Name: multitier-webapp-nat-1
```

**NAT Gateway 2 (AZ: us-east-1b)**
```
NAT GW ID:              nat-0356ae06f8c341844
Public IP:              13.219.168.206
Allocation ID:          eipalloc-0f27f666c7255c97b
Subnet:                 subnet-02ea822f5c3ee92b7
Private IP:             10.0.84.96
State:                  available
Network Interface:      eni-0c5323ce88646fc81
Tags:
  - Name: multitier-webapp-nat-2
```

### 6. Application Load Balancer
```
ALB ARN:        arn:aws:elasticloadbalancing:us-east-1:022499047467:loadbalancer/app/multitier-webapp-alb/c79e421ca2439822
Name:           multitier-webapp-alb
DNS Name:       multitier-webapp-alb-586845017.us-east-1.elb.amazonaws.com
State:          active
Scheme:         internet-facing
Type:           application
VPC:            vpc-0b4866766bf728184
Subnets:        subnet-0b151b13b365f04ae (AZ: us-east-1a)
                subnet-02ea822f5c3ee92b7 (AZ: us-east-1b)
Security Group: sg-038f779205f269ae9
IP Address Type: ipv4
Listeners:      Port 80 (HTTP) → Target Group
Created:        2026-06-09T08:35:56.840000+00:00
Tags:
  - Name: multitier-webapp-alb
  - Environment: production
  - Project: multitier-webapp
  - ManagedBy: terraform
```

### 7. Target Group
```
Target Group ARN:   arn:aws:elasticloadbalancing:us-east-1:022499047467:targetgroup/app-20260609083540939900000002/fbe5b05c969bbad6
Name:               app-20260609083540939900000002
VPC:                vpc-0b4866766bf728184
Protocol:           HTTP
Port:               80
Health Check:
  - Path:           /health
  - Protocol:       HTTP
  - Interval:       30 seconds
  - Timeout:        5 seconds
  - Healthy Count:  2 consecutive
  - Unhealthy Count: 3 consecutive
  - Matcher:        HTTP 200
Target Type:        instance
Protocol Version:   HTTP/1
IP Address Type:    ipv4
Status:             ⚠️ NO HEALTHY TARGETS (ASG not deployed)
Registered Targets: 0
Created:            2026-06-09T08:35:40.939900+00:00
Tags:
  - Name: multitier-webapp-tg
  - Environment: production
  - Project: multitier-webapp
  - ManagedBy: terraform
```

### 8. Bastion Host
```
Instance ID:        i-0e2318d36aa053bfc
Instance Type:      t3.micro
State:              running
Availability Zone:  us-east-1a
VPC:                vpc-0b4866766bf728184
Subnet:             subnet-0b151b13b365f04ae (public)
Private IP:         10.0.24.86
Public IP:          35.153.140.63
DNS Name:           ec2-35-153-140-63.compute-1.amazonaws.com
Key Pair:           WebApp-key-pair
Security Group:     sg-0ae819e6a9840a033 (multitier-webapp-bastion-sg)
IAM Role:           AmazonSSMManagedInstanceCore (attached)
Monitoring:         Basic (1-minute metrics)
EBS Root Volume:    vol-0b45d9bcbd3c00e64 (8 GB, gp2)
Network Interface:   eni-0de90296431b60042
Launched:           2026-06-09T08:35:55+00:00
Tags:
  - Name: multitier-webapp-bastion
  - Environment: production
  - Project: multitier-webapp
  - ManagedBy: terraform
Status Check:       ✅ Passing (2/2 checks)
```

### 9. RDS MySQL Database
```
DB Identifier:          multitier-webapp-mysql
Engine:                 MySQL 8.0.45
Instance Class:         db.t3.medium
Status:                 ⚠️ modifying (Multi-AZ being enabled)
Availability Zone:      us-east-1b
State Transition:       In progress
Multi-AZ:               false → true (modifying)
Allocated Storage:      20 GB
Storage Type:           gp2
Storage Encrypted:      ✅ Yes (AWS-managed KMS key)
Endpoint:               multitier-webapp-mysql.cy188y02caa5.us-east-1.rds.amazonaws.com
Port:                   3306
Master Username:        admin
Database Name:          appdb
Parameter Group:        default.mysql8.0 (in-sync)
Backup Retention:       7 days
Automated Backups:      ✅ Enabled
Copy Tags to Snapshot:  ✅ Yes
Preferred Backup Window: 03:00-04:00 UTC
Preferred Maintenance:  Sunday 04:00-05:00 UTC
Public Accessible:      ✅ No (Private only)
Deletion Protection:    ✅ Enabled
DB Subnet Group:        multitier-webapp-db-subnet-group
  - Subnets:
    - subnet-08b35229d7f95d22f (us-east-1a)
    - subnet-0759bbc903d447ce3 (us-east-1b)
VPC Security Group:     sg-08c07dc0ea119991b (allows port 3306 from Web tier)
CloudWatch Logs:        ✅ Enabled (error, general, slowquery)
Enhanced Monitoring:    ❌ Disabled
Performance Insights:   ❌ Disabled
IAM DB Authentication: ❌ Disabled
Database Insights Mode: standard
Network Type:          IPV4
Customer Owned IP:     ❌ Disabled
Backup Target:         region
Active Directory:      None
Monitoring Interval:    0 (no detailed monitoring)
Certificate:           rds-ca-rsa2048-g1 (valid until 2027-06-09)
Read Replicas:         None
Tags:
  - Name: multitier-webapp-mysql
  - Environment: production
  - Project: multitier-webapp
  - ManagedBy: terraform
Created:               2026-06-09T08:42:48.831000+00:00
```

### 10. Security Groups (5x)

**ALB Security Group**
```
SG ID:              sg-038f779205f269ae9
Name:               multitier-webapp-alb-sg
VPC:                vpc-0b4866766bf728184
Description:        Security group for Application Load Balancer
Inbound Rules:
  - Protocol: TCP, Port 80, Source: 0.0.0.0/0 (HTTP from anywhere)
  - Protocol: TCP, Port 443, Source: 0.0.0.0/0 (HTTPS from anywhere)
Outbound Rules:
  - Protocol: All (-1), Destination: 0.0.0.0/0 (all traffic allowed out)
Tags:
  - Name: multitier-webapp-alb-sg
  - Environment: production
  - Project: multitier-webapp
  - ManagedBy: terraform
```

**Web Tier Security Group**
```
SG ID:              sg-0bd01cf8d4a7175dc
Name:               multitier-webapp-web-app-sg
VPC:                vpc-0b4866766bf728184
Description:        Security group for Web/App EC2 instances
Inbound Rules:
  - Protocol: TCP, Port 80, Source: sg-038f779205f269ae9 (HTTP from ALB)
  - Protocol: TCP, Port 22, Source: sg-0ae819e6a9840a033 (SSH from Bastion)
Outbound Rules:
  - Protocol: All (-1), Destination: 0.0.0.0/0 (all traffic allowed out)
Tags:
  - Name: multitier-webapp-web-app-sg
  - Environment: production
  - Project: multitier-webapp
  - ManagedBy: terraform
Status:             ✅ Ready (but no instances)
```

**RDS Security Group**
```
SG ID:              sg-08c07dc0ea119991b
Name:               multitier-webapp-rds-sg
VPC:                vpc-0b4866766bf728184
Description:        Security group for RDS MySQL instance
Inbound Rules:
  - Protocol: TCP, Port 3306, Source: sg-0bd01cf8d4a7175dc (MySQL from Web tier)
Outbound Rules:
  - Protocol: All (-1), Destination: 0.0.0.0/0 (all traffic allowed out)
Tags:
  - Name: multitier-webapp-rds-sg
  - Environment: production
  - Project: multitier-webapp
  - ManagedBy: terraform
Status:             ✅ Configured (RDS ready)
```

**Bastion Security Group**
```
SG ID:              sg-0ae819e6a9840a033
Name:               multitier-webapp-bastion-sg
VPC:                vpc-0b4866766bf728184
Description:        Security group for Bastion Host
Inbound Rules:
  - Protocol: TCP, Port 22, Source: 0.0.0.0/0 (SSH from anywhere)
Outbound Rules:
  - Protocol: All (-1), Destination: 0.0.0.0/0 (all traffic allowed out)
Tags:
  - Name: multitier-webapp-bastion-sg
  - Environment: production
  - Project: multitier-webapp
  - ManagedBy: terraform
Status:             ✅ Active (Bastion running)
```

**Default VPC Security Group**
```
SG ID:              sg-0c29fde7d93a94c59
Name:               default
VPC:                vpc-0b4866766bf728184
Description:        default VPC security group
Inbound Rules:
  - Protocol: All (-1), Source: sg-0c29fde7d93a94c59 (self)
Outbound Rules:
  - Protocol: All (-1), Destination: 0.0.0.0/0 (all traffic allowed out)
Status:             ⓘ Default group (not used)
```

---

## ❌ MISSING COMPONENTS

### 1. Auto Scaling Group
```
Expected Name:      multitier-webapp-asg
Status:             NOT DEPLOYED ❌
Reason:             ASG resource not created by Terraform
Impact:             No web tier scaling capability
Required:           Create ASG with launch template
```

### 2. Launch Template
```
Expected Name:      multitier-webapp-lt
Status:             NOT DEPLOYED ❌
Reason:             Launch template not created
Impact:             Cannot launch EC2 instances
Required:           Create launch template with:
  - AMI: Amazon Linux 2 (latest)
  - Instance Type: t3.medium
  - Security Group: sg-0bd01cf8d4a7175dc
  - User Data: /var/www/html/index.html + httpd setup
```

### 3. Web Tier EC2 Instances
```
Expected Count:     2 (min 1, max 4, desired 2)
Current Count:      0
Status:             NOT DEPLOYED ❌
Reason:             ASG not created, so no instances launched
Impact:             No application servers
               Target group has no healthy targets
               ALB returning 502/503 errors
Required:           Create ASG to launch instances
```

### 4. CloudWatch Alarms
```
Expected Alarms:
  - CPU Utilization High (>60%)  - Trigger Scale Out
  - CPU Utilization Low (<40%)   - Trigger Scale In
  - Unhealthy Host Count         - Alert on target unhealthiness
  - RDS CPU Utilization          - Alert on database load

Current Status:     NONE CREATED ❌
Reason:             Alarms not created
Impact:             No automated scaling
               No alerts for performance issues
Required:           Create CloudWatch alarms and scaling policies
```

---

## ⚠️ DEPLOYMENT ISSUES

### Issue 1: Incomplete Deployment
**Status:** ⚠️ CRITICAL

The web tier (ASG, Launch Template, EC2 instances) is missing. The infrastructure is partially deployed:
- ✅ VPC, Networking, Security Groups created
- ✅ ALB and Target Group created
- ✅ RDS Database created
- ✅ Bastion for SSH access created
- ❌ **Web tier NOT created** (blocking traffic flow)
- ❌ **CloudWatch monitoring NOT created** (no alerts)

**Impact:** Application cannot receive traffic through ALB because no targets exist.

**Solution:** Run Terraform again or manually create:
1. Launch Template (multitier-webapp-lt)
2. Auto Scaling Group (multitier-webapp-asg) with 1-4 instances, min 1, desired 2
3. CloudWatch Alarms for scaling policies

---

### Issue 2: RDS in Modifying State
**Status:** ⚠️ IN PROGRESS

RDS is currently being modified to enable Multi-AZ:
```
Current Status:    modifying
Pending Changes:   MultiAZ: true
Estimated Time:    5-15 minutes
```

**Action:** Wait for this to complete before testing database connectivity.

---

### Issue 3: Target Group Has No Targets
**Status:** ⚠️ NO TRAFFIC

Target Group metrics show no registered targets:
- Healthy Hosts: 0
- Unhealthy Hosts: 0
- Total Targets: 0

**Impact:** ALB will return 502/503 errors for all requests.

---

## 🔍 Terraform Configuration Status

**Outputs Available:**
```
✅ vpc_id
✅ alb_dns_name
✅ alb_arn
✅ target_group_arn
✅ bastion_id
✅ bastion_public_ip
✅ rds_endpoint
✅ public_subnet_ids
✅ private_subnet_ids
✅ cloudwatch_log_group_name
✅ asg_min_size, asg_desired_capacity, asg_max_size
```

**Note:** Terraform outputs show desired values for ASG (min=1, desired=2, max=4) but ASG itself is not created.

---

## 📋 Quick Reference

### All Resource IDs

```bash
# VPC & Networking
VPC_ID=vpc-0b4866766bf728184
PUBLIC_SUBNET_1=subnet-0b151b13b365f04ae
PUBLIC_SUBNET_2=subnet-02ea822f5c3ee92b7
PRIVATE_SUBNET_1=subnet-08b35229d7f95d22f
PRIVATE_SUBNET_2=subnet-0759bbc903d447ce3
IGW_ID=igw-0ad77c9c663c0c376
NAT_1=nat-0b1b9884040ef525f
NAT_2=nat-0356ae06f8c341844

# Load Balancer
ALB_ARN=arn:aws:elasticloadbalancing:us-east-1:022499047467:loadbalancer/app/multitier-webapp-alb/c79e421ca2439822
ALB_DNS=multitier-webapp-alb-586845017.us-east-1.elb.amazonaws.com
TG_ARN=arn:aws:elasticloadbalancing:us-east-1:022499047467:targetgroup/app-20260609083540939900000002/fbe5b05c969bbad6

# EC2 Instances
BASTION_ID=i-0e2318d36aa053bfc
BASTION_IP=35.153.140.63

# RDS
RDS_ENDPOINT=multitier-webapp-mysql.cy188y02caa5.us-east-1.rds.amazonaws.com
RDS_ID=multitier-webapp-mysql
RDS_PORT=3306

# Security Groups
ALB_SG=sg-038f779205f269ae9
WEB_SG=sg-0bd01cf8d4a7175dc
RDS_SG=sg-08c07dc0ea119991b
BASTION_SG=sg-0ae819e6a9840a033

# Account & Region
ACCOUNT_ID=022499047467
REGION=us-east-1
```

---

## 🔗 AWS Console Links

- VPC: https://console.aws.amazon.com/vpc/home?region=us-east-1#vpcs:vpcId=vpc-0b4866766bf728184
- EC2: https://console.aws.amazon.com/ec2/v2/home?region=us-east-1
- RDS: https://console.aws.amazon.com/rds/home?region=us-east-1#databases:
- CloudWatch: https://console.aws.amazon.com/cloudwatch/home?region=us-east-1

---

**Last Updated:** June 9, 2026  
**Next Action:** Deploy web tier (ASG + Launch Template) to complete the stack.
