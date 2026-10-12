# Scalable Web App with ALB & Auto Scaling — Resume Summary

## Project Overview

A horizontally scalable web tier on AWS, provisioned with Terraform in `us-east-1` and layered onto a pre-existing VPC (`vpc-0b8ea2c5bf5093847`, `10.0.0.0/24`). An internet-facing Application Load Balancer (`WebAppALB`) listens on HTTP:80 and forwards to target group `WebApp-tg`. That target group is fed by an EC2 Auto Scaling Group (`WebAppASG`, min 1 / max 4) of `t3.medium` Amazon Linux 2 instances running Apache. On boot, each instance uses **IMDSv2** to read its own instance ID and Availability Zone and serves them on a landing page, which makes load balancing visible from a browser. The VPC had only a `us-east-1a` subnet, so the Terraform creates and owns a second public subnet in `us-east-1b` (`10.0.0.16/28`) and associates it with the existing public route table, giving the ALB and ASG two AZs. Scaling uses **two Step Scaling policies** driven by CloudWatch CPU alarms: +1 instance at 60-80% CPU, +2 above 80%, −1 below 40%. The 40-60% band is left as a dead band. The stack was deployed and audited on **8 June 2026**. `Result.md` and two console screenshots record the ALB active, the app responding through the ALB from `us-east-1b`, and ASG instances running in both AZs.

## Architecture

```
                                   Internet
                                      │ HTTP :80
                                      ▼
                    Internet Gateway  igw-076bdd124057cfb98  (pre-existing)
 ┌────────────────────────────────────┼────────────────────────────────────────┐
 │  VPC  vpc-0b8ea2c5bf5093847   10.0.0.0/24   (pre-existing)                  │
 │  Public route table  rtb-09ef904e894338594   0.0.0.0/0 → IGW                 │
 │                                    ▼                                        │
 │  ┌──────────────────────────────────────────────────────────────────────┐  │
 │  │  Application Load Balancer  WebAppALB  (internet-facing, WebApp-sg)  │  │
 │  │  Listener HTTP:80 ──► Target group WebApp-tg  (GET / → 200, 30 s)    │  │
 │  └───────────────┬──────────────────────────────────────┬───────────────┘  │
 │                  │                                      │                  │
 │  ┌───────────────▼───────────────┐   ┌──────────────────▼───────────────┐  │
 │  │ us-east-1a  10.0.0.0/28        │   │ us-east-1b  10.0.0.16/28          │  │
 │  │ subnet-017d9e213cb1cd657       │   │ subnet-0ff2ce1b2900affd6          │  │
 │  │ (pre-existing)                 │   │ (Terraform: aws_subnet.web_1b)    │  │
 │  │ EC2 t3.medium · AL2 · httpd    │   │ EC2 t3.medium · AL2 · httpd       │  │
 │  │ i-09d5334a060a575eb            │   │ i-09f631c6554220059               │  │
 │  └───────────────┬───────────────┘   └──────────────────┬───────────────┘  │
 │                  └──────────────┬───────────────────────┘                  │
 │                                 │  Auto Scaling Group WebAppASG            │
 │                                 │  min 1 · max 4 · ELB health, 120 s grace  │
 │                                 │  Launch template WebAppTemplate (v1)      │
 └─────────────────────────────────┼──────────────────────────────────────────┘
                                   │ CPUUtilization (AWS/EC2, per ASG, 60 s)
                                   ▼
 ┌─────────────────────────────────────────────────────────────────────────────┐
 │ CloudWatch  WebApp-cpu-high  > 60% for 2×60 s ──► step scale-out  +1 / +2   │
 │             WebApp-cpu-low   < 40% for 2×60 s ──► step scale-in   −1        │
 │             treat_missing_data = notBreaching                                │
 └─────────────────────────────────────────────────────────────────────────────┘
```

## Technology Stack

| Layer | Technology | Purpose |
|---|---|---|
| **Networking** | Pre-existing VPC + IGW + public route table; 1 Terraform-managed subnet | Second AZ (`us-east-1b`, `10.0.0.16/28`) added so the ALB and ASG span two AZs |
| **Load balancing** | Application Load Balancer + instance target group | HTTP:80 listener; `GET /` health check, 30 s interval, 2 healthy / 3 unhealthy, matcher `200` |
| **Compute** | EC2 Auto Scaling + launch template (`t3.medium`, Amazon Linux 2) | 1-4 instances, ELB health checks, 120 s grace period, detailed (1-minute) monitoring |
| **Web app** | Apache `httpd` via inline user data | Landing page showing instance ID + AZ fetched with IMDSv2 tokens |
| **Scaling** | Step Scaling policies + CloudWatch metric alarms | +1 (60-80%), +2 (>80%), −1 (<40%); `Average` aggregation |
| **AMI resolution** | `data "aws_ami"` (`amzn2-ami-hvm-2.*-x86_64-gp2`) | Latest Amazon Linux 2 resolved at plan time (`ami-046b36f55e189564a` at deploy) |
| **IaC** | Terraform `>= 1.6.0` (aws `~> 5.0`), provider `default_tags` | 16 managed resources; split `aws_vpc_security_group_*_rule` resources |
| **Alternative deploy** | AWS CLI (`Automation/deploy.sh`) | Imperative equivalent using Target Tracking policies |
| **Operations** | Bash (`Automation/check-alb.sh`) | Checks ALB state, target health counts, and HTTP reachability |

## Key Achievements

- **Extended an existing VPC to two AZs without taking it over** — Terraform creates only the `us-east-1b` subnet and its route-table association. The VPC, IGW, `us-east-1a` subnet, and route table stay external, and `concat(var.subnet_ids, [aws_subnet.web_1b.id])` feeds both the ALB and ASG.
- **Asymmetric Step Scaling with a dead band** — the scale-out policy has two steps (+1 at 60-80%, +2 above 80%) to react faster to sharp spikes, while scale-in removes one instance at a time below 40%. Nothing happens between 40% and 60%.
- **Load balancing you can see** — user data uses IMDSv2 (`PUT /latest/api/token`) to fetch instance ID and AZ. The screenshot records the ALB serving `i-09f631c6554220059` in `us-east-1b`, with a second instance `i-09d5334a060a575eb` in `us-east-1a`.
- **ELB-driven self-healing** — `health_check_type = "ELB"` means an instance that fails the ALB's `GET /` probe is replaced, not just deregistered.
- **Drift-aware ASG** — `ignore_changes = [desired_capacity]` stops `terraform apply` from undoing scaling activity. `create_before_destroy` on the ASG, launch template, and target group keeps replacements zero-gap.
- **Tag propagation handled explicitly** — provider `default_tags` covers normal resources, and the ASG repeats `Name`/`Environment`/`ManagedBy` as `tag {}` blocks with `propagate_at_launch = true`, because ASG instances do not inherit provider default tags.
- **Spurious scaling suppressed** — both alarms use `treat_missing_data = "notBreaching"`, so terminating instances that stop reporting metrics do not trigger extra scale-in.

## Infrastructure Components

Counts are Terraform resource blocks in `main.tf` (16 managed + 1 data source).

| Component | Count | Details |
|---|---|---|
| **Subnet + route-table association** | 2 | `aws_subnet.web_1b` (`subnet-0ff2ce1b2900affd6`, `10.0.0.16/28`, public IP on launch) → `rtb-09ef904e894338594` |
| **Security group + rules** | 5 | `WebApp-sg` (`sg-0638b502cb8e1f90d`) + ingress 22/80/443 from `0.0.0.0/0` + egress all |
| **Launch template** | 1 | `WebAppTemplate` (`lt-0aefb49318f24eb4d`, v1), `t3.medium`, key `WebApp-key-pair`, instance + volume tag specs |
| **Target group** | 1 | `WebApp-tg`, HTTP:80, target type `instance` |
| **ALB + listener** | 2 | `WebAppALB` (internet-facing, deletion protection off) + HTTP:80 forward listener |
| **Auto Scaling Group** | 1 | `WebAppASG`, min 1 / max 4, ELB health, 120 s grace, `$Latest` template version |
| **Scaling policies** | 2 | `WebApp-scale-out` (StepScaling +1 / +2) and `WebApp-scale-in` (StepScaling −1) |
| **CloudWatch alarms** | 2 | `WebApp-cpu-high` (>60%) and `WebApp-cpu-low` (<40%), 60 s period, 2 evaluation periods |
| **Data source** | 1 | `aws_ami.amazon_linux_2` |
| **Pre-existing (not managed)** | — | VPC, IGW `igw-076bdd124057cfb98`, subnet `subnet-017d9e213cb1cd657` (1a), public RT, key pair `WebApp-key-pair` |

## Deployment Issues Diagnosed & Resolved

The project has no dedicated troubleshooting log. The rows below are the behaviours and constraints recorded in `Result.md` and the README.

| Issue | Root cause | Fix |
|---|---|---|
| ASG dropped from 2 instances to `desired = 1` shortly after deploy | The `WebApp-cpu-low` alarm fired at ~0% CPU with no traffic (<40% for 2×60 s) and triggered the −1 scale-in policy | Documented as expected idle behaviour. `ignore_changes = [desired_capacity]` keeps Terraform from fighting it, and the README gives `aws autoscaling set-desired-capacity ... --desired-capacity 2` to restore. Recommended follow-ups: more `evaluation_periods` or a scale-in warm-up |
| ALB needed a second AZ, but the existing VPC had only a `us-east-1a` subnet | An ALB must be attached to subnets in at least two AZs | Terraform creates `aws_subnet.web_1b` (`10.0.0.16/28`) and associates it with the existing public route table |
| Instances in the new subnet had to reach package repos during boot | User data runs `yum update` / `yum install httpd`, which needs internet egress | Both subnets use the public route table (`0.0.0.0/0 → IGW`) with `map_public_ip_on_launch = true` |

## Test Results

From the 2026-06-08 audit in `Result.md` and the `screenshots/` folder. No automated test suite exists in this project folder. `Automation/check-alb.sh` checks state, target health, and HTTP reachability, but no captured run output is stored.

| Check | Result | Evidence |
|---|---|---|
| ALB state | PASS | `WebAppALB` active, internet-facing, across `us-east-1a` + `us-east-1b` |
| App reachable via ALB | PASS | `screenshots/webapp-running.png`: page served by `i-09f631c6554220059` in `us-east-1b` |
| Multi-AZ instances | PASS | `screenshots/ec2-instances.png`: 2 × `t3.medium` `WebApp-asg-instance`, one per AZ; `us-east-1b` instance 3/3 status checks |
| Target group health check config | PASS | `GET /` → `200`, thresholds 2/3 |
| Scale-out alarm | OK | `WebApp-cpu-high` in `OK` |
| Scale-in alarm | ALARM (expected) | `WebApp-cpu-low` in `ALARM` at idle, ASG scaled to `desired = 1` |
| Load / scaling test | Not recorded | No load test or scale-out event captured |

## Quick Start

```bash
# 1. Enter the project directory
cd "Scalable Web App with ALB & Auto Scaling"

# 2. Provide variables.tf + terraform.tfvars (both git-ignored in this repo)
#    Required: vpc_id, subnet_ids (1a), public_route_table_id, key_pair_name

# 3. Initialise, plan, and apply
terraform init
terraform plan  -var-file=terraform.tfvars
terraform apply -var-file=terraform.tfvars

# 4. Open the app and check health
terraform output alb_dns_name
bash Automation/check-alb.sh
```

> Allow 2-3 minutes after `apply` for instances to pass the ALB health check before traffic is forwarded.

## Cost Estimate

From the project README (`us-east-1`, on-demand, baseline at 2 instances).

| Resource | Quantity | Monthly (USD) |
|---|---|---|
| EC2 `t3.medium` | 2 (desired) | ~$60 |
| Application Load Balancer | 1 | ~$18 + LCU usage |
| CloudWatch alarms | 2 | ~$0.20 |
| **Total (baseline)** | | **~$78 / month** |

> Cost scales linearly with ASG size, up to 4 instances. The root portfolio README lists this project at ~$220/month, which does not match the project's own estimate. See the [AWS Pricing Calculator](https://calculator.aws/).

## Security Posture

| Topic | Posture |
|---|---|
| Shared security group | One SG (`WebApp-sg`) is attached to both the ALB and the instances, so instances accept 80/443 directly from `0.0.0.0/0`, not only from the ALB |
| SSH | `22` open to `0.0.0.0/0`; the README recommends restricting it or using SSM / EC2 Instance Connect |
| Transit encryption | HTTP:80 only; `443` is open but has no HTTPS listener or ACM certificate |
| Instance metadata | User data uses IMDSv2 tokens, but the launch template does not enforce `http_tokens = required` |
| Instance placement | Instances in public subnets with public IPs (needed for `yum` egress, as there is no NAT) |
| Secrets | None in the configuration; key pair `.pem` excluded by `.gitignore` |
| IAM | No instance profile attached |
| Deletion protection | `enable_deletion_protection = false` on the ALB |
| State | Local backend; README documents an S3 + DynamoDB backend as the upgrade |

## Project Structure

```
Scalable Web App with ALB & Auto Scaling/
├── README.md                 # Full documentation (14 sections)
├── Result.md                 # Live audit (2026-06-08): resource IDs, routing, alarm states
├── main.tf                   # Provider + default_tags, 1b subnet, SG, LT, TG, ALB, ASG, policies, alarms
├── outputs.tf                # ALB DNS/ARN, TG ARN, ASG name, LT ID/version, SG ID, AMI ID
├── .gitignore                # State, tfvars, .pem, and variables.tf excluded
├── screenshots/
│   ├── webapp-running.png    # App served through the ALB (instance ID + AZ)
│   └── ec2-instances.png     # ASG instances across both AZs
└── Automation/
    ├── deploy.sh             # AWS CLI equivalent (Target Tracking variant)
    ├── check-alb.sh          # ALB state, target health, HTTP 200 check
    └── .gitignore            # Excludes generated reports and build artifacts
```

> `variables.tf` is listed in `.gitignore` and was never committed, so the input declarations (and the validation rules the README describes) exist only in the README's Input Variables table. A fresh clone needs `variables.tf` recreated before `terraform plan` will run.

## Key Learnings & Technical Decisions

**Step Scaling for asymmetric control.** Target Tracking would be simpler, but one policy cannot express a dead band or different step sizes per direction. Two Step Scaling policies driven by two alarms scale out aggressively (+2 above 80%) and scale in conservatively (−1 below 40%), with no action between 40% and 60%. The AWS CLI variant in `Automation/deploy.sh` uses Target Tracking, which makes the trade-off concrete.

**Idle fleets will scale in, so plan for it.** With a 40% floor and no traffic, `cpu-low` stays in `ALARM` and the ASG trims to its minimum. That is the policy working as designed, but it means a "desired 2" stack runs 1 instance at rest. The cleaner fixes are a higher `asg_min` or a longer scale-in evaluation window, not a manual `set-desired-capacity`.

**Manage only what you need in a shared VPC.** The project adds exactly one subnet and one route-table association to an existing network. `terraform destroy` removes the `us-east-1b` subnet and leaves the VPC, IGW, `us-east-1a` subnet, and route table untouched, so it is safe to run against shared infrastructure.

**ASG tags are their own system.** Provider `default_tags` do not reach instances launched by an ASG, so the ASG repeats the tags as `tag {}` blocks with `propagate_at_launch = true`. Without them, cost allocation by `Environment`/`ManagedBy` would miss the most expensive resources.

## What I'd Do Differently

- **Split the security groups.** Use one SG for the ALB (80/443 from the internet) and one for instances (80 from the ALB SG only), so instances are not directly reachable.
- **Commit `variables.tf`** (and a `terraform.tfvars.example`) with the validation rules the README describes, so the project runs from a clean clone.
- **Move instances to private subnets behind NAT or VPC endpoints**, and replace the open `22` rule with SSM Session Manager via an instance profile.
- **Enforce IMDSv2** with `metadata_options { http_tokens = "required" }` in the launch template.
- **Add HTTPS** with an ACM certificate, a 443 listener, and an HTTP→HTTPS redirect.
- **Capture a scaling test.** Generate load (for example, `stress` on an instance), then record the scale-out to 2-4 instances and the scale-in back, so the Step Scaling behaviour is proven and not only configured.

## Summary

This project deploys a two-AZ, self-healing web tier in 16 Terraform resources layered onto a pre-existing VPC: an internet-facing ALB, an instance target group with `GET /` health checks, and a 1-4 instance EC2 Auto Scaling Group of Apache servers that report their instance ID and AZ via IMDSv2. Asymmetric Step Scaling (+1 / +2 out, −1 in) with a 40-60% dead band is driven by CloudWatch CPU alarms. The stack was deployed to `us-east-1` on 8 June 2026. The recorded evidence shows the ALB active, the app served through it from `us-east-1b`, instances in both AZs, and the expected idle scale-in to one instance. The main hardening steps are separate ALB and instance security groups, private subnets, enforced IMDSv2, HTTPS, and a committed `variables.tf`.
