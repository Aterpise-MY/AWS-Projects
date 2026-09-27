# GitHub Actions CI/CD to AWS ECS (Fargate) — Resume Summary

> Source note: the project folder `GitHub Actions ECS Deployment/` is **not present in this repository**. This entry is written solely from the `### 14.` section of the root `README.md` and the other places that README mentions the project (Quick Navigation, Technology Stack, Cost Summary, Testing & Validation, Performance Benchmarks, and Repository Structure). Details the root README does not state — region, exact provider versions, individual resource names or IDs, output names, and a line-item cost breakdown — are deliberately left out rather than guessed.

> Status: Terraform authored and `terraform fmt` + `terraform validate`-clean; not yet deployed. Figures below describe the authored design, not a live deployment.

## Project Overview

A continuous-delivery pipeline that ships a containerized storefront API to Amazon ECS on Fargate on every push to `main`, built for an e-commerce team (Northwind Commerce) that needs zero-touch releases. Terraform provisions a self-contained VPC (2 public + 2 private subnets, an Internet Gateway, and a single NAT Gateway), an internet-facing Application Load Balancer, an ECS Fargate service whose tasks run in private subnets with no public IP, an ECR repository with scan-on-push, IAM roles, CloudWatch logging, and CPU-based Application Auto Scaling. A GitHub Actions workflow (`.github/workflows/deploy.yml`) builds each commit into a Docker image tagged with the commit SHA, pushes it to ECR, renders a new task-definition revision from `task-definition.json`, and performs a rolling ECS deployment that waits for service stability — so shipping a change is a `git push`. Terraform and the pipeline own disjoint parts of the service state, so a later `terraform apply` never reverts a deploy or a scale-out.

## Architecture

```
   Developer ── git push (main) ──┐
                                   ▼
        ┌──────────────────────────────────────────────────────┐
        │  GitHub Actions  .github/workflows/deploy.yml          │
        │  checkout → configure-aws-credentials → ecr-login      │
        │  → docker build/push :<github.sha>                     │
        │  → render task-definition.json → rolling ECS deploy    │
        │    (waits for service stability)                       │
        └───────────────┬──────────────────────────┬───────────┘
                        │ push image               │ new task-def revision
                        ▼                          │
               ┌─────────────────┐                 │
               │  Amazon ECR      │                 │
               │  scan-on-push    │                 │
               │  untagged → 14 d │                 │
               └────────┬────────┘                 │
                        │ pull (via NAT)           │
 Internet               │                          │
    │ HTTP :80          │                          │
    ▼                   │                          │
 ┌──────────────────────┼──────────────────────────┼───────────────┐
 │  VPC  (2 AZ)         │                          │               │
 │  ┌──── Public subnets (x2) ─────────────────────┼─────────────┐ │
 │  │  Internet Gateway   ALB (internet-facing)    │  NAT Gateway│ │
 │  │                     listener HTTP :80        │  (single)   │ │
 │  └──────────────────────────┬───────────────────┼──────▲──────┘ │
 │                             │ Target Group      │      │ egress │
 │                             │ type = ip         ▼      │ (SNAT) │
 │  ┌──── Private subnets (x2) ▼──────────────────────────┴──────┐ │
 │  │  ECS Fargate service  (tasks: no public IP)                  │ │
 │  │  task SG: ingress from ALB SG only                           │ │
 │  │  Application Auto Scaling: CPU 50% target, min 2 / max 6     │ │
 │  └──────────────────────────────┬──────────────────────────────┘ │
 └─────────────────────────────────┼────────────────────────────────┘
                                   ▼
                        ┌───────────────────────┐
                        │  CloudWatch Logs       │
                        └───────────────────────┘
```

## Technology Stack

| Layer | Technology | Purpose |
|---|---|---|
| **CI/CD** | GitHub Actions (`deploy.yml`) | Build → push to ECR → render task definition → rolling ECS deploy on every push to `main` |
| **Pipeline actions** | `configure-aws-credentials`, `amazon-ecr-login`, `amazon-ecs-deploy-task-definition` | AWS auth, registry login, and a deploy step that waits for service stability |
| **Registry** | Amazon ECR | SHA-tagged images, scan-on-push, lifecycle expiry of untagged images after 14 days |
| **Compute** | Amazon ECS on AWS Fargate | Storefront API tasks in private subnets with no public IP |
| **Load balancing** | Application Load Balancer + target group (`type = ip`) | Internet-facing HTTP :80 listener forwarding to healthy Fargate tasks |
| **Autoscaling** | Application Auto Scaling (target tracking) | CPU 50% target, min 2 / max 6 tasks, 60 s scale-out / 300 s scale-in cooldowns |
| **Networking** | VPC, 2 public + 2 private subnets, IGW, single NAT Gateway | Self-contained network; task egress SNAT'd through the NAT Gateway |
| **Identity** | AWS IAM | ECS / pipeline roles (role-level detail not described in the source) |
| **Observability** | Amazon CloudWatch Logs | Container logging for the Fargate tasks |
| **IaC** | Terraform (`main.tf`, `variables.tf`, `outputs.tf`, `versions.tf`) | Provider constraints and `default_tags` in `versions.tf`; input variables with validation |

## Key Achievements

- **`git push` is the deploy** — the workflow runs checkout → configure-aws-credentials → ecr-login → `docker build`/`push` tagged with `github.sha` → render task definition → rolling ECS deploy that waits for stability, so every commit to `main` is traceable to an image and a task-definition revision.
- **Terraform and the pipeline own disjoint state** — `ignore_changes` on `task_definition`, `desired_count`, and `container_definitions` means `terraform apply` never reverts a pipeline deploy or an autoscaling scale-out.
- **Tasks are never internet-reachable** — Fargate tasks run in private subnets with no public IP; the task security group trusts only the ALB security group; outbound traffic is SNAT'd through the NAT Gateway.
- **First-apply bootstrap without a chicken-and-egg problem** — the initial task definition uses `public.ecr.aws/nginx/nginx:latest`, so the service goes healthy before the ECR repository holds any images; the pipeline then takes over.
- **Fargate-correct load balancing** — target group `type = ip` (required for the Fargate `awsvpc` network mode), with the ALB's HTTP :80 listener forwarding to healthy tasks.
- **Elastic by default** — Application Auto Scaling target-tracking on CPU 50% between 2 and 6 tasks, with a fast 60 s scale-out and a conservative 300 s scale-in cooldown.
- **Registry hygiene** — ECR scan-on-push plus a lifecycle rule that expires untagged images after 14 days.
- **`terraform fmt` + `terraform validate`-clean** across the authored configuration.

## Infrastructure Components

Counts are those stated or directly implied by the root README; the source does not give a total resource count or individual resource names.

| Component | Count | Details |
|---|---|---|
| **VPC** | 1 | Self-contained, 2 AZ |
| **Subnets** | 4 | 2 public (ALB, NAT) + 2 private (Fargate tasks) |
| **Internet Gateway** | 1 | Public-subnet ingress/egress |
| **NAT Gateway** | 1 | Single, shared; the largest cost line item |
| **Application Load Balancer** | 1 | Internet-facing; HTTP :80 listener |
| **Target group** | 1 | `type = ip` for Fargate `awsvpc` tasks |
| **Security groups** | 2 (ALB + task) | Task SG admits traffic only from the ALB SG |
| **ECS cluster + Fargate service** | 1 + 1 | Tasks in private subnets, no public IP; rolling deployments |
| **ECR repository** | 1 | Scan-on-push; untagged images expire after 14 days |
| **Application Auto Scaling** | target + policy | CPU 50% target tracking, min 2 / max 6, 60 s / 300 s cooldowns |
| **IAM roles** | not specified | Listed as "IAM roles" in the source |
| **CloudWatch log group** | 1 | Output alongside ALB DNS, ECR URL, and cluster/service names |

## Deployment Issues Diagnosed & Resolved

None recorded. The project has **not been deployed**, and the root README documents no deployment issues, root causes, or fixes for it. The design-level decisions that pre-empt common failure modes (disjoint Terraform/pipeline state via `ignore_changes`, the public nginx bootstrap image for first apply, and target group `type = ip` for Fargate) are covered under Key Achievements and Key Learnings rather than presented as resolved incidents.

## Test Results

The project is not deployed; the table reflects static validation only, as recorded in the root README's Testing & Validation table.

| Check | Scope | Status |
|---|---|---|
| `terraform fmt` | Terraform configuration | Clean |
| `terraform validate` | Provider + resource schema | Clean |
| Live rolling deploy | GitHub Actions → ECR → ECS service stability | Pending deploy |
| ALB health checks | Target group health for Fargate tasks | Pending deploy |

No automated test counts are recorded for this project.

## Quick Start

The root README lists the files but not the exact deployment procedure; the steps below follow from those files.

```bash
# 1. Configure inputs from the provided template
cd "GitHub Actions ECS Deployment"
cp terraform.tfvars.example terraform.tfvars

# 2. Provision VPC, ALB, ECR, IAM, ECS cluster/service, and autoscaling
terraform init
terraform plan
terraform apply          # service boots on public.ecr.aws/nginx/nginx:latest

# 3. Read the ALB DNS name, ECR URL, cluster/service names, and log group
terraform output

# 4. Configure the workflow's AWS access in GitHub, then ship by pushing to main
git push origin main     # deploy.yml: build → push :<sha> → render task def → rolling deploy
```

> Allow 8-12 minutes for the stack to deploy and the Fargate tasks to pass ALB health checks.

## Cost Estimate

The root README gives a single figure of **~$67/month** for the default footprint and names its drivers, but does not publish a per-resource breakdown or the region; the table below reflects only what is stated.

| Resource | Quantity | Monthly (USD) |
|---|---|---|
| NAT Gateway | 1 (single) | Largest line item — not itemised in source |
| Application Load Balancer | 1 | Not itemised in source |
| Fargate tasks | 2 (autoscaling minimum) | Not itemised in source |
| **Total (default footprint)** | | **~$67 / month** |

> $0 while destroyed. The stated optimization is to drop the NAT Gateway by running tasks in public subnets or adding VPC endpoints.

## Security Posture

| Topic | Posture |
|---|---|
| Task exposure | Private subnets, no public IP; not internet-reachable |
| Network path | Task SG accepts traffic only from the ALB SG; egress via the single NAT Gateway |
| Transit (ALB) | HTTP :80 listener; no HTTPS listener is described in the source |
| Image provenance | Every image tagged with the commit SHA (`github.sha`); deployments are traceable to a commit |
| Image scanning | ECR scan-on-push |
| Registry hygiene | Untagged images expire after 14 days |
| Drift control | `ignore_changes` on `task_definition`, `desired_count`, `container_definitions` |
| Pipeline credentials | Obtained via `configure-aws-credentials`; the credential mechanism (OIDC vs keys) is not specified in the source |
| Secrets in Git | `.gitignore` excludes state, `.terraform/`, and `*.tfvars` |

## Project Structure

As listed in the root README's Repository Structure block:

```
GitHub Actions ECS Deployment/
├── .github/
│   └── workflows/
│       └── deploy.yml              # CI/CD: build → push to ECR → deploy to ECS
├── README.md                       # Full documentation (15 sections)
├── main.tf                         # VPC, ALB, ECR, IAM, ECS cluster/service, autoscaling
├── variables.tf                    # Input variables with validation
├── outputs.tf                      # ALB DNS, ECR URL, cluster/service names, log group
├── versions.tf                     # Terraform + AWS provider constraints, default_tags
├── task-definition.json            # Fargate task def rendered by the pipeline
├── terraform.tfvars.example        # Configuration template
└── .gitignore                      # Excludes state, .terraform/, *.tfvars
```

## Key Learnings & Technical Decisions

**Split ownership between Terraform and the pipeline explicitly.** Terraform creates the service; the pipeline changes what it runs; autoscaling changes how many run. Without `ignore_changes` on `task_definition`, `desired_count`, and `container_definitions`, every `terraform apply` would roll the service back to the Terraform-known revision and task count. Declaring the boundary in code lets both tools operate on the same service without fighting.

**Break the first-apply chicken-and-egg with a public bootstrap image.** On the very first apply the ECR repository is empty, so a task definition pointing at it would never go healthy. Seeding the service with `public.ecr.aws/nginx/nginx:latest` lets the ALB, target group, and service come up green immediately, and the first pipeline run replaces it with the real SHA-tagged storefront image.

**Fargate forces `awsvpc`, which forces `target_type = ip`.** Each Fargate task gets its own ENI and IP, so the target group must register IPs rather than instances. Combined with private subnets and an ALB-only task security group, this keeps tasks off the internet while still load-balancing directly to them.

**Asymmetric cooldowns for target tracking.** Scaling out after 60 s and in after 300 s reacts quickly to load while avoiding flapping when CPU briefly dips below the 50% target.

## What I'd Do Differently

- **Deploy and audit** — the stack is `validate`-clean but unproven; a live rolling deploy, ALB health checks, and a `Result.md` audit would turn design intent into verified behaviour.
- **Remove the NAT Gateway cost** — the root README's own optimization: VPC endpoints for ECR/Logs, or public-subnet tasks, since the NAT is the largest line item.
- **Add HTTPS** — an ACM certificate and a 443 listener in front of the storefront API; the documented listener is HTTP :80 only.
- **Pin and document the pipeline's AWS authentication** so the credential model is explicit in the entry and not only in the workflow file.

## Summary

This project demonstrates a zero-touch container delivery pipeline: a GitHub Actions workflow that turns every push to `main` into a SHA-tagged ECR image and a rolling ECS Fargate deployment that waits for stability, on top of Terraform-provisioned infrastructure — a 2-public / 2-private subnet VPC with a single NAT Gateway, an internet-facing ALB with an IP-type target group, private no-public-IP Fargate tasks guarded by an ALB-only security group, an ECR repository with scan-on-push and untagged-image expiry, and CPU target-tracking autoscaling between 2 and 6 tasks. Terraform and the pipeline own disjoint state through `ignore_changes`, and a public nginx bootstrap image makes the first apply healthy before any image exists. Status: `terraform fmt` + `validate`-clean, estimated at ~$67/month, and not yet deployed. This entry is based on the root README description because the project folder is not in this repository.
