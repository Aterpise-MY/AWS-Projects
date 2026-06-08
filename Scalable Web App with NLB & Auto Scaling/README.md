# Scalable Web App with NLB & Auto Scaling

A production-grade infrastructure-as-code project that deploys a horizontally
scalable web application on AWS using Terraform. A Network Load Balancer (NLB)
distributes TCP traffic at Layer 4 across EC2 instances running Nginx or Apache;
the Auto Scaling Group automatically adds or removes instances in response to
CPU load. WAFv2 managed rules inspect traffic before it reaches the NLB, and
all instances live in private subnets — reachable only through the NLB and via
SSM Session Manager.

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
                    │              Internet                │
                    └──────────────────┬──────────────────┘
                                       │
                    ┌──────────────────▼──────────────────┐
                    │     Network Load Balancer (NLB)      │
                    │  TCP 80  •  TLS 443 (if ACM set)     │
                    │  internet-facing  •  cross-zone LB   │
                    └──────────┬────────────────┬──────────┘
                               │                │
          ┌────────────────────▼──┐        ┌────▼──────────────────┐
          │      us-east-1a       │        │      us-east-1b       │
          │  Public 10.0.1.0/24   │        │  Public 10.0.2.0/24   │
          │  (NLB node only)      │        │  (NLB node only)      │
          │                       │        │                       │
          │  Private 10.0.3.0/24  │        │  Private 10.0.4.0/24  │
          │  ┌─────────────────┐  │        │  ┌─────────────────┐  │
          │  │  EC2  t3.medium │  │        │  │  EC2  t3.medium │  │
          │  │  Nginx / Apache │  │        │  │  Nginx / Apache │  │
          │  └────────┬────────┘  │        │  └────────┬────────┘  │
          │           │           │        │           │           │
          │  ┌────────▼────────┐  │        │  ┌────────▼────────┐  │
          │  │   NAT Gateway   │  │        │  │   NAT Gateway   │  │
          └──┴─────────────────┴──┘        └──┴─────────────────┴──┘
                     │                                  │
                     └──────────────┬───────────────────┘
                                    ▼
                           Internet Gateway
                    Auto Scaling Group (2 – 6 instances)
                    Scale out: CPU > 70%  •  Scale in: CPU < 30%

   ┌─────────────────────────────────────────────────────────────────┐
   │  CloudWatch                                                     │
   │   • CPUUtilization HIGH alarm  ──►  scale-out policy (+1)       │
   │   • CPUUtilization LOW  alarm  ──►  scale-in  policy (−1)       │
   │   • UnHealthyHostCount  alarm  ──►  SNS email notification      │
   │   • HealthyHostCount    alarm  ──►  SNS email notification      │
   └─────────────────────────────────────────────────────────────────┘
```

**Traffic flow:**
`User → NLB (TCP 80 / TLS 443) → Target Group → EC2 instance (port 80, Nginx/Apache)`

> WAFv2 cannot be associated with an NLB (Layer 4). The WAF ACL is provisioned
> and ready; associate it with an ALB ARN if you place an ALB in front of the NLB.

---

## Networking & Routing

### VPC

| Field | Value |
|---|---|
| **CIDR Block** | `10.0.0.0/16` |
| **DNS Hostnames** | Enabled |
| **DNS Support** | Enabled |
| **Managed by** | `terraform-aws-modules/vpc/aws ~> 5.0` |

### Subnets

| Name | AZ | CIDR | Tier | Purpose |
|---|---|---|---|---|
| `scalable-webapp-prod-public-1` | `us-east-1a` | `10.0.1.0/24` | Public | NLB node; `map_public_ip_on_launch = false` |
| `scalable-webapp-prod-public-2` | `us-east-1b` | `10.0.2.0/24` | Public | NLB node; `map_public_ip_on_launch = false` |
| `scalable-webapp-prod-private-1` | `us-east-1a` | `10.0.3.0/24` | Private | EC2 instances; no public IPs |
| `scalable-webapp-prod-private-2` | `us-east-1b` | `10.0.4.0/24` | Private | EC2 instances; no public IPs |

### Route Tables

| Route Table | Subnets | Destination | Target |
|---|---|---|---|
| Public RT | public-1, public-2 | `10.0.0.0/16` | local |
| Public RT | public-1, public-2 | `0.0.0.0/0` | Internet Gateway |
| Private RT (AZ-1) | private-1 | `10.0.0.0/16` | local |
| Private RT (AZ-1) | private-1 | `0.0.0.0/0` | NAT Gateway (us-east-1a) |
| Private RT (AZ-2) | private-2 | `10.0.0.0/16` | local |
| Private RT (AZ-2) | private-2 | `0.0.0.0/0` | NAT Gateway (us-east-1b) |

> Each private subnet routes through its own AZ-local NAT Gateway. This
> prevents cross-AZ NAT traffic and keeps the stack operational when one AZ
> is impaired.

### Traffic Flow

```
Internet
    │
    ▼  0.0.0.0/0 → Internet Gateway
WAFv2 Web ACL
    │
    ▼
Network Load Balancer
    ├── public subnet us-east-1a (10.0.1.0/24)
    └── public subnet us-east-1b (10.0.2.0/24)
    │
    ▼  TCP:80 → Target Group
EC2 Instances (Auto Scaling Group)
    ├── private subnet us-east-1a (10.0.3.0/24)
    └── private subnet us-east-1b (10.0.4.0/24)
    │
    ▼  0.0.0.0/0 → NAT Gateway → Internet Gateway
Outbound (package installs, SSM, AWS APIs)
```

---

## Component Details

### 1. Security Groups

#### NLB Security Group (`scalable-webapp-prod-nlb-sg`)

| Direction | Protocol | Port | Source / Destination | Purpose |
|---|---|---|---|---|
| Inbound | TCP | 80 | `0.0.0.0/0` | HTTP from internet |
| Inbound | TCP | 443 | `0.0.0.0/0` | HTTPS from internet |
| Outbound | All | All | `0.0.0.0/0` | Forward traffic to instances |

#### EC2 Security Group (`scalable-webapp-prod-ec2-sg`)

| Direction | Protocol | Port | Source / Destination | Purpose |
|---|---|---|---|---|
| Inbound | TCP | 80 | NLB security group ID | HTTP from NLB only — not the open internet |
| Outbound | All | All | `0.0.0.0/0` | Package installs, SSM agent, AWS APIs |

> **Production note:** EC2 instances are not reachable from the internet. The
> inbound rule references the NLB security group ID, not a CIDR, so only the
> NLB's network interfaces can open connections to instances on port 80.

---

### 2. Launch Template (`scalable-webapp-prod-lt-*`)

| Attribute | Value |
|---|---|
| AMI | Supplied via `var.ami_id` (Amazon Linux 2023 or Ubuntu) |
| Instance Type | `t3.medium` (2 vCPU, 4 GB RAM) — override via `var.instance_type` |
| Key Pair | Supplied via `var.key_pair_name` (emergency SSH only) |
| IAM Instance Profile | `scalable-webapp-prod-ec2-profile` (SSM access) |
| Public IP | Disabled — instances are in private subnets |
| Detailed Monitoring | Enabled (1-minute CloudWatch metrics) |
| IMDSv2 | `HttpTokens = required` — token-based metadata only |
| Web Server | Nginx (default) or Apache — set via `var.web_server` |
| User Data | Installs and starts the web server; writes `index.html` showing instance ID and AZ (pulled via IMDSv2) |

The user data script selects Nginx or Apache at launch time based on
`var.web_server`. The index page is updated dynamically per instance, making
it easy to observe load balancing by refreshing the browser.

---

### 3. Network Load Balancer (`scalable-webapp-prod-nlb`)

| Attribute | Value |
|---|---|
| Type | Network (Layer 4 TCP/TLS) |
| Scheme | Internet-facing |
| Subnets | `scalable-webapp-prod-public-1` (us-east-1a), `scalable-webapp-prod-public-2` (us-east-1b) |
| Cross-Zone Load Balancing | Enabled |
| Deletion Protection | Enabled when `var.environment = "prod"` |
| HTTP Listener | TCP port 80 → forward to target group |
| HTTPS Listener | TLS port 443 → forward to target group (created only when `var.acm_certificate_arn` is non-empty) |
| TLS Policy | `ELBSecurityPolicy-TLS13-1-2-2021-06` |

> Unlike an ALB, an NLB operates at Layer 4. It does not terminate HTTP; it
> passes raw TCP connections through to instances. This means no HTTP-level
> features (path routing, header inspection, redirects) — use an ALB if those
> are required.

---

### 4. Target Group (`scalable-webapp-prod-tg`)

| Attribute | Value |
|---|---|
| Protocol / Port | TCP / 80 |
| Target Type | Instance |
| Health Check Protocol | TCP |
| Health Check Port | 80 |
| Health Check Interval | 30 seconds |
| Healthy Threshold | 3 consecutive successes |
| Unhealthy Threshold | 3 consecutive failures |

Health checks open a TCP connection on port 80. An instance must accept three
consecutive connections before traffic is routed to it, and must fail three
consecutive checks before being marked unhealthy and removed from rotation
(~90 seconds to drain).

---

### 5. Auto Scaling Group (`scalable-webapp-prod-asg`)

| Attribute | Value |
|---|---|
| Desired Capacity | 2 (configurable via `var.asg_desired_capacity`) |
| Minimum Capacity | 2 (configurable via `var.asg_min_size`) |
| Maximum Capacity | 6 (configurable via `var.asg_max_size`) |
| Subnets | `scalable-webapp-prod-private-1`, `scalable-webapp-prod-private-2` |
| Health Check Type | `ELB` — uses NLB health checks, not just EC2 instance status |
| Health Check Grace Period | 300 seconds (allows web server to start before first check) |
| Launch Template Version | `$Latest` — always uses the newest launch template version |
| Instance Refresh | Rolling, `MinHealthyPercentage = 50` |

> `health_check_type = "ELB"` means the ASG considers an instance healthy only
> when the NLB target group marks it healthy. This is stricter than `EC2`,
> which considers an instance healthy as soon as it is running, even if the
> web server has not started.

---

### 6. Scaling Policies & CloudWatch Alarms

Two **Simple Scaling** policies control instance count — one per direction.

#### Scale-Out Policy

| Trigger | Action | Cooldown |
|---|---|---|
| CPU > `var.cpu_scale_out_threshold` (default 70%) for 2 × 60 s | Add **1** instance | 300 seconds |

#### Scale-In Policy

| Trigger | Action | Cooldown |
|---|---|---|
| CPU < `var.cpu_scale_in_threshold` (default 30%) for 2 × 60 s | Remove **1** instance | 300 seconds |

#### CloudWatch Alarms

| Alarm | Metric | Threshold | Action |
|---|---|---|---|
| `cpu-high` | `CPUUtilization` (ASG avg) | > 70% for 2 periods | Scale-out policy |
| `cpu-low` | `CPUUtilization` (ASG avg) | < 30% for 2 periods | Scale-in policy |
| `unhealthy-hosts` | `UnHealthyHostCount` (NLB) | ≥ 1 for 2 periods | SNS notification |
| `healthy-hosts-low` | `HealthyHostCount` (NLB) | < `asg_min_size` for 2 periods | SNS notification |
| `network-in-high` | `ProcessedBytes` (NLB) | > 1 GB per 5 min | SNS notification |

---

## Directory Structure

```
.
├── main.tf                  # VPC module, SGs, IAM, launch template, NLB, ASG,
│                            #   scaling policies, CloudWatch alarms, SNS, WAFv2
├── variables.tf             # All input variable declarations with validation
├── outputs.tf               # Exported values after apply (NLB DNS, ASG name, etc.)
├── provider.tf              # AWS + Random providers; commented-out S3 remote state
├── prod.tfvars.example      # Copy to prod.tfvars and fill in required values
├── deploy.sh                # Equivalent AWS CLI deployment script (9 sections)
└── README.md                # This file
```

---

## Prerequisites

| Tool | Minimum Version | Install |
|---|---|---|
| Terraform | 1.5.0 | https://developer.hashicorp.com/terraform/install |
| AWS CLI | 2.x | https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html |
| AWS credentials | — | `aws configure` or environment variables |
| Apache Bench (`ab`) | any | `brew install httpd` (macOS) / `apt install apache2-utils` (Linux) — for load testing only |

**Account-level requirements:**

- An existing EC2 key pair in the target region (`var.key_pair_name`)
- An AMI ID for Amazon Linux 2023 or Ubuntu in the target region (`var.ami_id`)
- An ACM certificate ARN if HTTPS is required (`var.acm_certificate_arn`) — leave blank to deploy HTTP only
- IAM permissions: EC2 full, ELB full, AutoScaling full, CloudWatch full, WAFv2 full, IAM role create/attach, SNS full, VPC full

---

## Quick Start

### Path A — Terraform

```bash
# 1. Enter the project directory
cd "Scalable Web App with NLB & Auto Scaling"

# 2. Copy the example vars file and fill in the required values:
#    ami_id, key_pair_name, alarm_email
cp prod.tfvars.example prod.tfvars
vim prod.tfvars

# 3. Initialise providers and the VPC module
terraform init

# 4. Preview all changes before creating anything
terraform plan -var-file=prod.tfvars

# 5. Deploy (takes approximately 5–7 minutes)
terraform apply -var-file=prod.tfvars

# 6. Grab the NLB DNS name from outputs
terraform output nlb_dns_name

# 7. Verify the app is serving
curl http://$(terraform output -raw nlb_dns_name)
```

> **Remote state:** Before team use, create an S3 bucket and a DynamoDB table
> (partition key `LockID`, type String), then uncomment the `backend "s3"`
> block in `provider.tf` and re-run `terraform init`.

Allow **3–5 minutes** after `apply` completes for instances to pass their
NLB health checks before traffic is forwarded.

### Path B — AWS CLI (`deploy.sh`)

```bash
# 1. Open deploy.sh and set the variables at the top:
#    AMI_ID, KEY_PAIR_NAME, ALARM_EMAIL, and optionally REGION / WEB_SERVER
vim deploy.sh

# 2. Run the script (it executes all 9 sections in order)
chmod +x deploy.sh
./deploy.sh

# 3. The script prints the NLB DNS name in the summary at the end
curl http://<nlb_dns_name printed by the script>
```

Allow **3–5 minutes** after the script completes for health checks to pass.

---

## Input Variables

| Variable | Type | Default | Description |
|---|---|---|---|
| `project_name` | `string` | `"scalable-webapp"` | Prefix applied to every resource name and tag |
| `environment` | `string` | `"prod"` | Deployment environment; controls NLB deletion protection |
| `region` | `string` | `"us-east-1"` | AWS region to deploy into |
| `vpc_cidr` | `string` | `"10.0.0.0/16"` | CIDR block for the VPC |
| `public_subnet_cidrs` | `list(string)` | `["10.0.1.0/24","10.0.2.0/24"]` | One public subnet CIDR per AZ (NLB placement) |
| `private_subnet_cidrs` | `list(string)` | `["10.0.3.0/24","10.0.4.0/24"]` | One private subnet CIDR per AZ (EC2 placement) |
| `instance_type` | `string` | `"t3.medium"` | EC2 instance type |
| `ami_id` | `string` | *(required)* | AMI ID — supply Amazon Linux 2023 or Ubuntu for your region |
| `key_pair_name` | `string` | *(required)* | Name of an existing EC2 key pair |
| `asg_min_size` | `number` | `2` | Minimum instance count in the ASG |
| `asg_max_size` | `number` | `6` | Maximum instance count the ASG can scale to |
| `asg_desired_capacity` | `number` | `2` | Starting instance count |
| `cpu_scale_out_threshold` | `number` | `70` | CPU % that triggers a scale-out event (add 1 instance) |
| `cpu_scale_in_threshold` | `number` | `30` | CPU % that triggers a scale-in event (remove 1 instance) |
| `acm_certificate_arn` | `string` | `""` | ACM certificate ARN for TLS; leave empty to skip the port-443 listener |
| `alarm_email` | `string` | *(required)* | Email that receives CloudWatch alarm notifications |
| `web_server` | `string` | `"nginx"` | Web server to install — `"nginx"` or `"apache"` (validated) |

**Validation:** `var.web_server` is validated by Terraform; any value other
than `"nginx"` or `"apache"` causes `terraform plan` to fail before any AWS
API calls are made.

---

## Outputs

| Output | Description |
|---|---|
| `nlb_dns_name` | Public DNS name of the NLB — use as the app entry point |
| `nlb_arn` | ARN of the NLB (used for WAF association, CLI operations) |
| `asg_name` | Auto Scaling Group name |
| `asg_arn` | ARN of the Auto Scaling Group |
| `launch_template_id` | ID of the EC2 Launch Template |
| `vpc_id` | VPC ID |
| `public_subnet_ids` | List of public subnet IDs (NLB placement) |
| `private_subnet_ids` | List of private subnet IDs (EC2 placement) |
| `ec2_security_group_id` | Security group attached to EC2 instances |
| `iam_role_arn` | IAM role ARN granting SSM access to instances |
| `sns_topic_arn` | SNS topic ARN used for CloudWatch alarm notifications |
| `waf_web_acl_arn` | WAFv2 Web ACL ARN |

Retrieve any output after `apply`:

```bash
# Single output
terraform output nlb_dns_name

# All outputs as JSON
terraform output -json
```

---

## Scaling Behaviour

```
CPU %  │
  100  │
   70  │  ─────────────────────────────────────────── scale-out threshold (+1 instance)
       │               dead band (no action)
   30  │  ─────────────────────────────────────────── scale-in  threshold (−1 instance)
    0  └──────────────────────────────────────────────────────────────────────► time
```

**Dead band (30%–70%):** No scaling action fires in this range. This prevents
oscillation when CPU hovers near a threshold — a 5% CPU fluctuation will not
cause instances to be repeatedly added and removed.

**Evaluation periods = 2:** Each alarm requires two consecutive 60-second
periods (2 minutes total) above or below the threshold before firing. This
prevents reactions to brief CPU spikes caused by cron jobs or health check
responses.

**Cooldown = 300 s:** After a scaling action, Simple Scaling waits 300 seconds
before evaluating alarms again. This gives the new instance time to come into
service and absorb load before another scale-out is triggered.

**Step size = 1:** Both policies adjust capacity by exactly one instance per
action. This is conservative — sustained high CPU will trigger repeated
scale-out actions (one every ~7 minutes: 2-minute evaluation + 5-minute
cooldown) until demand is met or `asg_max_size` is reached. To scale faster
under sudden spikes, increase `scaling_adjustment` in the scale-out policy in
`main.tf`.

---

## Tagging Strategy

Every resource receives tags applied via the provider's `default_tags` block,
plus a per-resource `Name` tag:

| Tag Key | Value |
|---|---|
| `Name` | Unique per resource (e.g. `scalable-webapp-prod-nlb`, `scalable-webapp-prod-ec2-sg`) |
| `Project` | Value of `var.project_name` (default: `scalable-webapp`) |
| `Environment` | Value of `var.environment` (default: `prod`) |
| `ManagedBy` | `terraform` |

> **ASG instance tags:** The ASG uses explicit `tag {}` blocks with
> `propagate_at_launch = true` because ASG instance tags are not covered by
> the provider-level `default_tags`. Instances receive all four tags above
> plus `Name = scalable-webapp-prod-web`.

> **Launch template volume tags:** `tag_specifications` blocks for both
> `"instance"` and `"volume"` resource types are included in the launch
> template so EBS volumes are tagged at creation time.

---

## Security Considerations

| Topic | Current Posture | Recommended Hardening |
|---|---|---|
| NLB internet exposure | Ports 80 and 443 accept traffic from `0.0.0.0/0` — required for the NLB to receive public web traffic | No change needed; this is intentional |
| EC2 instance exposure | Instances are in private subnets; inbound port 80 is restricted to the NLB security group only | No change needed |
| SSH access | Key pair is attached but no SSH inbound rule exists in the EC2 SG | Remove the key pair from the launch template entirely if SSM is the only access method |
| IMDSv2 | `HttpTokens = required` on the launch template; user data uses IMDSv2 tokens | No change needed — IMDSv2 is enforced |
| Bastion host | None required — SSM Session Manager is configured via `AmazonSSMManagedInstanceCore` | Enforce SSM access via IAM conditions if stricter control is needed |
| WAF | WAFv2 ACL is created with `AWSManagedRulesCommonRuleSet` + `AWSManagedRulesKnownBadInputsRuleSet`, but **cannot be associated with an NLB** (WAF is Layer 7; NLB is Layer 4) | Place an ALB in front of the NLB and associate the WAF ACL with the ALB ARN |
| HTTPS | Port 443 listener is created only when `var.acm_certificate_arn` is supplied | Set `var.acm_certificate_arn` and add an HTTP→HTTPS redirect listener |
| TLS policy | `ELBSecurityPolicy-TLS13-1-2-2021-06` when HTTPS is enabled | Keep this policy; it enforces TLS 1.2+ and prefers TLS 1.3 |
| State file | Local backend by default | Use the S3 backend with DynamoDB state locking before team use |
| Deletion protection | Enabled on the NLB when `environment = "prod"` | No change needed |

---

## Cost Estimate

Based on **us-east-1** on-demand pricing (approximate; subject to change):

| Resource | Quantity | Unit Cost | Monthly Cost (USD) |
|---|---|---|---|
| EC2 `t3.medium` | 2 (desired) | $0.0416/hr | ~$61 |
| Network Load Balancer | 1 | $0.008/hr + $0.006/LCU-hr | ~$6 base |
| NAT Gateway | 2 (one per AZ) | $0.045/hr + $0.045/GB | ~$66 (idle) |
| WAFv2 Web ACL | 1 | $5.00/month + $1.00/million requests | ~$5 |
| CloudWatch Alarms | 5 | $0.10/alarm | ~$0.50 |
| SNS (email) | 1 topic | $0.00/notification (email is free) | ~$0 |
| **Total (baseline, 2 instances, no traffic data)** | | | **~$138/month** |

> **NAT Gateway costs dominate** when instances are in private subnets. At
> scale, data-processing charges ($0.045/GB) can exceed EC2 costs. Use a
> VPC Endpoint for S3 and SSM to reduce NAT traffic.
>
> Costs scale as the ASG adds instances. Use the
> [AWS Pricing Calculator](https://calculator.aws) for a precise estimate
> tailored to your instance count and traffic volume.

---

## Destroying the Stack

### Terraform

```bash
# If environment = "prod", disable NLB deletion protection first
aws elbv2 modify-load-balancer-attributes \
  --load-balancer-arn $(terraform output -raw nlb_arn) \
  --attributes Key=deletion_protection.enabled,Value=false

# Then destroy all Terraform-managed resources
terraform destroy -var-file=prod.tfvars
```

This removes all resources created by this configuration. No pre-existing
resources are used — everything is created fresh — so `terraform destroy`
is a complete teardown.

### AWS CLI (`deploy.sh`)

Uncomment the `# CLEANUP` section at the bottom of `deploy.sh` and run it.
Resources must be deleted in this order to avoid dependency errors:

1. WAF disassociation → WAF ACL deletion
2. CloudWatch alarms
3. Scaling policies
4. ASG — set `min/max/desired` to `0`, wait for instance termination, then delete
5. NLB listener → Target group → NLB (wait for NLB deletion)
6. Launch template
7. NAT Gateways (wait ~90 seconds per gateway)
8. Release Elastic IPs
9. Detach and delete Internet Gateway
10. Delete subnets
11. Delete route tables
12. Delete security groups
13. Delete VPC
14. IAM: remove role from instance profile → delete instance profile → detach policy → delete role
15. SNS topic

---

## Frequently Asked Questions

**Q: The NLB DNS resolves but connections time out or return nothing.**

A: The instances are likely still initialising or the web server has not yet
passed health checks. Wait 3–5 minutes and retry. If it persists:

1. Check that the ASG has launched instances: `aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names scalable-webapp-prod-asg`
2. Check target health: `aws elbv2 describe-target-health --target-group-arn <tg_arn>`
3. Verify NAT Gateways are `available` so the user data script could reach the internet to install the web server
4. Connect via SSM and inspect the web server: `aws ssm start-session --target <instance-id>`

**Q: All instances appear in only one Availability Zone.**

A: The `cpu-low` alarm fires at near-0% CPU when there is no traffic, which
triggers a scale-in that reduces `desired` to `asg_min_size`. If `asg_min_size`
is `1`, only one instance survives. Keep `asg_min_size` at `2` to guarantee
multi-AZ coverage, or restore desired capacity manually:

```bash
aws autoscaling set-desired-capacity \
  --auto-scaling-group-name scalable-webapp-prod-asg \
  --desired-capacity 2 \
  --region us-east-1
```

**Q: How do I add HTTPS?**

A: Request or import a certificate in ACM, then set `var.acm_certificate_arn`
in `prod.tfvars` and re-run `terraform apply`. A TLS listener on port 443 is
created automatically. To also redirect HTTP to HTTPS, add an `aws_lb_listener`
that replaces the TCP-80 listener with a redirect action — note that NLB
listeners use `redirect` only when using the `HTTP` protocol (ALB feature),
so the practical approach with an NLB is to handle the redirect in Nginx/Apache
configuration on the instance.

**Q: How do I update the application code?**

A: Update the user data script in `main.tf` and run `terraform apply`. Terraform
creates a new Launch Template version. To replace running instances without
downtime, trigger an instance refresh:

```bash
aws autoscaling start-instance-refresh \
  --auto-scaling-group-name scalable-webapp-prod-asg \
  --preferences MinHealthyPercentage=50,InstanceWarmup=300 \
  --region us-east-1
```

**Q: How do I enable remote Terraform state for a team?**

A: Create an S3 bucket (versioning enabled, SSE-S3 or SSE-KMS) and a DynamoDB
table with partition key `LockID` (String). Then uncomment the `backend "s3"`
block in `provider.tf`:

```hcl
backend "s3" {
  bucket         = "your-tfstate-bucket"
  key            = "scalable-webapp/terraform.tfstate"
  region         = "us-east-1"
  encrypt        = true
  dynamodb_table = "terraform-state-lock"
}
```

Re-run `terraform init` to migrate local state to S3.

**Q: Why Simple Scaling instead of Target Tracking?**

A: Simple Scaling gives a **dead band** between the scale-in and scale-out
thresholds (30%–70%), preventing oscillation when CPU hovers at a single value.
Target Tracking converges to a single target CPU percentage — any deviation
triggers immediate action in both directions. Simple Scaling also has an
explicit cooldown period per direction, which prevents rapid back-to-back
scaling actions. The trade-off is slower reaction to sudden spikes; if sub-60-
second scale-out is required, use a Target Tracking policy set to 50%–60% CPU.

**Q: Why is the NLB used instead of an ALB?**

A: The NLB operates at Layer 4 (TCP/TLS) and preserves the client's source IP
address natively. It handles millions of requests per second with ultra-low
latency, and supports static Elastic IP addresses per AZ — useful for
allowlisting in corporate firewalls. Use an ALB if you need HTTP-level features
such as path-based routing, host-based routing, request header manipulation,
or HTTP-to-HTTPS redirects.

---

## Deployment Issues Encountered

Real issues hit during the first deployment of this project, with root causes and fixes.

---

**Issue 1: `terraform apply` failed — "Invalid id: ami-00fa360e28f425da0 " (trailing space)**

**Symptom:** The Auto Scaling Group creation failed immediately with:
```
ValidationError: You must use a valid fully-formed launch template.
Invalid id: "ami-00fa360e28f425da0 "
```

**Root cause:** A trailing space was accidentally included when pasting the AMI ID into `prod.tfvars`:
```hcl
ami_id = "ami-00fa360e28f425da0 "   # ← trailing space after the ID
```
The Launch Template was created with the invalid AMI ID. The ASG then rejected
it at creation time because Auto Scaling validates the AMI ID against EC2.

**Fix:** Remove the trailing space in `prod.tfvars`:
```hcl
ami_id = "ami-00fa360e28f425da0"
```
Re-run `terraform apply`. Terraform updated the Launch Template in-place (v1 → v2)
and then created the ASG successfully. The 39 resources already created were not
affected — only the Launch Template was updated and the 5 remaining resources were
created.

**Prevention:** Always verify the AMI ID before applying:
```bash
grep ami_id prod.tfvars | cat -A   # cat -A shows trailing spaces as $
```

---

**Issue 2: `terraform apply` failed — WAFv2 association rejected by AWS**

**Symptom:** The original `main.tf` included `aws_wafv2_web_acl_association` linking
the WAF ACL to the NLB ARN. AWS rejected this with:
```
ValidationException: Resource ARN must be for an Application Load Balancer
```

**Root cause:** WAFv2 Web ACL associations are only supported on **Layer 7** resources
(ALB, API Gateway, AppSync, Cognito, App Runner, Verified Access). A Network Load
Balancer operates at **Layer 4 (TCP/TLS)** and cannot inspect HTTP headers — WAF has
nothing to intercept.

**Fix:** Removed the `aws_wafv2_web_acl_association` resource block from `main.tf`.
The `aws_wafv2_web_acl` resource itself is kept — the ACL is provisioned and its ARN
is exported — so it can be associated with an ALB if one is placed in front of the NLB
later.

**Prevention:** Check the [WAFv2 supported resource types](https://docs.aws.amazon.com/waf/latest/developerguide/waf-chapter.html) before adding a WAF association. NLB is not on the list.

---

**Issue 3: Both EC2 targets unhealthy — NLB health checks failing despite Nginx running**

**Symptom:** After `terraform apply` completed successfully, both targets showed
`Target.FailedHealthChecks` in the NLB target group. SSM confirmed Nginx was
`active` on both instances. TCP health checks on port 80 were still failing.

**Root cause:** The `aws_lb` resource was missing the `security_groups` argument:
```hcl
# BEFORE (broken)
resource "aws_lb" "web" {
  ...
  # security_groups not set — NLB had no SG attached
}
```
The EC2 security group allowed port 80 **only from the NLB security group**:
```hcl
ingress {
  security_groups = [aws_security_group.nlb.id]
}
```
Since the NLB had no SG attached, its network interfaces were not members of
`aws_security_group.nlb`. The EC2 SG rule never matched any traffic — including
NLB health check packets — so all connections were silently dropped.

**Fix:** Added `security_groups = [aws_security_group.nlb.id]` to the NLB resource:
```hcl
# AFTER (fixed)
resource "aws_lb" "web" {
  ...
  security_groups = [aws_security_group.nlb.id]
}
```
Because adding a security group forces NLB replacement, deletion protection
had to be disabled first:
```bash
aws elbv2 modify-load-balancer-attributes \
  --load-balancer-arn $(terraform output -raw nlb_arn) \
  --attributes Key=deletion_protection.enabled,Value=false
```
After `terraform apply`, both targets became healthy within 90 seconds (3 × 30 s
health check intervals).

**Prevention:** Always set `security_groups` on the `aws_lb` resource when you intend
to use security group references in target EC2 SG rules. Without it, the SG exists
but is not attached to the NLB's ENIs, and EC2 SG rules referencing it match nothing.

---

**Issue 4: `health_check.sh` — CloudWatch alarms section reported `[FAIL]` despite alarms existing**

**Symptom:** Running `./health_check.sh` showed:
```
[FAIL] No CloudWatch alarms found — were they deployed?
```
All 5 alarms were confirmed present via the AWS API.

**Root cause:** Two separate bugs combined to cause the failure.

*Bug A — Wrong alarm lookup method:* The script used `--alarm-names` with a
space-separated variable. Even a single unresolvable name in the list causes the
AWS CLI to return an empty result. This made the check fragile.

*Bug B — BSD `sed` whitespace parsing on macOS:* The `tfvar()` helper function
used `\s` in `sed` substitution patterns to strip whitespace around `=`:
```bash
sed 's/.*=\s*//; s/"//g; s/\s*$//'
```
macOS BSD `sed` does not reliably recognise `\s` as a whitespace class in all
contexts. When parsing `environment = "prod"`, the leading space after `=` was
not stripped, leaving `ENVIRONMENT=" prod"` (with a leading space). This caused
`ALARM_PREFIX` to become `scalable-webapp- prod` — a prefix that matched no
alarm names.

**Fix:**
1. Switched alarm lookup from `--alarm-names` to `--alarm-name-prefix "${ALARM_PREFIX}"` —
   prefix lookup returns all alarms sharing the prefix and never fails on a single
   missing name.
2. Replaced `\s` with `[[:space:]]` throughout the `tfvar()` sed pipeline and added
   an explicit leading-whitespace strip step for POSIX/BSD sed compatibility:
```bash
sed 's/.*=[[:space:]]*//' \
| sed 's/^[[:space:]]*//' \
| sed 's/[[:space:]]*$//' \
| sed 's/"//g'
```
3. Changed the `cpu-low` alarm from a `[FAIL]` condition to an informational note —
   it always fires on idle instances with no traffic, and `asg_min_size = 2` prevents
   it from actually scaling in below 2 instances.

**Prevention:** When writing shell scripts that parse `.tfvars` files on macOS, always
use POSIX character classes (`[[:space:]]`, `[[:alpha:]]`) instead of Perl-style
escapes (`\s`, `\w`) in `sed`, or switch to `grep -P` / `awk` for the parsing step.
