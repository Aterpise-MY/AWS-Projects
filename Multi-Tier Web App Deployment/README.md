# Multi-Tier Web Application Deployment on AWS

A production-ready Infrastructure as Code solution for deploying a scalable, highly available multi-tier web application on AWS. This project includes a VPC with public and private subnets across 2 AZs, an Application Load Balancer routing traffic to web servers in an Auto Scaling Group, a Bastion Host for secure SSH access, and a Multi-AZ RDS MySQL database. Traffic automatically scales based on CPU utilization with CloudWatch monitoring.

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Networking & Routing](#networking--routing)
3. [Component Details](#component-details)
4. [Directory Structure](#directory-structure)
5. [Prerequisites](#prerequisites)
6. [Quick Start](#quick-start)
7. [Input Variables](#input-variables)
8. [Outputs](#outputs)
9. [Scaling Behaviour](#scaling-behaviour)
10. [Tagging Strategy](#tagging-strategy)
11. [Security Considerations](#security-considerations)
12. [Cost Estimate](#cost-estimate)
13. [Destroying the Stack](#destroying-the-stack)
14. [Frequently Asked Questions](#frequently-asked-questions)

## Architecture Overview

```
                           Internet
                              │
                              ▼
                    ┌─────────────────────┐
                    │   Internet Gateway  │
                    └─────────┬───────────┘
                              │
                    ┌─────────▼───────────┐
                    │   ALB (Public)      │ ← SecurityGroup: 80, 443 from 0.0.0.0/0
                    │  (Multi-AZ: AZ1&2)  │
                    └────┬──────────┬─────┘
                         │          │
        Public Subnet A  │          │    Public Subnet B
        (10.0.1.0/24)    │          │    (10.0.2.0/24)
                         │          │
              ┌───────────▼┐        ┌▼──────────┐
              │ NAT GW 1   │        │  NAT GW 2 │
              └───────────┬┘        └┬──────────┘
                          │          │
       Private Subnet A   │          │    Private Subnet B
       (10.0.3.0/24)      │          │    (10.0.4.0/24)
              ┌───────────▼┐        ┌▼──────────┐
              │   ASG (2)  │        │   ASG (2) │ ← EC2 t3.medium, httpd
              │ Web Tier   │        │ Web Tier  │    SecurityGroup: 80 from ALB,
              └───────────┬┘        └┬──────────┘    22 from Bastion
                          │          │
              ┌───────────▼──────────▼──────┐
              │   RDS MySQL 8.0             │
              │   Multi-AZ Primary+Standby  │
              │   (db.t3.medium)            │
              │   SecurityGroup: 3306       │
              │   from Web Tier only        │
              └─────────────────────────────┘

             Bastion Host: 10.0.1.X (Public)
             SecurityGroup: 22 from 0.0.0.0/0
```

**Traffic flow:** Internet requests arrive at the ALB (public subnets AZ1 & AZ2) on port 80. The ALB distributes traffic across EC2 instances in private subnets (running httpd) via target group health checks. Web tier instances communicate with the RDS MySQL database (private, Multi-AZ) for application data. The Bastion Host (public subnet) provides secure SSH access to private instances. NAT Gateways enable outbound internet access from private subnets. CloudWatch monitors CPU utilization and triggers Auto Scaling policies to adjust instance count (1–4) based on demand.

## Networking & Routing

### VPC Configuration

| Component           | CIDR Block   | DNS Hostnames | DNS Support |
|-------------------|--------------|---------------|-------------|
| VPC               | 10.0.0.0/16  | ✓ Enabled     | ✓ Enabled   |

### Subnets

| Subnet Name          | CIDR Block   | AZ  | Type    | Map Public IP |
|----------------------|--------------|-----|---------|---------------|
| Public Subnet A      | 10.0.1.0/24  | AZ1 | Public  | ✓ Yes         |
| Public Subnet B      | 10.0.2.0/24  | AZ2 | Public  | ✓ Yes         |
| Private Subnet A     | 10.0.3.0/24  | AZ1 | Private | ✗ No          |
| Private Subnet B     | 10.0.4.0/24  | AZ2 | Private | ✗ No          |

### Route Tables

| Route Table Name | Routes                      | Associated Subnets      |
|------------------|-----------------------------|-----------------------|
| Public RT        | 0.0.0.0/0 → IGW             | Public A, Public B      |
| Private RT 1     | 0.0.0.0/0 → NAT GW (AZ1)    | Private A               |
| Private RT 2     | 0.0.0.0/0 → NAT GW (AZ2)    | Private B               |

### Traffic Flow Diagram

```
    Internet
       │
       ▼ (HTTP 80)
    ┌──────────────┐
    │   IGW        │
    └──────┬───────┘
           │ 10.0.0.0/16
           ▼
    ┌──────────────────┐
    │  ALB (Public)    │
    │  Listener: 80    │
    └──┬───────────┬───┘
       │           │ Health Check /health (30s)
    Subnet A    Subnet B
       │           │
       ▼ (Target:80)▼
    ┌──────────┐ ┌──────────┐
    │  EC2 i1  │ │  EC2 i2  │ NAT GW outbound
    └──────┬───┘ └────┬─────┘
           │          │
           └────┬─────┘ CIDR: 0.0.0.0/0
                ▼ (Port 3306 MySQL)
         ┌──────────────────┐
         │  RDS MySQL       │
         │  Multi-AZ        │
         │  (Primary+Standby)
         └──────────────────┘
```

## Component Details

### 1. Security Groups

| Name | Port | Protocol | Source/Destination | Purpose |
|------|------|----------|------------------|---------|
| **ALB-SG** | 80 | TCP | 0.0.0.0/0 | Accept HTTP from internet |
| **ALB-SG** | 443 | TCP | 0.0.0.0/0 | Accept HTTPS from internet (reserved) |
| **ALB-SG** | All | All | 0.0.0.0/0 | Outbound to anywhere |
| **Bastion-SG** | 22 | TCP | var.allowed_ssh_cidr | SSH access (default: 0.0.0.0/0) |
| **Bastion-SG** | All | All | 0.0.0.0/0 | Outbound to anywhere |
| **WebApp-SG** | 80 | TCP | ALB-SG | Accept HTTP from ALB only |
| **WebApp-SG** | 22 | TCP | Bastion-SG | SSH from Bastion only |
| **WebApp-SG** | All | All | 0.0.0.0/0 | Outbound to anywhere |
| **RDS-SG** | 3306 | TCP | WebApp-SG | MySQL from Web tier only |

### 2. Launch Template / Task Definition

| Attribute | Value | Notes |
|-----------|-------|-------|
| AMI | Amazon Linux 2 (Latest) | Retrieved dynamically via data source |
| Instance Type | t3.medium | Configurable via `var.instance_type` |
| Key Name | var.key_pair_name | Required; must exist in region |
| Security Groups | WebApp-SG | Restricts to ALB on 80, Bastion on 22 |
| IAM Instance Profile | EC2-Role | AmazonSSMManagedInstanceCore attached |
| Detailed Monitoring | ✓ Enabled | CloudWatch 1-minute metrics |
| User Data | /var/www/html/index.html + health endpoint | Yum update, install httpd/mysql, systemctl enable httpd |
| EBS Volume | Root: 8GB gp2 (default) | Can be customized in launch template |

### 3. Application Load Balancer

| Attribute | Value | Notes |
|-----------|-------|-------|
| Name | {project_name}-alb | E.g., multitier-webapp-alb |
| Scheme | Internet-facing | Publicly accessible |
| Type | Application (Layer 7) | HTTP/HTTPS capable |
| Subnets | Public A, Public B | Multi-AZ for HA |
| Security Groups | ALB-SG | Ports 80, 443 |
| Listener (Port 80) | Forward → TG | Distributes to target instances |
| Listener (Port 443) | Reserved for future HTTPS | Add via `aws elbv2 create-listener` |

### 4. Target Group

| Attribute | Value | Notes |
|-----------|-------|-------|
| Name | {project_name}-tg | Auto-generated suffix for uniqueness |
| Protocol | HTTP | Port 80 |
| Target Type | Instance | Direct EC2 instance targeting |
| VPC | Main VPC (10.0.0.0/16) | Created in the VPC |
| Health Check Path | /health | Returns 200 OK |
| Health Check Interval | 30 seconds | Evaluation period for status |
| Healthy Threshold | 2 | Consecutive checks required |
| Unhealthy Threshold | 3 | Consecutive checks to mark unhealthy |
| Timeout | 5 seconds | Must respond within 5s |
| Matcher | 200 | Only HTTP 200 is considered healthy |

> **Production Note:** Ensure `/health` endpoint is lightweight and fast (no database calls) to avoid false failures.

### 5. Auto Scaling Group

| Attribute | Value | Notes |
|-----------|-------|-------|
| Name | {project_name}-asg | E.g., multitier-webapp-asg |
| Launch Template | {project_name}-lt | Latest version always used |
| Min Size | var.asg_min (default: 1) | Minimum instances at rest |
| Max Size | var.asg_max (default: 4) | Hard cap on instance count |
| Desired Capacity | var.asg_desired (default: 2) | Target instance count |
| Availability Zones | AZ1, AZ2 | Spans both AZs for HA |
| Subnets | Private A, Private B | Non-routable from internet |
| Target Group | {project_name}-tg | Registers instances automatically |
| Health Check Type | ELB | Uses ALB health checks |
| Health Check Grace Period | 300 seconds (5 min) | Time before first health check |
| Termination Policy | Default (OldestLaunchTemplate) | First-launched instances replaced first |

### 6. Scaling Policies & CloudWatch Alarms

| Metric | Type | Threshold | Cooldown | Action | Notes |
|--------|------|-----------|----------|--------|-------|
| CPU High | Target Tracking | >60% | 300s | Scale Out (+1) | 2-minute evaluation; 60s period |
| CPU Low | Target Tracking | <40% | 300s | Scale In (−1) | 5-minute evaluation; 300s period |
| ALB Unhealthy Hosts | Alarm | >0 for 2 checks | — | Alert | Monitor target group health |
| RDS CPU | Alarm | >80% for 2 periods | — | Alert | Database performance degradation |

> **Dead-Band Explanation:** The gap between scale-out (60%) and scale-in (40%) thresholds prevents rapid oscillation (flapping). With a 300-second cooldown, the system waits 5 minutes after each scaling event before attempting another.

## Directory Structure

```
Multi-Tier Web App Deployment/
├── provider.tf               # AWS provider config, remote state stub (commented)
├── variables.tf              # All input variables with descriptions & defaults
├── main.tf                   # All resource definitions (VPC, SG, ALB, RDS, ASG, etc.)
├── outputs.tf                # Output values (ALB DNS, RDS endpoint, etc.)
├── terraform.tfvars          # Sample variable values (customize before deploy)
├── user_data.sh              # EC2 user data script (httpd setup, index.html)
├── deploy.sh                 # AWS CLI bash deployment script (alternative to Terraform)
├── README.md                 # This file
└── .gitignore                # Terraform artifacts (terraform/, .tfstate*, etc.)
```

## Prerequisites

| Tool | Minimum Version | Install |
|------|-----------------|---------|
| Terraform | 1.0 | https://www.terraform.io/downloads.html |
| AWS CLI | 2.0 | https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html |
| Bash | 4.0 | Pre-installed on macOS, Linux |
| AWS Account | — | https://aws.amazon.com |

**Account-Level Requirements:**
- An active AWS account with sufficient IAM permissions (EC2, RDS, ELB, Auto Scaling, VPC, IAM, CloudWatch)
- An existing EC2 Key Pair in the target region (e.g., `your-key-pair-name`)
- Sufficient EC2 quota for 1 Bastion + 2–4 Web instances (default: 3 running)

**Optional:**
- VPC with custom CIDR (default: 10.0.0.0/16)
- Custom RDS password (must be 8+ characters, mixed case + numbers + special chars)

## Quick Start

### Option 1: Terraform (Recommended)

1. **Clone/navigate to project directory:**
   ```bash
   cd /Users/brendonang/Code/AWS\ Project/Multi-Tier\ Web\ App\ Deployment
   ```

2. **Customize variables:**
   ```bash
   # Edit terraform.tfvars
   # At minimum, set:
   # - key_pair_name = "your-existing-key-pair"
   # - db_password = "YourSecurePassword123!@#"
   # - allowed_ssh_cidr = "YOUR_IP/32"  (recommended for production)
   ```

3. **Initialize Terraform:**
   ```bash
   terraform init
   ```

4. **Review planned changes:**
   ```bash
   terraform plan
   ```

5. **Apply configuration:**
   ```bash
   terraform apply
   ```

6. **View outputs:**
   ```bash
   terraform output
   # or
   terraform output -json | jq .
   ```

**Allow 5–10 minutes for health checks and instance registration.**

### Option 2: AWS CLI Bash Script

1. **Customize variables in deploy.sh:**
   ```bash
   # Edit the CONFIGURATION section at the top of deploy.sh
   KEY_PAIR_NAME="your-key-pair-name"
   DB_PASSWORD="YourSecurePassword123!@#"
   ALLOWED_SSH_CIDR="0.0.0.0/0"  # or your IP/32
   ```

2. **Make script executable and run:**
   ```bash
   chmod +x deploy.sh
   ./deploy.sh
   ```

3. **Script will output:**
   - VPC ID, Subnet IDs
   - ALB DNS name (for HTTP access)
   - Bastion public IP (for SSH access)
   - RDS endpoint and connection details
   - ASG name and current instance count

**Allow 10–15 minutes for RDS Multi-AZ setup and health checks.**

## Input Variables

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `region` | string | `us-east-1` | AWS region for all resources |
| `project_name` | string | `multitier-webapp` | Project name (used in all resource names) |
| `environment` | string | `production` | Environment tag (e.g., production, staging) |
| `vpc_cidr` | string | `10.0.0.0/16` | VPC CIDR block |
| `key_pair_name` | string | — | **Required.** Existing EC2 Key Pair name |
| `allowed_ssh_cidr` | string | `0.0.0.0/0` | CIDR allowed for SSH (⚠️ restrict in production) |
| `instance_type` | string | `t3.medium` | EC2 instance type for web tier |
| `bastion_instance_type` | string | `t3.micro` | EC2 instance type for bastion |
| `db_username` | string | `admin` | RDS master username |
| `db_password` | string | — | **Required.** RDS master password (sensitive) |
| `db_instance_class` | string | `db.t3.medium` | RDS instance class |
| `db_allocated_storage` | number | `20` | RDS storage size (GB) |
| `asg_min` | number | `1` | Minimum ASG instances |
| `asg_max` | number | `4` | Maximum ASG instances |
| `asg_desired` | number | `2` | Desired ASG instances at launch |
| `cpu_scale_out_threshold` | number | `60` | CPU % to scale out (add instance) |
| `cpu_scale_in_threshold` | number | `40` | CPU % to scale in (remove instance) |

**Cross-Variable Validation:**
- `key_pair_name` and `db_password` are required; deployment will fail if omitted.
- `asg_min` ≤ `asg_desired` ≤ `asg_max` (enforced by ASG logic).
- `cpu_scale_in_threshold` < `cpu_scale_out_threshold` (recommended: 40% < 60%).

## Outputs

| Output | Description | Example |
|--------|-------------|---------|
| `vpc_id` | VPC resource ID | `vpc-0a1b2c3d4e5f6g7h8` |
| `alb_dns_name` | ALB public DNS name | `multitier-webapp-alb-1234567890.us-east-1.elb.amazonaws.com` |
| `alb_arn` | ALB ARN | `arn:aws:elasticloadbalancing:...` |
| `bastion_public_ip` | Bastion Host public IP | `203.0.113.45` |
| `bastion_id` | Bastion Instance ID | `i-0a1b2c3d4e5f6g7h8` |
| `asg_name` | Auto Scaling Group name | `multitier-webapp-asg` |
| `rds_endpoint` | RDS connection endpoint | `multitier-webapp-mysql.c1a2b3c4d5e6.us-east-1.rds.amazonaws.com:3306` |
| `target_group_arn` | ALB Target Group ARN | `arn:aws:elasticloadbalancing:...` |
| `public_subnet_ids` | List of public subnet IDs | `["subnet-xxx", "subnet-yyy"]` |
| `private_subnet_ids` | List of private subnet IDs | `["subnet-zzz", "subnet-www"]` |
| `cloudwatch_log_group_name` | CloudWatch log group for app logs | `/aws/ec2/multitier-webapp` |

**Usage (Terraform):**
```bash
# View all outputs
terraform output

# View specific output
terraform output alb_dns_name

# Export to JSON for scripting
terraform output -json > outputs.json
```

## Scaling Behaviour

```
Instance Count
      4 │                    ┌──────────── Max (4)
        │                   /│\
      3 │                  / │ \
        │                 /  │  \
      2 │────────────────/   │   \──────────────── Desired (2)
        │                    │
      1 │───────────────────────────────────────── Min (1)
        └────────────────────────────────────────
          0h  2h  4h  6h  8h 10h 12h 14h 16h Time

CPU Threshold (Utilization %)
     100 │                                        ▲ Real CPU
        │                        ╭─────────────╮  │
      60 │───────────────────────╯   Scale Out │  ├─ Scaling
        │                        ╭─ Target 60% │  │ Thresholds
      40 │───────╮ Scale In     │             │  │
        │        ╰─ Target 40%  ╰─────────────╯  ▼
        │        
        └────────────────────────────────────────
          0h  2h  4h  6h  8h 10h 12h 14h 16h Time

Dead-Band: 40%–60% CPU. System rests in this range for 5 minutes (cooldown)
before scaling again, preventing flapping (rapid up/down cycles).

Evaluation Periods:
  - Scale Out: 2 × 60s = 2 minutes average
  - Scale In: 2 × 300s = 10 minutes average (longer to avoid churn)

Step Size: Always ±1 instance per scaling event (gradual, stable growth).
```

## Tagging Strategy

All resources are tagged for cost allocation, automation, and compliance:

| Tag Key | Value | Resource Scope | Purpose |
|---------|-------|----------------|---------|
| `Name` | Descriptive name | All | Identify resource in console |
| `Environment` | `production`, `staging`, `dev` | All | Environment segregation |
| `Project` | `multitier-webapp` | All | Cost center / project billing |
| `ManagedBy` | `terraform` or `awscli` | All | Track infrastructure-as-code tool |

**Tag Propagation (EC2 ASG → Instances):**
- Tags defined in `tag_specifications` of the launch template automatically apply to all instances launched by the ASG.
- RDS snapshots inherit tags from the parent DB instance.

## Security Considerations

| Topic | Current Posture | Recommended Hardening |
|-------|-----------------|----------------------|
| **SSH Access** | Open to 0.0.0.0/0 (bastion) | Restrict `allowed_ssh_cidr` to your IP/32 (e.g., `203.0.113.45/32`) |
| **RDS Public Access** | Not publicly accessible | ✓ Already private; good |
| **RDS Encryption** | Enabled (KMS default AWS-managed key) | ✓ Enabled; optionally use customer-managed CMK |
| **RDS Password Storage** | Plain text in Terraform state | Use `terraform state` encryption (remote S3 + DynamoDB) or AWS Secrets Manager |
| **Database Backup** | 7-day retention; automated snapshots | ✓ Configured; increase to 30+ days if required |
| **ALB HTTPS** | Not configured | Add HTTPS listener + ACM certificate; redirect HTTP→HTTPS |
| **Web App Secrets** | None in user data | Use Systems Manager Parameter Store or AWS Secrets Manager |
| **IAM Instance Role** | EC2 instances have `AmazonSSMManagedInstanceCore` | ✓ Allows EC2 Instance Connect (session-based SSH, no key required) |
| **VPC Flow Logs** | Not enabled | Optional: enable to monitor traffic patterns & detect anomalies |
| **Security Group Ingress** | Restrictive (ALB→Web, Bastion→Web, Web→RDS) | ✓ Good; follow least-privilege principle |

## Cost Estimate

**Estimated monthly costs (USD) in us-east-1:**

| Resource | Quantity | Monthly Cost (USD) | Notes |
|----------|----------|-------------------|-------|
| EC2 t3.micro (Bastion) | 1 | $5.83 | On-demand, 1 month = ~730 hours |
| EC2 t3.medium (Web/ASG) | 2–4 | $35–70 | On-demand; avg 2.5 instances |
| Application Load Balancer | 1 | $15 | Fixed hourly charge + data processing |
| ALB Data Processing | ~50 GB/month | $5 | Typical small-to-medium traffic |
| NAT Gateway | 2 | $32 | $16 per gateway + data processing |
| RDS db.t3.medium (Multi-AZ) | 1 | $70 | Multi-AZ doubles cost; ~$140 actual |
| RDS Storage | 20 GB | $2.30 | GP2 storage; automated backups included |
| RDS Data Transfer | ~5 GB/month | $0.50 | Outbound traffic (minimal internal) |
| CloudWatch Logs | ~10 GB/month | $5 | ALB, RDS, application logs retention |
| CloudWatch Alarms | 2 | $0.10 | CPU high/low alarms |
| **Total (estimated)** | — | **~$165–200/month** | Includes 2–4 instances, Multi-AZ RDS |

**Cost Optimization Tips:**
- Use **Reserved Instances** for 1-year or 3-year terms (30–40% savings on EC2).
- **Reserved Capacity Reservations** for RDS (20–30% savings).
- Enable **S3 transfer acceleration** if moving large data volumes.
- Monitor **CloudWatch cost anomaly detection** to alert on unexpected spikes.
- Reduce **RDS backup retention** from 7 to 1 day if not needed (saves ~$1–2/month per backup).
- Scale down `asg_desired` to 1 in non-production hours (e.g., nights/weekends).

**AWS Pricing Calculator:**
- VPC, Subnets, Route Tables, Security Groups, IGW, NAT Gateways: **Free**
- Elastic IPs: Free when in use (charged if unassociated)
- Link: https://calculator.aws/

## Destroying the Stack

### With Terraform

```bash
# Review resources that will be destroyed
terraform plan -destroy

# Destroy all resources
terraform destroy

# Or destroy specific resources (careful!)
terraform destroy -target=aws_rds_db_instance.main
```

> **RDS Note:** `deletion_protection = true` is set by default. You must disable it manually before Terraform can destroy the instance:
> ```bash
> aws rds modify-db-instance --db-instance-identifier multitier-webapp-mysql \
>   --no-deletion-protection --apply-immediately --region us-east-1
> ```
> Then run `terraform destroy`.

### With AWS CLI Bash Script

Uncomment and run the cleanup section at the end of `deploy.sh` in **reverse dependency order**:

```bash
# 1. Delete ASG (terminates all instances)
aws autoscaling delete-auto-scaling-group --auto-scaling-group-name multitier-webapp-asg \
  --force-delete --region us-east-1

# 2. Delete ALB and Target Group
aws elbv2 delete-load-balancer --load-balancer-arn arn:aws:elasticloadbalancing:... \
  --region us-east-1

# 3. Disable RDS deletion protection and delete
aws rds modify-db-instance --db-instance-identifier multitier-webapp-mysql \
  --no-deletion-protection --apply-immediately --region us-east-1
aws rds delete-db-instance --db-instance-identifier multitier-webapp-mysql \
  --skip-final-snapshot --region us-east-1

# 4. Delete security groups (after terminating dependent resources)
aws ec2 delete-security-group --group-id sg-xxxxxxxx --region us-east-1

# 5. Delete NAT Gateways and release Elastic IPs
# (Wait ~30 seconds for NAT GW to fully delete)

# 6. Delete VPC and subnets
```

**Resources NOT managed by Terraform/AWS CLI (manual cleanup):**
- EC2 Key Pair (create separately; not created by automation)
- VPC Flow Logs (if enabled manually)
- Manually created EBS snapshots or RDS snapshots

## Frequently Asked Questions

### Q1: I'm getting "502 Bad Gateway" from the ALB. What's wrong?

**A:** The ALB is healthy, but target instances may be unhealthy. Check:

1. **Instance health in target group:**
   ```bash
   aws elbv2 describe-target-health --target-group-arn <TG-ARN> --region us-east-1
   ```
   Look for `State: healthy`.

2. **Why instance is unhealthy:**
   - Check `/health` endpoint returns HTTP 200: `curl http://<instance-private-ip>/health`
   - Verify Security Group allows port 80 from ALB SG.
   - Check httpd is running: `sudo systemctl status httpd`
   - Review `/var/log/httpd/access_log` and `error_log` on instance.

3. **Wait for grace period:** New instances have 300 seconds before the first health check. If you just launched, wait 5 minutes.

4. **Stale application code:** If redeploying, terminate old instances to force ASG to launch new ones with fresh user data.

### Q2: Why are all instances concentrated in a single AZ?

**A:** Multi-AZ deployment requires:
- **Subnets in 2+ AZs:** Check `terraform output public_subnet_ids` includes subnets in different AZs.
- **ASG configured for both AZs:** Verify `vpc_zone_identifier` in ASG includes both private subnets.
- **IAM permissions:** Ensure you have `ec2:CreateNetworkInterface`, `ec2:Describe*` across AZs.

**Debug:**
```bash
# Check ASG AZ distribution
aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names multitier-webapp-asg \
  --region us-east-1 --query 'AutoScalingGroups[0].AvailabilityZones'

# Check running instances
aws ec2 describe-instances --filters "Name=tag:Name,Values=multitier-webapp-asg-instance" \
  --region us-east-1 --query 'Reservations[].Instances[].[InstanceId,Placement.AvailabilityZone]'
```

### Q3: How do I add HTTPS to the ALB?

**A:** Create an HTTPS listener and attach an ACM certificate:

```bash
# 1. Request or import certificate in ACM
aws acm request-certificate --domain-name example.com --region us-east-1

# 2. Validate certificate (email/DNS)

# 3. Create HTTPS listener (port 443)
aws elbv2 create-listener --load-balancer-arn <ALB-ARN> \
  --protocol HTTPS --port 443 \
  --certificates CertificateArn=arn:aws:acm:... \
  --default-actions Type=forward,TargetGroupArn=<TG-ARN> \
  --region us-east-1

# 4. (Optional) Redirect HTTP→HTTPS
aws elbv2 modify-listener --listener-arn <HTTP-LISTENER-ARN> \
  --default-actions Type=redirect,RedirectConfig='{Protocol=HTTPS,Port=443,StatusCode=HTTP_301}' \
  --region us-east-1
```

### Q4: How do I update my application code without redeploying the entire stack?

**A:** Two approaches:

**Option 1: SSH to instance (via Bastion) and update code directly**
```bash
# 1. SSH to Bastion
ssh -i your-key.pem ec2-user@<BASTION_PUBLIC_IP>

# 2. SSH to private web instance from Bastion
ssh -i your-key.pem ec2-user@<PRIVATE_IP>

# 3. Update application code
sudo nano /var/www/html/index.html
sudo systemctl restart httpd
```

**Option 2: Update launch template and perform rolling deployment**
```bash
# 1. Update user_data in launch template (via AWS Console or CLI)
aws ec2 create-launch-template-version --launch-template-name multitier-webapp-lt \
  --source-version '$Latest' --launch-template-data file://new-user-data.json

# 2. Update ASG to use new version
aws autoscaling update-auto-scaling-group --auto-scaling-group-name multitier-webapp-asg \
  --launch-template LaunchTemplateId=<ID>,Version='$Latest'

# 3. Gradually replace instances
aws autoscaling start-instance-refresh --auto-scaling-group-name multitier-webapp-asg \
  --preferences '{"MinHealthyPercentage": 50, "InstanceWarmupSeconds": 300}'
```

**Option 3: Use AWS Systems Manager Session Manager (no bastion required)**
```bash
# Connect via Session Manager (requires AmazonSSMManagedInstanceCore policy)
aws ssm start-session --target <INSTANCE_ID> --region us-east-1

# Then edit code as root
```

### Q5: Can I migrate state from local Terraform to remote S3 backend?

**A:** Yes. Uncomment the `backend "s3"` block in `provider.tf` and run:

```bash
# 1. Create S3 bucket and DynamoDB table (once)
aws s3 mb s3://my-terraform-state-bucket --region us-east-1
aws dynamodb create-table --table-name terraform-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST --region us-east-1

# 2. Update provider.tf backend bucket name

# 3. Re-initialize Terraform
terraform init
# (When prompted, confirm migrating state from local to S3)

# 4. Verify
terraform state list
```

### Q6: Why does the CPU scale-out threshold look high at 60%?

**A:** The 60% threshold (with 40% scale-in) provides:
- **Stability:** Avoids rapid flapping (oscillating up/down). The 20% dead-band is deliberate.
- **Cost control:** Prevents over-provisioning small traffic spikes that last <2 minutes.
- **Response time:** System scales out within 2–4 minutes of sustained load, acceptable for most apps.

**Adjust if:**
- **Traffic is unpredictable:** Lower to 50% scale-out, 35% scale-in.
- **Latency-sensitive app:** Lower to 50%/30% for faster response (higher cost).
- **Batch/periodic jobs:** Increase to 75%/50% to absorb short spikes efficiently.

---

**For further support or issues, refer to:**
- [Terraform AWS Provider Docs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs)
- [AWS EC2 Auto Scaling Guide](https://docs.aws.amazon.com/autoscaling/)
- [ALB Target Group Health Checks](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/target-group-health-checks.html)
