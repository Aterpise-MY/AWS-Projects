# GitHub Actions CI/CD → AWS ECS (Fargate)

This project deploys a containerized web application to **Amazon ECS on Fargate** and wires up a **GitHub Actions** pipeline that builds, pushes, and releases a new image on every push to `main`. Terraform provisions a self-contained VPC, an **Application Load Balancer** in public subnets, and a Fargate **service** whose tasks run in private subnets. Public traffic enters through the ALB on port 80 and is round-robined across healthy tasks; **Application Auto Scaling** adds or removes tasks by tracking average CPU. The CI/CD pipeline registers a new task-definition revision per commit and performs a rolling ECS deployment, so shipping a change is a `git push`.

> Status: Terraform authored, `fmt`-clean and `validate`-clean; not yet applied to AWS. Figures below describe the authored footprint and design intent, not a live deployment.

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Networking & Routing](#2-networking--routing)
3. [Component Details](#3-component-details)
4. [CI/CD Pipeline](#4-cicd-pipeline)
5. [Directory Structure](#5-directory-structure)
6. [Prerequisites](#6-prerequisites)
7. [Quick Start](#7-quick-start)
8. [Input Variables](#8-input-variables)
9. [Outputs](#9-outputs)
10. [Scaling Behaviour](#10-scaling-behaviour)
11. [Tagging Strategy](#11-tagging-strategy)
12. [Security Considerations](#12-security-considerations)
13. [Cost Estimate](#13-cost-estimate)
14. [Destroying the Stack](#14-destroying-the-stack)
15. [Frequently Asked Questions](#15-frequently-asked-questions)

## 1. Architecture Overview

```
                              ┌──────────────────────┐
                              │   GitHub Actions      │
                              │  (push to main)       │
                              │  build → push → deploy│
                              └───────────┬──────────┘
                                          │ 1. docker push
                                          │ 2. update service
                                          ▼
        Internet                    ┌───────────┐
           │                        │    ECR     │  image:sha
           │ HTTP :80               └─────┬─────┘
           ▼                              │ pull
   ┌───────────────┐                      │
   │  Internet GW  │                      │
   └───────┬───────┘                      │
           │                              │
           ▼                              │
   ┌───────────────────────────┐          │
   │  Application Load Balancer │         │
   │  (public subnets, 2 AZs)   │         │
   └───────┬───────────────────┘          │ 
           │ forward → target group (ip)  │
   ┌───────┴──────────────────────────────┴───────────┐
   ▼                                                  ▼
┌────────────────────┐                       ┌────────────────────┐
│  Fargate task (AZ-a)│                      │  Fargate task (AZ-b)│
│  private subnet     │                      │  private subnet     │
│  container :80      │  ── logs ──▶ CloudWatch│  container :80     │
└─────────┬──────────┘   /ecs/gha-ecs        └─────────┬──────────┘
          │ outbound (image pull, APIs)                 │
          └──────────────▶ NAT Gateway ─────────────────┘
                                │
                                ▼
                          Internet GW
```

Traffic flow: Internet → Internet Gateway → ALB (public subnets) → Target Group (`type = ip`) → Fargate tasks (private subnets, port 80) → CloudWatch Logs. Task egress (image pulls, AWS API calls) leaves through a single NAT Gateway. Separately, GitHub Actions pushes each build to ECR and triggers a rolling update of the ECS service.

## 2. Networking & Routing

### VPC

| Attribute | Value |
|---|---|
| CIDR | `10.30.0.0/16` |
| DNS support / hostnames | Enabled |
| AZs spanned | 2 (configurable, 2–3) |

### Subnets

| Name | Type | CIDR (AZ-a / AZ-b) | Hosts |
|---|---|---|---|
| `gha-ecs-public-*` | Public | `10.30.0.0/24` / `10.30.1.0/24` | ALB, NAT Gateway |
| `gha-ecs-private-*` | Private | `10.30.10.0/24` / `10.30.11.0/24` | Fargate tasks |

### Route Tables

| Route Table | Association | Route | Target |
|---|---|---|---|
| `gha-ecs-public-rt` | Public subnets | `0.0.0.0/0` | Internet Gateway |
| `gha-ecs-private-rt` | Private subnets | `0.0.0.0/0` | NAT Gateway |

### Traffic Flow

```
 client ──HTTP:80──▶ ALB ──▶ target group (ip) ──▶ task :80
                      ▲                                  │
                      │                                  ▼
             public subnet                       private subnet
                                                        │
                                          outbound ▼ (0.0.0.0/0)
                                              NAT GW ──▶ IGW ──▶ Internet
```

> Tasks have no public IP. All inbound reaches them only via the ALB security group; all outbound is SNAT'd through the NAT Gateway.

## 3. Component Details

### 3.1 ALB Security Group (`gha-ecs-alb-sg`)

| Direction | Port | Protocol | Source / Destination |
|---|---|---|---|
| Ingress | 80 | TCP | `0.0.0.0/0` |
| Egress | All | All | `0.0.0.0/0` |

### 3.2 ECS Security Group (`gha-ecs-ecs-sg`)

| Direction | Port | Protocol | Source / Destination |
|---|---|---|---|
| Ingress | `container_port` (80) | TCP | ALB security group |
| Egress | All | All | `0.0.0.0/0` |

> The task SG only trusts the ALB SG as a source — tasks are never directly reachable from the internet.

### 3.3 ECR Repository (`northwind-storefront`)

| Attribute | Value |
|---|---|
| Tag mutability | `MUTABLE` |
| Scan on push | Enabled |
| Lifecycle policy | Expire untagged images after 14 days |
| `force_delete` | `true` (so `terraform destroy` can remove a non-empty repo) |

### 3.4 Task Definition (`gha-ecs-task`)

| Attribute | Value |
|---|---|
| Launch type | Fargate (`requires_compatibilities = ["FARGATE"]`) |
| Network mode | `awsvpc` |
| CPU / Memory | 256 (.25 vCPU) / 512 MiB |
| Container name | `my-container` (must match the workflow) |
| Bootstrap image | `public.ecr.aws/nginx/nginx:latest` |
| Log driver | `awslogs` → `/ecs/gha-ecs` |
| Execution role | Pull from ECR + write logs |
| Task role | App runtime identity (empty by default) |

> `container_definitions` is under `ignore_changes` — the pipeline registers new revisions with your ECR image and Terraform will not revert them.

### 3.5 Load Balancer (`gha-ecs-alb`)

| Attribute | Value |
|---|---|
| Type | Application (internet-facing) |
| Subnets | Public, both AZs |
| Listener | HTTP :80 → forward |

### 3.6 Target Group (`gha-ecs-tg`)

| Attribute | Value |
|---|---|
| Target type | `ip` (required for Fargate `awsvpc`) |
| Protocol / Port | HTTP / 80 |
| Health check path | `/` |
| Healthy / Unhealthy threshold | 2 / 3 |
| Interval / Timeout | 30s / 5s |
| Success matcher | `200-399` |

### 3.7 ECS Service (`gha-ecs-service`)

| Attribute | Value |
|---|---|
| Launch type | Fargate |
| Desired count | 2 (initial) |
| Subnets | Private, both AZs |
| Public IP | Disabled |
| Health check grace period | 60s |
| Ignored drift | `task_definition`, `desired_count` |

### 3.8 Scaling Policy & Target (`gha-ecs-cpu-target-tracking`)

| Attribute | Value |
|---|---|
| Policy type | Target Tracking |
| Metric | `ECSServiceAverageCPUUtilization` |
| Target value | 50% |
| Min / Max capacity | 2 / 6 |
| Scale-out cooldown | 60s |
| Scale-in cooldown | 300s |

## 4. CI/CD Pipeline

The workflow at `.github/workflows/deploy.yml` runs on every push to `main`:

| Step | Action | What it does |
|---|---|---|
| 1 | `actions/checkout@v4` | Clones the repo |
| 2 | `aws-actions/configure-aws-credentials@v4` | Authenticates the runner to AWS |
| 3 | `aws-actions/amazon-ecr-login@v2` | Logs Docker into ECR |
| 4 | `docker build/push` | Builds image, tags with `github.sha`, pushes to ECR |
| 5 | `amazon-ecs-render-task-definition@v1` | Injects the new image into `task-definition.json` |
| 6 | `amazon-ecs-deploy-task-definition@v2` | Registers the revision and rolls the ECS service (waits for stability) |

Required GitHub repository secrets:

| Secret | Example | Source |
|---|---|---|
| `AWS_ACCESS_KEY_ID` | `AKIA...` | IAM user / OIDC role |
| `AWS_SECRET_ACCESS_KEY` | `...` | IAM user |
| `AWS_REGION` | `us-east-1` | `region` variable |
| `ECR_REPOSITORY_NAME` | `northwind-storefront` | `ecr_repository_url` output |
| `ECS_CLUSTER` | `gha-ecs-cluster` | `ecs_cluster_name` output |
| `ECS_SERVICE` | `gha-ecs-service` | `ecs_service_name` output |

> For production, prefer **GitHub OIDC** with `configure-aws-credentials` (`role-to-assume`) over long-lived access keys — no static secrets to rotate.

## 5. Directory Structure

```
GitHub Actions ECS Deployment/
├── .github/
│   └── workflows/
│       └── deploy.yml            # CI/CD: build → push to ECR → deploy to ECS
├── main.tf                       # VPC, ALB, ECR, IAM, ECS cluster/service, autoscaling
├── variables.tf                  # Input variables with validation
├── outputs.tf                    # ALB DNS, ECR URL, cluster/service names, log group
├── versions.tf                   # Terraform + AWS provider constraints, default tags
├── task-definition.json          # Fargate task def rendered by the pipeline
├── terraform.tfvars.example      # Copy to terraform.tfvars and edit
├── .gitignore                    # Excludes state, .terraform/, tfvars
└── README.md                     # This file
```

## 6. Prerequisites

| Tool | Minimum Version | Install |
|---|---|---|
| Terraform | 1.5 | https://developer.hashicorp.com/terraform/install |
| AWS CLI | 2.x | https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html |
| Docker | 20.x | https://docs.docker.com/get-docker/ |
| gh (optional) | 2.x | https://cli.github.com/ |

Account-level requirements:
- An AWS account with permissions to create VPC, ELB, ECS, ECR, IAM, and CloudWatch resources.
- A GitHub repository with the six secrets above configured (Settings → Secrets and variables → Actions).
- A `Dockerfile` at the repository root for the pipeline's `docker build`.

## 7. Quick Start

```bash
# 1. Clone and enter the project
cd "GitHub Actions ECS Deployment"

# 2. Configure variables
cp terraform.tfvars.example terraform.tfvars
#    edit region / project_name / ecr_repository_name as desired

# 3. Provision the infrastructure (bootstraps with a public nginx image)
terraform init
terraform plan
terraform apply

# 4. Capture the values the pipeline needs
terraform output ecr_repository_url ecs_cluster_name ecs_service_name

# 5. Add them (plus AWS creds + region) as GitHub repository secrets,
#    commit a Dockerfile + your app, then:
git push origin main   # GitHub Actions builds, pushes, and deploys

# 6. Browse the app
terraform output alb_dns_name   # http://<alb-dns-name>
```

Allow 3–5 minutes for the ALB to register targets and health checks to pass.

## 8. Input Variables

| Variable | Type | Default | Description |
|---|---|---|---|
| `region` | string | `us-east-1` | AWS region to deploy into |
| `project_name` | string | `gha-ecs` | Base name for resources (lowercase, ≤31 chars) |
| `environment` | string | `prod` | Environment tag |
| `vpc_cidr` | string | `10.30.0.0/16` | VPC CIDR block |
| `az_count` | number | `2` | AZs to span (2–3) |
| `ecr_repository_name` | string | `northwind-storefront` | ECR repo the pipeline pushes to |
| `container_name` | string | `my-container` | Container name; **must match the workflow** |
| `container_image` | string | `public.ecr.aws/nginx/nginx:latest` | Bootstrap image for first apply only |
| `container_port` | number | `80` | Container + target group port |
| `task_cpu` | number | `256` | Fargate CPU units |
| `task_memory` | number | `512` | Fargate memory (MiB) |
| `desired_count` | number | `2` | Initial task count |
| `min_capacity` | number | `2` | Autoscaling minimum |
| `max_capacity` | number | `6` | Autoscaling maximum |
| `cpu_target_value` | number | `50` | Target CPU % for scaling |
| `health_check_path` | string | `/` | ALB health check path |
| `log_retention_days` | number | `14` | CloudWatch Logs retention |

> Validation rules: `project_name` must be lowercase alphanumeric/hyphen starting with a letter; `az_count` must be 2 or 3. `task_memory` must be a valid pairing for `task_cpu` (Fargate enforces this at apply time).

## 9. Outputs

| Output | Description |
|---|---|
| `alb_dns_name` | Public DNS name of the ALB (browse `http://<this>`) |
| `ecr_repository_url` | ECR repository URI for the pipeline |
| `ecs_cluster_name` | Cluster name → `ECS_CLUSTER` secret |
| `ecs_service_name` | Service name → `ECS_SERVICE` secret |
| `task_definition_family` | Task-def family (matches `task-definition.json`) |
| `task_execution_role_arn` | Execution role ARN |
| `cloudwatch_log_group` | Container log group |
| `vpc_id` | VPC ID |

```bash
terraform output ecs_service_name
# "gha-ecs-service"
```

## 10. Scaling Behaviour

Target tracking holds average CPU near **50%**. Above target it scales out (60s cooldown); below target it scales in conservatively (300s cooldown), within the 2–6 task band.

```
CPU %
 100 |                          ╭──╮
     |                      ╭──╯    ╰──╮        scale-out (60s cooldown)
  50 |······················•···········•·······  ← target 50%
     |          ╭────╮ ╭──╯               ╰──╮
   0 |──────────╯    ╰─╯                     ╰──── scale-in (300s cooldown)
     +--------------------------------------------------▶ time
      tasks: 2       2        3      4      4      3   2
                          dead-band = hysteresis between
                          scale-out and scale-in decisions
```

- **Dead-band / hysteresis:** the asymmetric cooldowns (fast out, slow in) prevent flapping — the service reacts quickly to load spikes but drains capacity gradually.
- **Evaluation period:** CloudWatch evaluates the CPU metric on a 1-minute cadence; target tracking manages the underlying alarms automatically.
- **Step size:** target tracking computes the step from the gap between actual and target CPU, so a big spike adds more tasks per adjustment than a small one — bounded by `max_capacity = 6`.

## 11. Tagging Strategy

| Tag Key | Value |
|---|---|
| `Project` | `GitHub-Actions-ECS` |
| `Environment` | `var.environment` (`prod`) |
| `ManagedBy` | `Terraform` |
| `Name` | Per-resource (`gha-ecs-*`) |

> `Project`, `Environment`, and `ManagedBy` are applied globally via the provider `default_tags` block, so every taggable resource inherits them without per-resource repetition. Per-resource `Name` tags are set individually.

## 12. Security Considerations

| Topic | Current posture | Recommended hardening |
|---|---|---|
| Listener protocol | HTTP :80 only | Add an HTTPS :443 listener with ACM cert; redirect 80→443 |
| Task exposure | Tasks in private subnets, no public IP | Keep; add VPC endpoints for ECR/CloudWatch to drop NAT for AWS traffic |
| CI/CD credentials | Static IAM access keys in GitHub secrets | Switch to GitHub OIDC (`role-to-assume`), no long-lived keys |
| Image scanning | ECR scan-on-push enabled | Gate deploys on scan results; add Trivy/Grype in CI |
| Task role | Empty (least privilege by default) | Attach only the specific policies the app needs |
| ALB access logging | Not enabled | Enable ALB access logs to S3 for audit |
| Secrets in container | None wired | Use SSM Parameter Store / Secrets Manager via task-def `secrets` |

## 13. Cost Estimate

Approximate `us-east-1` monthly cost for the default footprint (2 Fargate tasks @ .25 vCPU/0.5 GB running 24/7, 1 ALB, 1 NAT Gateway). Excludes data transfer and CloudWatch ingestion beyond free tier.

| Resource | Quantity | Monthly cost (USD) |
|---|---|---|
| Fargate vCPU | 0.25 vCPU × 2 tasks × 730h | ~14.79 |
| Fargate memory | 0.5 GB × 2 tasks × 730h | ~3.24 |
| Application Load Balancer | 1 (+ minimal LCU) | ~16.20 |
| NAT Gateway | 1 (hourly + minimal data) | ~32.40 |
| ECR storage | ~1 GB | ~0.10 |
| CloudWatch Logs | ~1 GB ingest/store | ~0.53 |
| **Total** | | **~67.26** |

> The **NAT Gateway is the largest line item.** For a dev/demo environment you can run tasks in public subnets with `assign_public_ip = true` and drop the NAT (removes ~$32/mo), or add VPC endpoints for ECR/S3/CloudWatch to cut NAT data-processing. See the [AWS Pricing Calculator](https://calculator.aws/).

## 14. Destroying the Stack

```bash
terraform destroy
```

Pre-steps and notes:
- The ECR repository uses `force_delete = true`, so `destroy` removes it even with images present. Remove this if you want destroy to fail on a non-empty repo.
- The ECS service scales to 0 and is deleted before the ALB/target group tear down (Terraform handles ordering).
- **Not managed by Terraform and will survive:** container images already pushed to ECR are deleted with the repo, but any manually created ECS task-definition revisions registered by the pipeline are **not** removed by `destroy` — deregister stale revisions manually if desired. CloudWatch log data is deleted with the log group.

## 15. Frequently Asked Questions

**Q: I get a 502/503 from the ALB right after deploying — why?**
A: Targets aren't healthy yet, or the container isn't listening on `container_port`. Check the target group health in the console, confirm the app binds `0.0.0.0:80`, and confirm the health check path returns `200-399`. The 60s grace period gives new tasks time before the ELB marks them unhealthy.

**Q: My tasks are all in one AZ — is that a risk?**
A: No. The service spreads tasks across the private subnets in both AZs, and the ALB is attached to public subnets in both AZs. With `desired_count = 2` you get one task per AZ; losing an AZ leaves the other serving traffic while ECS reschedules.

**Q: How do I add HTTPS?**
A: Request/import an ACM certificate, add an `aws_lb_listener` on port 443 with `protocol = "HTTPS"`, `certificate_arn`, and an SSL policy, then change the port-80 listener to redirect to 443. Point a Route 53 alias at the ALB DNS name.

**Q: How do I update the app code?**
A: Just `git push` to `main`. GitHub Actions builds a new image tagged with the commit SHA, pushes it to ECR, registers a new task-definition revision, and performs a rolling ECS deployment — no Terraform run needed. Terraform ignores that image/revision drift by design.

**Q: Why does Terraform ignore `task_definition` and `desired_count`?**
A: Because CI/CD and the autoscaler own them at runtime. Without `ignore_changes`, the next `terraform apply` would revert the service to the bootstrap image and reset the task count, undoing a deployment or a scale-out.

**Q: Should I use remote state?**
A: Yes for any shared/team use. Uncomment the `backend "s3"` block in `versions.tf`, pre-create the S3 bucket and DynamoDB lock table, then `terraform init -migrate-state`. Local state is fine for a solo demo.

**Q: Why target-tracking instead of step scaling?**
A: Target tracking is simpler and self-tuning — you declare the desired CPU (50%) and AWS manages the alarms and step sizes. Step scaling is worth it only when you need bespoke thresholds or non-CPU composite triggers.
