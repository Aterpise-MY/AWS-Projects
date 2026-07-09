# Server Room Inspection Dashboard — Resume Summary

## Project Overview

An AWS-native rebuild of a Malaysian corporate factory's (MCF) legacy Power Automate + Ubuntu/EC2 server-room inspection system, delivered as a read-only operational dashboard for Facilities staff. The stack was designed and built as a series of **gated phases (0–6)** — networking, KMS, security groups, IAM, and secrets first (Phase 0), then RDS PostgreSQL (Phase 1), a schema-migration Lambda and a synthetic Glue backfill (Phase 2), the ECR + ECS Fargate + ALB dashboard tier (Phase 3), Cognito authentication (Phase 4), SES/EventBridge breach notifications (Phase 5), and CloudWatch/SNS observability plus an AD Connector (Phase 6) — now composed into a single Terraform root module. The full-stack path is `Internet → IGW → ALB (public) → Fargate task (private-app) → RDS PostgreSQL (private-data)`, with a single shared NAT Gateway, a customer-managed KMS key, three Secrets Manager placeholders, and reference-wired security groups enforcing the `ALB → app:8080 → data:5432` path by SG identity rather than CIDR. Everything targets account `022499047467` in `ap-southeast-1` (Singapore) under the resource prefix `mcf-srid-prod`. **The entire codebase is `terraform validate`-clean and authored to a deployable state, but it is not currently deployed** — the stack was destroyed to control cost, so this summary describes authored and validated infrastructure, not a live deployment. Two artifacts remain outstanding before the demo path can go fully live: the Flask dashboard **container image** (must be built and pushed to ECR) and, for HTTPS, an **ACM certificate + domain**.

## Architecture

```
                       Internet  (MCF office / staff)
                                  │  HTTP :80 (demo) / HTTPS :443 (Path A)
                                  ▼
                    Internet Gateway  mcf-srid-prod-igw
 ┌────────────────────────────────┼──────────────────────────────────────┐
 │  VPC  mcf-srid-prod-vpc   10.20.0.0/16      (2 AZ: 1a, 1b)             │
 │                                 │                                       │
 │  ┌──── Public tier ────────────▼──────────────────────────────────┐   │
 │  │  NAT GW + EIP (single, shared)   Application Load Balancer       │   │
 │  │  10.20.0.0/24 · 10.20.1.0/24     mcf-srid-prod-alb (alb-sg)      │   │
 │  └──────────┬───────────────────────────────────┬──────────────────┘   │
 │             │ 0.0.0.0/0 egress (private tiers)    │ TG → tcp/8080        │
 │             │                                     │ health GET /healthz  │
 │  ┌──────────▼──── Private-app tier ───────────────▼──────────────────┐  │
 │  │  10.20.10.0/24 · 10.20.11.0/24                                     │  │
 │  │  ECS Fargate task (desired 1)  0.25 vCPU / 0.5 GB                  │  │
 │  │  Flask + gunicorn :8080   app-sg (8080 from ALB SG only)          │  │
 │  │  image ← ECR mcf-srid-prod-dashboard   reads db secret via task role│ │
 │  │  [gated] migration Lambda · breach-notifier Lambda · Glue backfill │  │
 │  └───────────────────────────────────────┬───────────────────────────┘  │
 │                                           │ tcp/5432 (TLS forced)         │
 │  ┌────────────────────────────────────────▼──────────────────────────┐  │
 │  │  Private-data tier  10.20.20.0/24 · 10.20.21.0/24                   │  │
 │  │  RDS PostgreSQL 16.14  mcf-srid-prod-pg  db.t4g.micro  single-AZ    │  │
 │  │  data-sg (5432 from app SG + Glue SG only; egress VPC-CIDR only)    │  │
 │  └────────────────────────────────────────────────────────────────────┘  │
 │                                                                            │
 │  ┌── Account-wide / cross-cutting ────────────────────────────────────┐   │
 │  │ KMS CMK alias/mcf-srid  (RDS · ECR · logs · secrets · S3 backfill)  │   │
 │  │ Secrets Manager:  rds/credentials · ses/smtp · ad/bind-account      │   │
 │  │ Cognito user pool + hosted UI + OIDC client  (ALB auth gated HTTPS) │   │
 │  │ SES + EventBridge → breach-notifier Lambda   (gated: notifications) │   │
 │  │ CloudWatch dashboard + 8 alarms → SNS topic  ·  AD Connector (gated)│   │
 │  └─────────────────────────────────────────────────────────────────────┘  │
 └────────────────────────────────────────────────────────────────────────────┘
```

## Technology Stack

| Layer | Technology | Purpose |
|---|---|---|
| **Networking** | Amazon VPC (`10.20.0.0/16`), IGW, single shared NAT Gateway + EIP | 3-tier, 2-AZ layout (public / private-app / private-data), 6 subnets, 2 route tables |
| **Load balancing** | Application Load Balancer (internet-facing) + target group (`target_type = ip`) | HTTP:80 demo listener forwarding to Fargate on `tcp/8080`; `GET /healthz` probe |
| **Compute** | AWS ECS Fargate (0.25 vCPU / 0.5 GB, `awsvpc`) | Single-task Flask + gunicorn dashboard service in private-app subnets |
| **Registry** | Amazon ECR (`mcf-srid-prod-dashboard`) | KMS-encrypted image repo, `scan_on_push`, untagged-expiry lifecycle |
| **Database** | Amazon RDS PostgreSQL 16.14 (`db.t4g.micro`, single-AZ, gp3) | Private inspection store; `rds.force_ssl = 1`, PITR, Performance Insights |
| **Data loading** | AWS Lambda (migration) + AWS Glue (Python-shell backfill) | Applies 5 DDL files + creates `srid_app`; loads the 2,924-row synthetic CSV |
| **Security / crypto** | AWS KMS CMK, 4 reference-wired security groups | One CMK (`alias/mcf-srid`) reused across RDS/ECR/logs/secrets/S3; SG-identity path control |
| **Secrets** | AWS Secrets Manager (3 placeholder containers) | `rds/credentials`, `ses/smtp`, `ad/bind-account`; CMK-encrypted, populated per phase |
| **Auth** | Amazon Cognito (user pool + hosted UI + OIDC client) | Admin-create-only, MFA optional; ALB `authenticate-cognito` rule gated on HTTPS |
| **Notifications** | Amazon SES + EventBridge + Lambda (gated) | Scheduled breach-digest emails from `v_flagged_records` |
| **Observability** | CloudWatch dashboard + 8 metric alarms + SNS | ALB/ECS/RDS widgets and alarms fanned out to an alarms topic |
| **Directory** | AWS Directory Service (AD Connector, gated) | Deploy-ready on-prem AD integration, off pending Site-to-Site VPN |
| **IaC** | Terraform `>= 1.5` (aws `~> 5.0`, archive `~> 2.4`) | 12 reusable modules under one root; S3 remote state + S3-native locking |

## Key Achievements

- **Twelve-module phased architecture authored end-to-end** — `networking`, `kms`, `security`, `iam`, `secrets`, `database`, `migration`, `glue`, `compute`, `cognito`, `notifications`, and `observability`, each with its own `main.tf` / `variables.tf` / `outputs.tf`, composed by a single root `main.tf`.
- **Reference-wired security groups** — the `ALB → app:8080 → data:5432` path is enforced by SG identity, not CIDR ranges, using the provider-v5 split `aws_vpc_security_group_(ingress|egress)_rule` resources; the data tier egresses only to the VPC CIDR.
- **Single customer-managed KMS key reused across the stack** — one CMK (`alias/mcf-srid`) with rotation on encrypts RDS storage + Performance Insights, the ECR repo, CloudWatch log groups, all three secrets, and the Glue backfill bucket, with a dedicated CloudWatch Logs key-policy grant.
- **Gating discipline for cost and external dependencies** — HTTP ingress, HTTPS/Cognito ALB auth, SES notifications, and the AD Connector are all `count`/`for_each`-gated so a default `apply` is clean and gated phases cost nothing until enabled.
- **Least-privilege database access** — a `random_password`-generated `srid_app` login runs `SELECT`-only against `srid` schema views; the app fetches the DB secret at runtime via the ECS **task** role rather than a task-definition `secrets` block.
- **Secrets never committed to source** — three Secrets Manager containers seeded with placeholder versions, populated in place by the owning phase; generated passwords flow only through the encrypted S3 state backend.
- **Synthetic seed pipeline** — a 2,924-row synthetic legacy dataset (2 sites, 6 inspectors) generated and stored in a KMS-encrypted, versioned, public-access-blocked S3 bucket, loaded by a Glue Python-shell job through a `NETWORK`-type connection.
- **`terraform validate`-clean across all phases** — the whole root module validates without error, with cross-variable validation ensuring exactly one CIDR per AZ per tier before any AWS call.

## Infrastructure Components

Counts below are Terraform **resource declarations** authored across the 12 modules; some expand further at apply time via `for_each` (e.g. subnets and route-table associations materialize per-AZ).

| Component | Count | Details |
|---|---|---|
| **Terraform modules** | 12 | `networking`, `kms`, `security`, `iam`, `secrets`, `database`, `migration`, `glue`, `compute`, `cognito`, `notifications`, `observability` |
| **VPC / IGW / NAT / EIP** | 4 | `aws_vpc` + `aws_internet_gateway` + single shared `aws_nat_gateway` + `aws_eip` |
| **Subnets** | 3 blocks → 6 subnets | `aws_subnet` per tier via `for_each` over AZ (public / private-app / private-data) |
| **Route tables + routes + associations** | 6 | 2 `aws_route_table`, 2 `aws_route` (IGW / NAT), `aws_route_table_association` (×3 blocks) |
| **Security groups + rules** | 14 | 4 `aws_security_group` (ALB / app / data / Glue) + 6 ingress + 4 egress rules |
| **KMS** | 2 | `aws_kms_key` (rotation on) + `aws_kms_alias` |
| **Secrets Manager** | 2 → 3 secrets | `aws_secretsmanager_secret` + `_version` (RDS / SES / AD via `for_each`) |
| **IAM roles + policies** | 14 | 5 `aws_iam_role`, 5 `aws_iam_role_policy`, 4 `aws_iam_role_policy_attachment` |
| **RDS** | 5 | `aws_db_instance` + `aws_db_parameter_group` + `aws_db_subnet_group` + 2 `random_password` |
| **Lambda functions** | 2 | Migration Lambda (Phase 2) + breach-notifier Lambda (Phase 5, gated) + 1 permission |
| **Glue backfill** | 16 | S3 bucket (+ versioning/SSE/ownership/public-access-block), 2 `aws_s3_object`, `aws_glue_job`, `aws_glue_connection`, SG + IAM |
| **ECS + ALB (compute)** | 11 | `aws_ecs_cluster` + `aws_ecs_task_definition` + `aws_ecs_service` + `aws_lb` + listener + target group + `aws_ecr_repository` + lifecycle + log group + IAM |
| **Cognito** | 4 | `aws_cognito_user_pool` + client + domain + gated `aws_lb_listener_rule` |
| **SES notifications** | 7 | `aws_ses_configuration_set` + email identity + EventBridge rule/target + notifier Lambda + log group + IAM (all gated) |
| **Observability** | 12 | CloudWatch dashboard + 8 `aws_cloudwatch_metric_alarm` + SNS topic + subscription + AD Connector (`aws_directory_service_directory`, gated) |
| **Total authored resource blocks** | ~93 | Across all 12 modules (more at apply due to `for_each` expansion) |

## Design Decisions & Issues Resolved

| Topic | Consideration | Resolution |
|---|---|---|
| SG-identity vs CIDR path control | Hard-coding CIDRs between tiers is brittle and over-permissive | Reference-wired SGs — `app-sg` accepts `8080` only from `alb-sg`, `data-sg` accepts `5432` only from `app-sg`/`glue-sg`, so the path is enforced by SG identity |
| Secrets landing in Terraform state | Real credentials in a `secret_version` would sit in plaintext state | Seed three placeholder secret containers; populate in place per phase (`rds` from the DB module's sensitive output, `ses`/`ad` out of band), and keep state in the encrypted S3 backend |
| CloudWatch Logs + CMK encryption | A CMK-encrypted log group fails to write without an explicit key grant | Add a dedicated `AllowCloudWatchLogsToUseKey` statement (scoped by encryption context) to the CMK policy so ECS/Lambda log groups work without a compute-time key edit |
| SNS topic + CMK encryption | A CMK-encrypted SNS topic needs `cloudwatch.amazonaws.com` `kms:GenerateDataKey`/`Decrypt`, absent from the Phase 0 key | Ship the alarms topic SSE-off deliberately and document adding the grant as hardening rather than silently broadening the key policy |
| Cost of NAT and multi-AZ | Per-AZ NAT and Multi-AZ RDS roughly double the fixed cost of a small internal tool | `single_nat_gateway = true` (one shared NAT ~$33/mo) and `multi_az = false`, both flagged as one-line, non-destructive flips before production |
| Unauthenticated HTTP demo exposure | The demo ships HTTP:80 with `office_cidr = 0.0.0.0/0`, publishing inspection data | Gate the HTTP ingress rule (`enable_http_ingress`), document narrowing `office_cidr`, and wire Cognito ALB auth ready to enable once HTTPS (Path A) is in place |
| External artifacts Terraform can't create | HTTPS needs an ACM cert + domain; SES needs verified identities; AD needs a VPN | `count`/`for_each`-gate every dependent resource (`alb_https_enabled`, `enable_cognito_alb_auth`, `enable_notifications`, `enable_ad_connector`) so a default apply is clean and each phase turns on independently |
| Runtime secret retrieval | A task-definition `secrets` block ties the secret to deploy time | The app fetches `DB_SECRET_ARN` itself at startup via the ECS **task** role, decoupling secret rotation from task-definition revisions |
| CI/manual drift on ECS | Image deploys and manual scaling would show as Terraform drift | `lifecycle { ignore_changes = [task_definition, desired_count] }` on the service so `apply` doesn't fight CI or autoscaling |

## Validation Status

This project was **not deployed**; the table reflects static Terraform validation and design review, not live AWS tests. No `terraform apply` was run and no live resources were audited.

| Check | Scope | Status |
|---|---|---|
| `terraform validate` (root) | Whole composed stack (all 12 modules) | VALIDATE-CLEAN |
| Module structure | Each `modules/<name>/` has `main.tf` / `variables.tf` / `outputs.tf` | PRESENT |
| Provider / version pins | `versions.tf`: Terraform `>= 1.5`, aws `~> 5.0`, archive `~> 2.4` | RESOLVED (`.terraform.lock.hcl` present) |
| Cross-variable validation | Exactly one CIDR per AZ per tier (public / app / data) | ENFORCED at plan |
| Gating flags | HTTP ingress, HTTPS/Cognito auth, notifications, AD Connector `count`/`for_each`-gated | DEFAULT-APPLY CLEAN |
| Phase 0 (networking/kms/security/iam/secrets) | VPC, CMK, 4 SGs, 5 roles, 3 secrets | AUTHORED + VALIDATED |
| Phase 1 (database) | RDS PostgreSQL 16.14, parameter/subnet groups, passwords | AUTHORED + VALIDATED |
| Phase 2 (migration + glue) | Migration Lambda (zip built) + Glue backfill (2,924-row CSV) | AUTHORED + VALIDATED |
| Phase 3 (compute) | ECR + ECS Fargate + ALB + logs + IAM | AUTHORED + VALIDATED |
| Phase 4 (cognito) | User pool + client + domain + gated ALB rule | AUTHORED + VALIDATED |
| Phase 5 (notifications) | SES + EventBridge + notifier Lambda (gated OFF) | AUTHORED + VALIDATED |
| Phase 6 (observability) | Dashboard + 8 alarms + SNS + AD Connector (gated) | AUTHORED + VALIDATED |
| Live deployment / smoke tests | `apply`, health checks, live queries | NOT PERFORMED (stack not deployed) |

## Quick Start

```bash
# 1. Enter the terraform directory
cd "Server Room Inspection Dashboard/terraform"

# 2. (First time only) create the remote-state bucket
cd bootstrap && terraform init && terraform apply && cd ..

# 3. Initialise the root against the S3 backend (S3-native lockfile locking)
terraform init

# 4. Validate, review, and apply the whole stack (Phases 0-6; gated modules stay OFF)
terraform validate
terraform plan
terraform apply

# 5. Build and push the dashboard image so the ECS service can go healthy
aws ecr get-login-password --region ap-southeast-1 \
  | docker login --username AWS --password-stdin \
    022499047467.dkr.ecr.ap-southeast-1.amazonaws.com
docker build -t mcf-srid-prod-dashboard:latest .
docker tag  mcf-srid-prod-dashboard:latest "$(terraform output -raw ecr_repository_url):latest"
docker push "$(terraform output -raw ecr_repository_url):latest"

# 6. Run the schema migration, then the synthetic backfill, then hit the URL
aws lambda invoke --function-name "$(terraform output -raw migration_lambda_name)" /dev/stdout --region ap-southeast-1
aws glue start-job-run --job-name "$(terraform output -raw glue_backfill_job)" --region ap-southeast-1
terraform output dashboard_url        # http://<alb_dns_name>/overview
```

> Allow ~10-15 minutes for RDS to reach `available`, then ~2-3 minutes after the image is pushed for the Fargate task to pass health checks. Until a healthy image is in ECR the ALB returns `503`.

## Cost Estimate

Approximate `ap-southeast-1` on-demand pricing, 730 hrs/month, for the **default deploy** (Phases 0–4 + 6; notifications and AD Connector OFF). This is a design-time estimate — the stack is not deployed and incurs no cost while destroyed.

| Resource | Quantity | Monthly (USD) |
|---|---|---|
| NAT Gateway (hourly) | 1 shared | ~$32.85 |
| Elastic IP (attached) | 1 | $0.00 |
| KMS CMK | 1 | ~$1.00 |
| Secrets Manager | 3 secrets | ~$1.20 |
| S3 remote state + Glue backfill bucket | negligible | ~$0.10 |
| VPC / subnets / IGW / routes / SGs / IAM | — | $0.00 |
| RDS `db.t4g.micro` (single-AZ) | 730 hrs | ~$18.25 |
| RDS gp3 storage | 20 GiB | ~$2.76 |
| RDS logs / Performance Insights | low volume / free tier | ~$0.30 |
| Fargate vCPU + memory | 0.25 vCPU / 0.5 GB × 730 h | ~$11.25 |
| ALB (hourly) + ~1 LCU | 730 hrs | ~$19.40 |
| ECR storage | ~0.5 GB image | ~$0.05 |
| CloudWatch Logs (dashboard) | low ingest + 30-day | ~$1.00 |
| NAT data processing | image + secret pulls | ~$0.50 |
| CloudWatch dashboard + 8 alarms + SNS | 1 + 8 | ~$3.80 |
| **Total (estimate, active demo path)** | | **≈ $92 / month** |

> Gated phases add cost only when enabled: Phase 5 notifications are effectively cents, and the AD Connector Small adds ~$36/mo (`~$0.05/hr`) only when `enable_ad_connector = true`. The NAT Gateway is the single largest fixed cost.

## Security Posture

| Topic | Posture |
|---|---|
| Transit encryption (ALB) | Plain HTTP:80 for the demo; HTTPS (Path A) authored and gated on `alb_https_enabled` + an ACM cert |
| Application auth | Unauthenticated demo; Cognito user pool/client/domain created, ALB `authenticate-cognito` rule gated on HTTPS |
| ALB ingress scope | HTTP ingress `count`-gated (`enable_http_ingress`); `office_cidr` defaults to `0.0.0.0/0` and is documented to narrow for prod |
| Data-tier isolation | RDS private, no public IP; `data-sg` ingress `5432` from app/Glue SG only; egress VPC-CIDR only — no Internet path either direction |
| RDS transit | `rds.force_ssl = 1` — TLS forced for every client on the `mcf-srid-prod-pg16` parameter group |
| Least privilege (DB) | `srid_app` login; app session `SELECT`-only over `srid` views; runtime secret fetch via task role |
| Encryption at rest | One CMK (`alias/mcf-srid`, rotation on) across RDS + PI, ECR, CloudWatch Logs, all secrets, and the Glue bucket |
| Secrets | 3 Secrets Manager containers, CMK-encrypted; passwords generated in-module and kept out of source |
| IAM | 5 role stubs + resource-scoped inline policies; no wildcard-admin, no access keys |
| NAT resilience | Single shared NAT — `1a` impairment cuts egress for both AZs; `single_nat_gateway = false` documented as the pre-prod flip |
| Remote state | S3 backend, `encrypt = true`, S3-native lockfile; generated DB passwords live in state, so bucket IAM must stay restricted |
| Deletion safety | RDS `deletion_protection` default `false`, `skip_final_snapshot = true`; both flagged to harden for production |

## Project Structure

```
Server Room Inspection Dashboard/
├── README.md                         # Whole architecture (Phases 0-6)
├── PHASE1_RDS_SCOPE.md               # Phase 1 RDS design / approval artifact
├── PHASE1_PLAN_PREVIEW.txt           # Saved read-only terraform plan for Phase 1
├── PHASE3_DASHBOARD_DESIGN.md        # Approved dashboard + compute design
├── database/                         # SQL + job source consumed by Phase 2
│   ├── schema/
│   │   ├── 001_schema.sql            # Schema/namespace DDL
│   │   ├── 002_tables.sql            # sites / inspectors / inspection_log
│   │   ├── 003_indexes.sql           # Indexes
│   │   ├── 004_views.sql             # v_daily_summary / v_monthly_compliance / v_flagged_records
│   │   └── 005_roles_grants.sql      # srid_app least-privilege role + grants
│   ├── migration/
│   │   ├── build.sh                  # Packages the migration Lambda zip
│   │   ├── handler.py                # DDL runner / connectivity proof
│   │   └── .build/                   # Vendored psycopg2 + SQL (build workspace)
│   └── glue/
│       ├── backfill_job.py           # Synthetic backfill Glue job
│       ├── generate_synthetic_data.py
│       └── data/backfill_inspections.csv   # 2,924-row synthetic dataset
└── terraform/
    ├── main.tf                       # Root wiring for all 12 modules
    ├── variables.tf                  # Root input variables (all phases)
    ├── outputs.tf                    # Root outputs (all phases)
    ├── provider.tf                   # AWS provider + default_tags
    ├── versions.tf                   # Terraform >= 1.5; aws ~> 5.0, archive ~> 2.4
    ├── backend.tf                    # S3 remote state + S3-native lockfile
    ├── terraform.tfvars(.example)    # Non-secret config + template
    ├── bootstrap/                    # Creates the state bucket (local state)
    └── modules/
        ├── networking/               # VPC, subnets, IGW, single NAT, routes   [P0]
        ├── security/                 # 4 reference-wired SGs (+ gated HTTP:80)  [P0]
        ├── kms/                      # CMK + alias (+ CloudWatch Logs grant)    [P0]
        ├── iam/                      # ECS x2 + Lambda role stubs               [P0]
        ├── secrets/                  # 3 secret placeholders (db populated)     [P0/1]
        ├── database/                 # RDS PostgreSQL 16.14                     [P1]
        ├── migration/                # In-VPC migration Lambda (+ dist/*.zip)   [P2]
        ├── glue/                     # Glue backfill (bucket/job/connection)    [P2]
        ├── compute/                  # ECR + ECS Fargate + ALB + logs + IAM     [P3]
        ├── cognito/                  # User pool + domain + client + auth rule  [P4]
        ├── notifications/            # SES + EventBridge + notifier Lambda      [P5]
        └── observability/            # SNS + dashboard + 8 alarms + AD Connector[P6]
```

## Key Learnings & Technical Decisions

**Gated, phase-by-phase delivery keeps a default apply safe and cheap.** Rather than committing an all-or-nothing stack, each capability that depends on an external artifact — HTTPS (ACM cert + domain), Cognito ALB auth (HTTPS listener), SES notifications (verified identities), the AD Connector (Site-to-Site VPN) — is `count`/`for_each`-gated behind an `enable_*` flag. A `terraform apply` with defaults stands up the working demo path (Phases 0–4 + 6) and creates nothing that would fail validation or bill for an unusable resource. Each phase then turns on independently once its real-world prerequisite exists.

**Security-group identity is a stronger contract than CIDR.** The `ALB → app:8080 → data:5432` path is expressed by referencing SG IDs (`app-sg` accepts `8080` only from `alb-sg`; `data-sg` accepts `5432` only from `app-sg` and `glue-sg`) using the provider-v5 split ingress/egress rule resources. This survives subnet renumbering, documents intent, and means the data tier has no Internet path in either direction — its egress is scoped to the VPC CIDR.

**One CMK, many consumers, with the grants the services actually need.** A single customer-managed key (`alias/mcf-srid`, rotation on) encrypts RDS, Performance Insights, ECR, every CloudWatch log group, all three secrets, and the Glue bucket. The subtle part was the key policy: CloudWatch Logs needs an explicit `kms:Encrypt*`/`Decrypt` grant (scoped by log-group encryption context) or CMK-encrypted log groups silently fail to write, while the SNS alarms topic was deliberately left SSE-off because the Phase 0 key does not yet grant `cloudwatch.amazonaws.com`.

**Secrets and passwords stay out of source, and drift stays out of state.** Three placeholder secret containers are populated per phase rather than committed; the app reads its DB secret at runtime via the ECS task role instead of a task-definition `secrets` block; and `ignore_changes = [task_definition, desired_count]` on the service means CI image deploys and manual scaling never register as Terraform drift.

## What I'd Do Differently

- **Deploy and audit.** The stack is validate-clean but unproven against live AWS — an `apply`, a pushed image, and a `Result.md` audit would convert design confidence into verified behaviour and real health-check/query results.
- **Per-AZ NAT before any production cutover.** `single_nat_gateway = false` is the single most impactful resilience change; the shared NAT is an acceptable demo economy but a real single point of failure.
- **Ship the dashboard container image in-repo.** The Flask + gunicorn app is the outstanding required artifact; committing an `app/` folder and a build step would make the demo path self-contained.
- **Add Fargate autoscaling.** The service is pinned at `desired_count = 1`; an `aws_appautoscaling_target` + target-tracking policy on ECS `CPUUtilization` (already drift-safe via `ignore_changes`) would make the tier elastic.
- **Harden the notifier before enabling Phase 5.** The breach-notifier handler is a documented stub with psycopg2 wiring commented out — wire the query and email body, and add VPC endpoints (S3/ECR/SSM) to cut NAT data-processing.
- **Flip RDS to Multi-AZ and enable deletion protection + a final snapshot** for a genuine production posture.

## Summary

This project demonstrates a complete, phase-gated, AWS-native rebuild of a legacy on-prem inspection system — a 3-tier VPC feeding an internet-facing ALB, a single-task ECS Fargate dashboard, and a private RDS PostgreSQL store, wrapped with a single reused KMS CMK, three Secrets Manager placeholders, reference-wired security groups, Cognito authentication, SES/EventBridge notifications, and CloudWatch/SNS observability, plus a deploy-ready AD Connector. It comprises **12 Terraform modules and roughly 93 authored resource blocks** (expanding further at apply via `for_each` on the subnets and route-table associations), with a 2,924-row synthetic dataset ready for backfill. The entire codebase is **`terraform validate`-clean and authored to a deployable state, but it is not currently deployed** — it was destroyed to control cost, so all claims here reflect authored and validated infrastructure rather than a live deployment or live tests. Two artifacts remain before the demo can go fully live: the Flask dashboard container image and, for HTTPS, an ACM certificate + domain.
