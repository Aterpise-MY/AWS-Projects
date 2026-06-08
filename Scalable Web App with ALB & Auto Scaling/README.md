# Scalable Web Application — AWS ALB & Auto Scaling

A production-ready infrastructure-as-code project that deploys a horizontally
scalable web application on AWS using Terraform. Traffic is distributed across
EC2 instances by an Application Load Balancer; the Auto Scaling Group
automatically adds or removes instances in response to CPU load.

---

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

---

## Architecture Overview

```
                           ┌─────────────────────────────────────┐
                           │              Internet               │
                           └──────────────────┬──────────────────┘
                                              │
                           ┌──────────────────▼──────────────────┐
                           │         Internet Gateway            │
                           │       igw-076bdd124057cfb98         │
                           └──────────────────┬──────────────────┘
                                              │
                           ┌──────────────────▼──────────────────┐
                           │    Application Load Balancer (ALB)  │
                           │    WebAppALB  •  port 80  •  HTTP   │
                           │    internet-facing, multi-AZ        │
                           └──────────┬───────────────┬──────────┘
                                      │               │
                    ┌─────────────────▼──┐       ┌───▼─────────────────┐
                    │    us-east-1a      │       │    us-east-1b       │
                    │  10.0.0.0/28       │       │  10.0.0.16/28       │
                    │  ┌──────────────┐  │       │  ┌──────────────┐   │
                    │  │  EC2 t3.med  │  │       │  │  EC2 t3.med  │   │
                    │  │  Amazon      │  │       │  │  Amazon      │   │
                    │  │  Linux 2     │  │       │  │  Linux 2     │   │
                    │  │  Apache      │  │       │  │  Apache      │   │
                    │  └──────────────┘  │       │  └──────────────┘   │
                    └────────────────────┘       └─────────────────────┘
                              │                             │
                    └─────────┴─────────────────────────────┘
                              Auto Scaling Group (1 – 4 instances)
                              Scale out: CPU > 60%
                              Scale in:  CPU < 40%

   ┌──────────────────────────────────────────────────────────────────┐
   │  CloudWatch                                                      │
   │   • CPUUtilization HIGH alarm  ──►  scale-out policy             │
   │   • CPUUtilization LOW alarm   ──►  scale-in  policy             │
   └──────────────────────────────────────────────────────────────────┘
```

**Traffic flow:**
`User → IGW → ALB (port 80) → Target Group → EC2 instance (port 80, Apache)`

---

## Networking & Routing

### VPC

| Field | Value |
|---|---|
| **VPC ID** | `vpc-0b8ea2c5bf5093847` |
| **CIDR Block** | `10.0.0.0/24` |
| **Internet Gateway** | `igw-076bdd124057cfb98` (state: available) |

### Subnets

| Subnet | AZ | CIDR | Available IPs | Public IP on Launch | Managed by |
|---|---|---|---|---|---|
| `subnet-017d9e213cb1cd657` | us-east-1a | `10.0.0.0/28` | 9 | Yes | Pre-existing |
| `subnet-0ff2ce1b2900affd6` | us-east-1b | `10.0.0.16/28` | 10 | Yes | Terraform (`aws_subnet.web_1b`) |

### Route Tables

| Route Table | Type | Destination | Target | State | Subnets |
|---|---|---|---|---|---|
| `rtb-09ef904e894338594` | Public | `10.0.0.0/24` | local | active | us-east-1a, us-east-1b |
| `rtb-09ef904e894338594` | Public | `0.0.0.0/0` | `igw-076bdd124057cfb98` | active | us-east-1a, us-east-1b |
| `rtb-090756b8feaaaa054` | Main (private) | `10.0.0.0/24` | local | active | — (no subnets assigned) |

> Both subnets share the public route table so EC2 instances can reach the
> internet via the IGW during boot — required for `yum install httpd` in user data.

### Traffic Flow

```
Internet
    │
    ▼  0.0.0.0/0 → igw-076bdd124057cfb98
Internet Gateway
    │
    ▼
Application Load Balancer (WebAppALB)
    ├── subnet-017d9e213cb1cd657  (us-east-1a, 10.0.0.0/28)
    └── subnet-0ff2ce1b2900affd6  (us-east-1b, 10.0.0.16/28)
    │
    ▼  HTTP:80 → Target Group (WebApp-tg)
EC2 Instances (Auto Scaling Group)
    ├── us-east-1a  (10.0.0.0/28)
    └── us-east-1b  (10.0.0.16/28)
```

---

## Component Details

### 1. Security Group (`WebApp-sg`)

| Direction | Protocol | Port | Source / Destination | Purpose |
|-----------|----------|------|----------------------|---------|
| Inbound   | TCP      | 22   | 0.0.0.0/0            | SSH management |
| Inbound   | TCP      | 80   | 0.0.0.0/0            | HTTP web traffic |
| Inbound   | TCP      | 443  | 0.0.0.0/0            | HTTPS web traffic |
| Outbound  | All      | All  | 0.0.0.0/0            | Package updates, AWS APIs |

> **Production note:** Restrict SSH to a known CIDR (e.g. your office IP or a
> bastion host) by overriding the ingress rule in a derived module.

---

### 2. Launch Template (`WebAppTemplate`)

| Attribute        | Value |
|------------------|-------|
| AMI              | Latest Amazon Linux 2 (`amzn2-ami-hvm-2.*-x86_64-gp2`) — resolved dynamically |
| Instance Type    | `t3.medium` (2 vCPU, 4 GB RAM) |
| Key Pair         | `WebApp-key-pair` (RSA, PEM) |
| Detailed Monitoring | Enabled (1-minute CloudWatch metrics) |
| User Data        | Installs Apache httpd, enables & starts the service, serves a dynamic HTML page showing the instance ID and AZ |

The user data script uses **IMDSv2** (token-based metadata) which is the
current AWS security best practice. The HTML page updates automatically per
instance, making it easy to observe load balancing in action.

---

### 3. Application Load Balancer (`WebAppALB`)

| Attribute        | Value |
|------------------|-------|
| Scheme           | Internet-facing |
| Type             | Application (Layer 7) |
| State            | Active |
| Subnets          | `subnet-017d9e213cb1cd657` (us-east-1a), `subnet-0ff2ce1b2900affd6` (us-east-1b) |
| Listener         | HTTP on port 80, forward to target group |
| DNS Name         | `WebAppALB-99455837.us-east-1.elb.amazonaws.com` |

The ALB distributes traffic using a round-robin algorithm by default. Each
request lands on a healthy instance; if an instance fails health checks it is
drained and removed from rotation within ~90 seconds.

---

### 4. Target Group (`WebApp-tg`)

| Attribute               | Value |
|-------------------------|-------|
| Protocol / Port         | HTTP / 80 |
| Target Type             | Instance |
| Health Check Path       | `/` |
| Health Check Interval   | 30 seconds |
| Healthy Threshold       | 2 consecutive successes |
| Unhealthy Threshold     | 3 consecutive failures |
| Expected HTTP Status    | `200` |

Health checks run every 30 seconds. An instance must return two consecutive
`200 OK` responses before traffic is sent to it, and three consecutive failures
before it is marked unhealthy and traffic is redirected.

---

### 5. Auto Scaling Group (`WebAppASG`)

| Attribute              | Value |
|------------------------|-------|
| Desired capacity       | 2 (scales down to 1 under low CPU — see note below) |
| Minimum capacity       | 1 |
| Maximum capacity       | 4 |
| Health check type      | ELB (uses ALB health checks, not just EC2 status) |
| Health check grace period | 120 seconds (allows Apache to start before first check) |
| Subnets                | us-east-1a + us-east-1b |

> **Note:** The `cpu-low` alarm fires at ~0% CPU when there is no traffic,
> causing the ASG to scale in to `desired=1`. To prevent this, increase
> `evaluation_periods` in `main.tf` or add an `estimated_instance_warmup`
> to the scale-in policy.

---

### 6. Scaling Policies & CloudWatch Alarms

Two independent **Step Scaling** policies are used — one per direction — giving
explicit control over step sizes and cooldowns.

#### Scale-Out Policy

| Condition | Action |
|-----------|--------|
| CPU between 60% and 80% | Add **1** instance |
| CPU above 80%           | Add **2** instances (rapid spike) |

Triggered by the `cpu-high` CloudWatch alarm:
- Metric: `CPUUtilization` averaged across the ASG
- Period: 60 seconds
- Evaluation periods: 2 (alarm fires after 2 consecutive breaches)
- Threshold: > 60%
- Current state: **OK**

#### Scale-In Policy

| Condition | Action |
|-----------|--------|
| CPU below 40% | Remove **1** instance |

Triggered by the `cpu-low` CloudWatch alarm:
- Metric: `CPUUtilization` averaged across the ASG
- Period: 60 seconds
- Evaluation periods: 2
- Threshold: < 40%
- Current state: **ALARM** (idle instance, no traffic)

Both alarms use `treat_missing_data = "notBreaching"` to avoid spurious
scale-in events when an instance is terminating and stops publishing metrics.

---

## Directory Structure

```
.
├── main.tf                        # Provider, data sources, and all resource definitions
├── variables.tf                   # Input variable declarations with descriptions & validation
├── outputs.tf                     # Values exported after apply (ALB DNS, ASG name, etc.)
├── terraform.tfvars               # Variable values — edit before applying
├── deploy.sh                      # Equivalent AWS CLI deployment script (reference)
├── Result.md                      # Live architecture audit — updated by /audit skill
├── WebApp-key-pair.pem            # EC2 SSH private key (chmod 400, git-ignored)
├── screenshots/
│   ├── webapp-running.png         # Web app live via ALB
│   └── ec2-instances.png          # EC2 console showing ASG instances
├── .claude/
│   └── commands/
│       └── audit.md               # /audit skill — runs after terraform apply
└── README.md                      # This file
```

---

## Prerequisites

| Tool      | Minimum Version | Install |
|-----------|-----------------|---------|
| Terraform | 1.6.0           | https://developer.hashicorp.com/terraform/install |
| AWS CLI   | 2.x             | https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html |
| AWS credentials | — | `aws configure` or environment variables |

You also need an existing AWS VPC with at least one public subnet. The
`us-east-1b` subnet is created and managed by this Terraform configuration.

---

## Quick Start

```bash
# 1. Clone / enter the project directory
cd "Scalable Web App with ALB & Auto Scaling"

# 2. Fill in your real values
#    At minimum set: vpc_id, subnet_ids, public_route_table_id, key_pair_name
vim terraform.tfvars

# 3. Initialise Terraform (downloads the AWS provider)
terraform init

# 4. Preview the execution plan
terraform plan -var-file=terraform.tfvars

# 5. Deploy (auto-approve or type "yes" when prompted)
terraform apply -var-file=terraform.tfvars

# 6. Visit the application
terraform output alb_dns_name

# 7. Run the architecture audit skill
# Type /audit in Claude Code to check all resources and update Result.md
```

Allow **2–3 minutes** after `apply` completes for the EC2 instances to pass
their health checks before the ALB begins forwarding traffic.

---

## Input Variables

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `region` | `string` | `"us-east-1"` | AWS region |
| `app_name` | `string` | `"WebApp"` | Prefix for all resource names |
| `environment` | `string` | `"production"` | Deployment environment |
| `vpc_id` | `string` | *(required)* | Existing VPC ID |
| `subnet_ids` | `list(string)` | *(required)* | Pre-existing subnet IDs (e.g. us-east-1a). The us-east-1b subnet is Terraform-managed and appended automatically |
| `public_route_table_id` | `string` | *(required)* | Route table ID with `0.0.0.0/0 → IGW` — used to make the us-east-1b subnet public |
| `instance_type` | `string` | `"t3.medium"` | EC2 instance type |
| `key_pair_name` | `string` | `""` | EC2 key pair for SSH (optional) |
| `asg_desired` | `number` | `2` | Desired instance count |
| `asg_min` | `number` | `1` | Minimum instance count |
| `asg_max` | `number` | `4` | Maximum instance count |
| `scale_out_cpu_threshold` | `number` | `60` | CPU % that triggers scale-out |
| `scale_in_cpu_threshold` | `number` | `40` | CPU % that triggers scale-in |

All variables are validated; Terraform will reject invalid combinations (e.g.
`asg_desired` outside `[asg_min, asg_max]` or a scale-in threshold higher than
the scale-out threshold) before any AWS API calls are made.

---

## Outputs

| Output | Description |
|--------|-------------|
| `alb_dns_name` | Full HTTP URL of the load balancer — use as your app's entry point |
| `alb_arn` | ARN of the ALB |
| `target_group_arn` | ARN of the ALB Target Group |
| `asg_name` | Name of the Auto Scaling Group |
| `launch_template_id` | ID of the EC2 Launch Template |
| `launch_template_latest_version` | Current latest version number |
| `security_group_id` | ID of the shared Security Group |
| `ami_id` | Amazon Linux 2 AMI ID resolved at plan time |

Retrieve any output after apply:

```bash
terraform output alb_dns_name
terraform output -json          # all outputs as JSON
```

---

## Scaling Behaviour

```
CPU %  │
  100  │
   80  │              ┌─────────────────────────────────  +2 instances
   60  │         ─────┘  scale-out threshold              +1 instance
   40  │  scale-in threshold ─────┐
   20  │                          └─────────────────────  -1 instance
    0  └──────────────────────────────────────────────────────► time
```

**Dead band (40%–60%):** No scaling action occurs in this range, preventing
oscillation when CPU hovers near a threshold.

**Evaluation periods = 2:** The alarm must breach the threshold for two
consecutive 60-second periods (2 minutes total) before firing. This prevents
reactions to momentary CPU spikes.

**Scale-out step sizes:**
- Moderate load (60%–80%): +1 instance — gradual scale for sustained but
  manageable traffic growth.
- Heavy load (>80%): +2 instances — faster reaction to sudden traffic spikes.

---

## Tagging Strategy

Every resource receives three standard tags applied via the provider's
`default_tags` block, plus a per-resource `Name` tag:

| Tag Key     | Value |
|-------------|-------|
| `Name`      | Unique per resource (e.g. `WebAppALB`, `WebApp-sg`) |
| `Environment` | Value of `var.environment` (default: `production`) |
| `ManagedBy` | `terraform` |
| `Project`   | Value of `var.app_name` (default: `WebApp`) |

Because ASG tag propagation uses a different mechanism than provider
`default_tags`, ASG instances receive their tags explicitly via `tag {}` blocks
inside `aws_autoscaling_group`.

---

## Security Considerations

| Topic | Current posture | Recommended hardening |
|-------|-----------------|----------------------|
| SSH access | Open to 0.0.0.0/0 | Restrict to a known CIDR or remove; use EC2 Instance Connect / SSM Session Manager instead |
| HTTPS | Port 443 open, no TLS termination | Add an ACM certificate and an HTTPS listener; redirect HTTP → HTTPS |
| IMDSv2 | User data uses token-based metadata | Enforce `HttpTokens = required` in the Launch Template's `metadata_options` block |
| Secrets | No secrets in this config | Use AWS Secrets Manager or SSM Parameter Store for any app secrets |
| State file | Local backend | Use an S3 backend with DynamoDB state locking for team use |
| Deletion protection | Disabled on ALB | Set `enable_deletion_protection = true` in production |

---

## Cost Estimate

Based on **us-east-1** on-demand pricing (approximate, subject to change):

| Resource | Quantity | Monthly cost (USD) |
|----------|----------|--------------------|
| EC2 t3.medium | 2 (desired) | ~$60 |
| Application Load Balancer | 1 | ~$18 + LCU usage |
| CloudWatch Alarms | 2 | ~$0.20 |
| **Total (baseline)** | | **~$78/month** |

Costs scale linearly as the ASG adds instances. Use [AWS Pricing Calculator](https://calculator.aws) for a precise estimate tailored to your traffic profile.

---

## Destroying the Stack

```bash
terraform destroy -var-file=terraform.tfvars
```

This removes all Terraform-managed resources including the `us-east-1b` subnet.
The pre-existing VPC, `us-east-1a` subnet, route table, and internet gateway
are **not** managed by this config and will not be affected.

---

## Frequently Asked Questions

**Q: The ALB DNS resolves but returns 502 Bad Gateway.**
A: The instances are still starting or Apache has not yet passed health checks.
Wait 2–3 minutes and retry. If it persists, check that both subnets have
`map_public_ip_on_launch = true` and are associated with a route table that has
a `0.0.0.0/0 → IGW` route — instances need internet access during boot to run
`yum install httpd`.

**Q: All instances appear in only one AZ.**
A: The `cpu-low` CloudWatch alarm may have fired (CPU ~0% under no traffic),
triggering a scale-in that reduced `desired` to 1. Restore with:
```bash
aws autoscaling set-desired-capacity \
  --auto-scaling-group-name WebAppASG \
  --desired-capacity 2 \
  --region us-east-1
```

**Q: How do I add HTTPS?**
A: Request or import an ACM certificate, add a second `aws_lb_listener` on
port 443 with `protocol = "HTTPS"` referencing the certificate ARN, and change
the HTTP listener to return a `redirect` action.

**Q: How do I update the application code?**
A: Update the user data in `main.tf`, then run `terraform apply`. Terraform
creates a new Launch Template version. To replace existing instances, trigger
an instance refresh:
```bash
aws autoscaling start-instance-refresh \
  --auto-scaling-group-name WebAppASG \
  --preferences MinHealthyPercentage=50,InstanceWarmup=120 \
  --region us-east-1
```

**Q: How do I store Terraform state remotely?**
A: Add a `backend "s3"` block to `main.tf`:
```hcl
terraform {
  backend "s3" {
    bucket         = "your-tfstate-bucket"
    key            = "webApp/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "terraform-state-lock"
    encrypt        = true
  }
}
```

**Q: Why Step Scaling instead of Target Tracking?**
A: Step Scaling gives explicit control over step sizes per alarm, a dead band
between thresholds (preventing oscillation), and separate cooldown periods per
direction. Target Tracking is simpler but doesn't support a dead band or
asymmetric step sizes in one policy definition.

**Q: How do I re-run the architecture audit?**
A: Type `/audit` in Claude Code. The skill inspects all live AWS resources via
the AWS API MCP server and rewrites `Result.md` with current IDs, health
status, and routing details.
