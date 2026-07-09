# Server Room Inspection Dashboard (SRID) — MCF

An AWS-native rebuild of a Malaysian corporate factory's (MCF) legacy
Power Automate + Ubuntu/EC2 server-room inspection system. SRID delivers a
**read-only operational dashboard** for Facilities staff — at a glance, are both
plants (`P1`, `P2`) completing their twice-daily (AM/PM) inspections; what is the
monthly compliance percentage; which environmental readings breached the
threshold bands (temperature `18–27 °C`, humidity `40–60 %RH`, UPS voltage
`395–430 V`); and a filterable raw inspection log. A synthetic seed of **2,924
inspection rows** across **2 sites** and **6 inspectors** stands in for the real
cutover data. Traffic enters an internet-facing Application Load Balancer, is
forwarded to a single-task ECS Fargate service running a Flask + gunicorn app in
private subnets, which queries a private RDS PostgreSQL instance as the
least-privilege `srid_app` login. Everything is Terraform-managed against account
`022499047467` in `ap-southeast-1` (Singapore) under the resource prefix
`mcf-srid-prod`.

> **This README documents the complete, deployable architecture across Phases
> 0–6 as one whole.** The Terraform is `terraform validate`-clean but the stack
> is **not currently deployed** (it has been destroyed to control cost). Concrete
> resource IDs (`vpc-…`, `sg-…`, `subnet-…`) are assigned at `apply` time and are
> surfaced by `terraform output`; this document refers to resources by their
> stable **names** (`mcf-srid-prod-*`) rather than ephemeral IDs.

> **Two artifacts are required before the demo path is fully live and are NOT in
> this repository:** (1) the **dashboard container image** — the Flask app must be
> built and pushed to ECR before the ECS service can pass health checks; and
> (2) an **ACM certificate + domain** if you want HTTPS (the demo ships plain
> HTTP:80). Two further phases are **gated OFF by default**: **breach
> notifications** (needs verified SES identities) and the **AD Connector** (needs
> a Site-to-Site VPN to the on-prem domain controllers).

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

SRID was built in **gated phases**, each confirmed by the Boss before the next
began, but the Terraform now composes them into a single root module. The
full-stack path is: **Internet → IGW → ALB (public) → Fargate task (private-app)
→ RDS (private-data)**, with Cognito, SES/EventBridge notifications,
CloudWatch/SNS observability, KMS, Secrets Manager, and NAT wired around it.

```
                          ┌───────────────────────────────────────┐
                          │  Internet  (MCF office / staff)       │
                          └────────────────────┬──────────────────┘
                                               │  HTTP :80 (demo)  /  HTTPS :443 (Path A)
                          ┌────────────────────▼──────────────────┐
                          │  Internet Gateway  mcf-srid-prod-igw  │
                          └────────────────────┬──────────────────┘
   ┌───────────────────────────────────────────┼──────────────────────────────────────────┐
   │  VPC  mcf-srid-prod-vpc   10.20.0.0/16    │                                           │
   │  ┌──────── Public tier (2 AZ) ─────────────▼───────────────────────────────────────┐  │
   │  │  1a 10.20.0.0/24              1b 10.20.1.0/24                                     │  │
   │  │  ┌──────────────────────────┐   ┌─────────────────────────────────────────────┐ │  │
   │  │  │ NAT GW + EIP (single,     │   │ Application Load Balancer  mcf-srid-prod-alb│ │  │
   │  │  │ shared — cost control)    │   │ SG: alb-sg (443 always; 80 gated)           │ │  │
   │  │  └───────────┬──────────────┘   └───────────────────┬─────────────────────────┘ │  │
   │  └──────────────┼───────────────────────────────────────┼───────────────────────────┘ │
   │                 │ 0.0.0.0/0 egress for private tiers      │ target group → tcp/8080     │
   │                 │                                         │ health check GET /healthz   │
   │  ┌──────────────▼──── Private-app tier (2 AZ) ────────────▼──────────────────────────┐ │
   │  │  1a 10.20.10.0/24            1b 10.20.11.0/24                                       │ │
   │  │  ┌────────────────────────────────────────────────────────────────────────────┐  │ │
   │  │  │ ECS Fargate task (desired 1)  0.25 vCPU / 0.5 GB  Flask+gunicorn :8080       │  │ │
   │  │  │ SG: app-sg (8080 from ALB SG only)   image ← ECR  mcf-srid-prod-dashboard   │  │ │
   │  │  │ reads db secret at startup (task role) → connects as srid_app               │  │ │
   │  │  └───────────────────────────────────────┬────────────────────────────────────┘  │ │
   │  │  [gated] migration Lambda · breach-notifier Lambda · Glue backfill · AD Connector │ │
   │  └──────────────────────────────────────────┼────────────────────────────────────────┘ │
   │                                             │ tcp/5432 (TLS forced)                     │
   │  ┌──────────────────────────────────────────▼────────────────────────────────────────┐ │
   │  │  Private-data tier (2 AZ)  1a 10.20.20.0/24   1b 10.20.21.0/24                       │ │
   │  │  RDS PostgreSQL 16.14  mcf-srid-prod-pg  db.t4g.micro  single-AZ  private  gp3      │ │
   │  │  SG: data-sg (5432 from app SG only; egress VPC-CIDR only)                           │ │
   │  └─────────────────────────────────────────────────────────────────────────────────────┘ │
   │                                                                                          │
   │  ┌── Account-wide / cross-cutting ─────────────────────────────────────────────────────┐ │
   │  │ KMS CMK alias/mcf-srid  (RDS · ECR · logs · secrets · S3)                            │ │
   │  │ Secrets Manager:  rds/credentials · ses/smtp · ad/bind-account                       │ │
   │  │ Cognito user pool + hosted UI + OIDC client   (ALB auth rule gated on HTTPS)         │ │
   │  │ SES + EventBridge schedule → breach-notifier Lambda   (gated: enable_notifications)  │ │
   │  │ CloudWatch dashboard + 8 alarms → SNS alarms topic   ·   AD Connector (gated)        │ │
   │  └──────────────────────────────────────────────────────────────────────────────────────┘ │
   └────────────────────────────────────────────────────────────────────────────────────────────┘
```

**Traffic flow:** a staff browser hits the ALB in the public subnets on `:80`
(demo) or `:443` (Path A) → the ALB forwards to the Fargate task on `tcp/8080` in
the private-app subnets → the task opens a TLS-forced PostgreSQL connection on
`tcp/5432` to the private RDS instance in the private-data subnets and issues
`SELECT`-only queries as `srid_app`. The task reaches ECR, Secrets Manager, and
KMS **outbound** through the single shared NAT Gateway; container stdout/stderr
ships to a CMK-encrypted CloudWatch log group. There is **no public path to the
Fargate task or the database** — only the ALB is internet-facing.

> Authentication is **Cognito-native for the demo**; an **AD Connector**
> integration is written deploy-ready but deliberately **not applied** (it needs a
> Site-to-Site VPN to on-prem). Seed data is **synthetic** until a real cutover is
> approved.

---

## Networking & Routing

### VPC

| Field | Value |
|---|---|
| **Name** | `mcf-srid-prod-vpc` |
| **CIDR Block** | `10.20.0.0/16` |
| **Availability Zones** | `ap-southeast-1a`, `ap-southeast-1b` |
| **Tiers** | 3 (public, private-app, private-data) × 2 AZ = 6 subnets |
| **DNS Hostnames / Support** | Enabled |
| **Managed by** | `module.networking` (native `aws_vpc`, not a community module) |

### Subnets

| Name | AZ | CIDR | Tier | Hosts |
|---|---|---|---|---|
| `mcf-srid-prod-public-ap-southeast-1a` | `1a` | `10.20.0.0/24` | Public | NAT Gateway, ALB node |
| `mcf-srid-prod-public-ap-southeast-1b` | `1b` | `10.20.1.0/24` | Public | ALB node |
| `mcf-srid-prod-app-ap-southeast-1a` | `1a` | `10.20.10.0/24` | Private-app | Fargate task, Lambda/Glue ENIs |
| `mcf-srid-prod-app-ap-southeast-1b` | `1b` | `10.20.11.0/24` | Private-app | Fargate task |
| `mcf-srid-prod-data-ap-southeast-1a` | `1a` | `10.20.20.0/24` | Private-data | RDS primary |
| `mcf-srid-prod-data-ap-southeast-1b` | `1b` | `10.20.21.0/24` | Private-data | RDS subnet-group member |

> Public subnets set `map_public_ip_on_launch = true`. The Glue backfill
> connection ENIs land in the **first** private-app subnet (`1a`), selected via
> `module.networking.app_subnets_by_az`.

### Route Tables

| Route Table | Subnets | Destination | Target |
|---|---|---|---|
| `mcf-srid-prod-rt-public` | 2 × public | `10.20.0.0/16` | local |
| `mcf-srid-prod-rt-public` | 2 × public | `0.0.0.0/0` | Internet Gateway |
| `mcf-srid-prod-rt-private` | 2 × app + 2 × data | `10.20.0.0/16` | local |
| `mcf-srid-prod-rt-private` | 2 × app + 2 × data | `0.0.0.0/0` | NAT Gateway |

> **Single shared NAT Gateway.** `single_nat_gateway = true` places one NAT in
> `1a` and routes **both** private tiers through it via one shared private route
> table. This is a deliberate cost choice (~$33/mo vs ~$66/mo for one NAT per AZ)
> — it accepts that an `1a` impairment removes outbound Internet for private
> resources in both AZs. Set `single_nat_gateway = false` for one NAT + EIP per AZ
> and per-AZ private route tables before any production cutover requiring
> AZ-independent egress.

### Traffic Flow

```
Internet
    │  :80 / :443
    ▼  0.0.0.0/0 → Internet Gateway
Public tier (10.20.0.0/24, 10.20.1.0/24)
    │  ALB  ── target group ──► tcp/8080, health check GET /healthz
    │  NAT Gateway + EIP  ── 0.0.0.0/0 return path for private tiers
    ▼
Private-app tier (10.20.10.0/24, 10.20.11.0/24)   Fargate task :8080
    │  app SG → data SG : tcp/5432 (TLS forced)
    ▼
Private-data tier (10.20.20.0/24, 10.20.21.0/24)  RDS PostgreSQL

Outbound (private → NAT → IGW → Internet): ECR image pull, Secrets Manager,
KMS, SES, package installs. Inbound app path terminates at the ALB only.
```

---

## Component Details

Each sub-section documents what the Terraform actually creates. Reference-wired
security groups mean the `ALB → app:8080 → data:5432` path is enforced by SG
identity, not CIDR.

### 1. VPC, Subnets, IGW & NAT (`module.networking`)

| Attribute | Value |
|---|---|
| VPC CIDR | `10.20.0.0/16`, DNS support + hostnames enabled |
| Subnets | 6 (`for_each` over AZ → CIDR map), tagged `Tier` = public / private-app / private-data |
| Internet Gateway | `mcf-srid-prod-igw`, attached; public RT default route |
| NAT Gateway | 1 (single, shared), `mcf-srid-prod-nat-0` in public `1a` + one EIP |
| Route tables | 1 public (→ IGW), 1 private (→ NAT), associations for all 6 subnets |

> The NAT Gateway is the dominant fixed cost of the network tier (~$33/mo even at
> idle). VPC endpoints (S3/ECR/SSM) could cut NAT data-processing later.

### 2. Security Groups (`module.security`)

Rules use the provider-v5 split `aws_vpc_security_group_(ingress|egress)_rule`
resources.

#### ALB SG (`mcf-srid-prod-alb-sg`, `Tier = public`)

| Direction | Protocol | Port | Source / Dest | Purpose |
|---|---|---|---|---|
| Inbound | TCP | 443 | `0.0.0.0/0` | HTTPS from clients (always present) |
| Inbound | TCP | `alb_listener_port` (80) | `office_cidr` | **Gated** HTTP demo — created only when `enable_http_ingress = true` |
| Outbound | TCP | 8080 | app SG | Forward to Fargate tasks |

> **Production caveat (unauthenticated demo):** the HTTP:80 ingress defaults to
> `office_cidr = "0.0.0.0/0"`. Because Phase 3 ships **without application auth**,
> narrow `office_cidr` to the MCF office egress CIDR, or move to HTTPS + Cognito
> (Phase 4). Leaving it open publishes inspection data (plant names, inspector
> `sam_account_name`, readings) to anyone who finds the ALB DNS name.

#### App SG (`mcf-srid-prod-app-sg`, `Tier = private-app`)

| Direction | Protocol | Port | Source / Dest | Purpose |
|---|---|---|---|---|
| Inbound | TCP | 8080 | ALB SG | Traffic from the ALB only |
| Outbound | All | All | `0.0.0.0/0` | AWS APIs, ECR, Secrets, package pulls (via NAT) |

#### Data SG (`mcf-srid-prod-data-sg`, `Tier = private-data`)

| Direction | Protocol | Port | Source / Dest | Purpose |
|---|---|---|---|---|
| Inbound | TCP | 5432 | app SG | PostgreSQL from the app tier |
| Inbound | TCP | 5432 | Glue SG | PostgreSQL from the Glue backfill (added by `module.glue`) |
| Outbound | All | All | VPC CIDR `10.20.0.0/16` | Intra-VPC only — no Internet egress |

> The data SG egresses **only** to the VPC CIDR by design. The database tier has
> no Internet path in either direction.

### 3. KMS Customer-Managed Key (`module.kms`)

| Attribute | Value |
|---|---|
| Alias | `alias/mcf-srid` |
| Rotation | `enable_key_rotation = true` |
| Deletion window | `deletion_window_in_days` (default 30) |
| Key policy grants | Root admin; `secretsmanager`/`rds`/`s3` service use (account-scoped); `logs.ap-southeast-1.amazonaws.com` scoped by log-group encryption context |
| Reuse | RDS storage + PI, ECR repo, CloudWatch Logs, Secrets Manager, Glue backfill bucket |

> The dedicated `AllowCloudWatchLogsToUseKey` statement is what lets the
> CMK-encrypted ECS and Lambda log groups work without a key-policy edit at
> compute time.

### 4. Secrets Manager Placeholders (`module.secrets`)

Three secret **containers** are created with a version holding **placeholder**
(empty) values; each is populated in place by the phase that owns it — no second
secret or version resource is ever created.

| Secret Name | Populated by | Payload keys |
|---|---|---|
| `mcf-srid-prod/rds/credentials` | Phase 1 (in place, when `db_connection.host != ""`) | `engine, host, port, dbname, username, password, app_username, app_password` |
| `mcf-srid-prod/ses/smtp` | Phase 5 (out of band) | `smtp_username, smtp_password, smtp_host, smtp_port, from_address` |
| `mcf-srid-prod/ad/bind-account` | AD Connector phase (out of band) | `directory_id, domain, bind_dn, bind_password` |

> Generated passwords reach the db secret only via the database module's
> **sensitive** `db_connection` output. Passwords therefore live in Terraform
> state — keep state in the encrypted S3 backend.

### 5. IAM Role Stubs (`module.iam`)

Created up front so later phases attach scoped inline policies to a stable ARN.

| Role Name | Trust | Baseline policy | Runtime consumer |
|---|---|---|---|
| `mcf-srid-prod-ecs-task-execution` | `ecs-tasks.amazonaws.com` | `AmazonECSTaskExecutionRolePolicy` (managed) | ECS agent: image pull, log write |
| `mcf-srid-prod-ecs-task` | `ecs-tasks.amazonaws.com` | none (runtime identity) | Dashboard app: reads db secret |
| `mcf-srid-prod-lambda-exec` | `lambda.amazonaws.com` | `AWSLambdaBasicExecutionRole` (managed) | Breach-notifier Lambda |

> `module.compute` attaches an inline `…-ecs-exec-extra` policy (ECR pull + log
> write + `kms:Decrypt`) to the execution role and a `…-ecs-task-extra` policy
> (`secretsmanager:GetSecretValue` + `kms:Decrypt`) to the task role. The
> **migration Lambda** uses its own dedicated role (`…-migration-lambda`), not the
> shared stub.

### 6. RDS PostgreSQL (`module.database` — Phase 1)

| Attribute | Value |
|---|---|
| Identifier | `mcf-srid-prod-pg` |
| Engine | `postgres 16.14` |
| Instance class | `db.t4g.micro` (2 vCPU burstable, 1 GiB RAM) |
| Storage | gp3, `20` → `50` GiB autoscale, CMK-encrypted |
| Availability | Single-AZ (`multi_az = false`) |
| Exposure | Private (`publicly_accessible = false`); data SG; port `5432` |
| Transit | Parameter group `mcf-srid-prod-pg16`: `rds.force_ssl = 1`, slow-query (`>1s`) + connection/disconnection logging |
| Subnet group | `mcf-srid-prod-db-subnets` (private-data `1a` + `1b`) |
| Backups | 7-day retention + PITR; window `17:00–17:30 UTC` (= `01:00–01:30 SGT`) |
| Monitoring | Performance Insights (7-day, CMK-encrypted); logs exports `postgresql`, `upgrade` |
| Credentials | `random_password` master (`srid_admin`) + app (`srid_app`), 32 chars |

> **Availability trade-off:** single-AZ is an approved right-sizing choice for a
> 2-room tool. Flipping to Multi-AZ is a non-destructive `multi_az = true` change.

> The module sets `deletion_protection` (default `false` in the module var) and
> `skip_final_snapshot = true`. Set `deletion_protection = true` and a final
> snapshot before treating this as production.

### 7. Migration Lambda (`module.migration` — Phase 2)

| Attribute | Value |
|---|---|
| Function | `mcf-srid-prod-migration`, `python3.12`, x86_64, 256 MB, 120s timeout |
| Package | `terraform/modules/migration/dist/migration.zip` (bundles `handler.py` + psycopg2) |
| Placement | Private-app subnets, app SG (reaches data SG:5432) |
| Role | Dedicated `…-migration-lambda`: `AWSLambdaVPCAccessExecutionRole` + inline `GetSecretValue` + `kms:Decrypt` |
| Log group | `/aws/lambda/mcf-srid-prod-migration` (CMK-encrypted) |
| Job | Applies the 5 DDL files (`001`–`005`) and creates + password-sets the `srid_app` role |

### 8. Glue Backfill (`module.glue` — Phase 2)

| Attribute | Value |
|---|---|
| Bucket | `mcf-srid-prod-backfill-022499047467-apse1` (SSE-KMS, versioned, public-access-blocked, `force_destroy`) |
| Objects | `scripts/backfill_job.py` + `raw/backfill_inspections.csv` (the 2,924-row synthetic legacy dataset) |
| Connection | `mcf-srid-prod-rds-network` (`NETWORK` type — VPC placement, no stored creds) |
| Glue SG | `mcf-srid-prod-glue-sg` (self-ref all-TCP as Glue requires; egress all) |
| Job | `mcf-srid-prod-backfill`, Python-shell 3.9, `max_capacity = 1.0`, `psycopg2-binary==2.9.9` |
| Role | `mcf-srid-prod-glue-backfill`: `AWSGlueServiceRole` + inline S3 read / secret read / CMK use |

### 9. ECR Repository (`module.compute` — Phase 3)

| Attribute | Value |
|---|---|
| Name | `mcf-srid-prod-dashboard` |
| Encryption | KMS with `alias/mcf-srid` |
| Scanning | `scan_on_push = true` |
| Lifecycle | Expire untagged images 7 days after push |
| Mutability | `MUTABLE` |

> **Required artifact:** the repo is created empty. The dashboard image must be
> built and pushed (`…:latest` by default, see `image_tag`) **before** the ECS
> service can pull it and reach a healthy state.

### 10. ECS Cluster, Task Definition & Service (`module.compute` — Phase 3)

| Attribute | Value |
|---|---|
| Cluster | `mcf-srid-prod` (Container Insights off by default) |
| Task family | `mcf-srid-prod-dashboard`, Fargate, `awsvpc`, LINUX/X86_64 |
| Size | `container_cpu = 256` (0.25 vCPU), `container_memory = 512` (0.5 GB) |
| Container | `dashboard`, image `…/mcf-srid-prod-dashboard:<image_tag>`, port `8080` |
| Env | `DB_SECRET_ARN`, `AWS_REGION`, `APP_PORT` — app fetches the secret itself via the **task** role (no task-def `secrets` block) |
| Logs | `awslogs` → `/ecs/mcf-srid-prod-dashboard` (CMK-encrypted, 30-day retention) |
| Service | `mcf-srid-prod-dashboard`, `desired_count = 1`, private-app subnets, app SG, `assign_public_ip = false`, 60s health-check grace |
| Lifecycle | `ignore_changes = [task_definition, desired_count]` so CI image deploys / manual scale don't show as drift |

### 11. Application Load Balancer, Listener & Target Group (`module.compute` — Phase 3)

| Attribute | Value |
|---|---|
| ALB | `mcf-srid-prod-alb`, internet-facing, public subnets, ALB SG |
| Target group | `mcf-srid-prod-tg`, `target_type = ip`, HTTP:8080, dereg delay 30s |
| Health check | `GET /healthz`, matcher `200`, interval 30s, healthy 2 / unhealthy 3 |
| Listener | HTTP on `alb_listener_port` (default `80`), default action forward → TG |
| Dashboard URL | `http://<alb_dns_name>/overview` |

> **Production caveat (HTTP not HTTPS):** the listener is plain HTTP for the demo.
> For HTTPS (Path A) set `alb_listener_port = 443`, add an ACM certificate + a
> `certificate_arn` on the listener, and set `alb_https_enabled = true` — this
> also unlocks Phase 4 ALB Cognito auth. An ACM cert needs a domain the Boss
> controls (Route 53 or external CNAME validation).

### 12. Dashboard Application (routes & data model — required artifact)

The app is **server-rendered Flask + Jinja + gunicorn** (2 workers) on
`0.0.0.0:8080`, `SELECT`-only, connecting as `srid_app`. Routes map directly to
the `srid` schema views:

| Route | Page | Backing object(s) |
|---|---|---|
| `GET /overview` | KPI tiles + trend charts | `v_daily_summary`, `v_monthly_compliance`, `v_flagged_records` (count) |
| `GET /log` | Paginated, filterable inspection log | `inspection_log` ⋈ `sites` ⋈ `inspectors` |
| `GET /flagged` | Breach table with coloured badges | `v_flagged_records` (`breach_reasons` array) |
| `GET /healthz` | ALB health probe (no UI) | liveness / optional `SELECT 1` |

Data model (`database/schema/`): tables `sites` (P1/P2), `inspectors`
(AD-backed `sam_account_name`), `inspection_log` (one row per plant per shift,
`UNIQUE(source_site, inspection_date, shift)`); views `v_daily_summary`,
`v_monthly_compliance`, `v_flagged_records`. Threshold bands live in the
`v_flagged_records` definition (temp `18–27 °C`, humidity `40–60 %RH`, UPS
`395–430 V`) so a single `ALTER VIEW` re-tunes them.

> **Required artifact:** no application source is committed in this repository
> yet. The container image is the outstanding deliverable before the ECS service
> can pass health checks; until then the ALB returns `503` (no healthy targets).

### 13. Cognito User Pool, Client & Domain (`module.cognito` — Phase 4)

| Attribute | Value |
|---|---|
| User pool | `mcf-srid-prod`, email alias + auto-verified email |
| Sign-up | `allow_admin_create_user_only = true` (no self sign-up) |
| Password policy | min 12 chars, upper/lower/number/symbol required |
| MFA | `OPTIONAL` (TOTP software token) |
| Recovery | verified email |
| Domain | hosted UI prefix = `cognito_domain_prefix` or the name prefix (`mcf-srid-prod`) |
| App client | `mcf-srid-prod-client`, `generate_secret = true`, OAuth `code` flow, scopes `openid email profile`, `COGNITO` IdP |
| ALB auth rule | `authenticate-cognito` listener rule at priority 10 — **`count`-gated** on `enable_cognito_alb_auth && alb_https_enabled` |

> **Production caveat (auth deferred):** the user pool, domain, and client are
> always created, but ALB Cognito authentication **requires an HTTPS listener**.
> The rule stays OFF under the HTTP:80 demo. Populate `cognito_callback_urls` with
> the ALB HTTPS URL and set both `alb_https_enabled` and `enable_cognito_alb_auth`
> to `true` after Path A is in place.

### 14. SES + EventBridge + Breach-Notifier Lambda (`module.notifications` — Phase 5)

| Attribute | Value |
|---|---|
| Notifier Lambda | `mcf-srid-prod-breach-notifier`, `python3.12`, 256 MB, 60s; in private-app subnets + app SG |
| Package | self-contained `data.archive_file` from `modules/notifications/src/handler.py` (no external artifact) |
| SES | configuration set `mcf-srid-prod-notifications` + `aws_ses_email_identity` for sender + every recipient |
| Schedule | EventBridge rule `mcf-srid-prod-breach-notify`, default `cron(30 8,20 * * ? *)` (after AM/PM shifts) |
| IAM | inline `ses:SendEmail`/`SendRawEmail` + secret read + `kms:Decrypt` on the shared lambda-exec role |
| Behaviour | queries `srid.v_flagged_records` and emails a breach digest |

> **Gated OFF (`enable_notifications = false`).** Every active resource is
> `count`/`for_each`-gated so a default apply is clean. SES needs **verified**
> sender/recipient identities (in the sandbox, recipients too) — real artifacts
> that cannot be created purely in Terraform. The handler is a documented **stub**
> (psycopg2 wiring is illustrated but commented) — harden before enabling.

### 15. Observability — SNS, Dashboard & Alarms (`module.observability` — Phase 6)

| Attribute | Value |
|---|---|
| SNS topic | `mcf-srid-prod-alarms` (+ optional email subscription when `alarm_email` set) |
| Dashboard | `mcf-srid-prod` — 4 widgets: ALB requests/5XX, ALB p95 latency, ECS CPU/memory, RDS CPU/connections/free-storage |
| Alarms (8) | `alb-5xx-high`, `alb-latency-high` (p95 > 2s), `alb-unhealthy-hosts`, `ecs-cpu-high` (>80%), `ecs-memory-high` (>80%), `rds-cpu-high` (>80%), `rds-free-storage-low` (<2 GiB), `rds-connections-high` |

> The SNS topic is intentionally left SSE-off: a CMK-encrypted topic would need
> the key policy to grant `cloudwatch.amazonaws.com`
> `kms:GenerateDataKey`/`Decrypt`, which the Phase 0 CMK does not yet include.

### 16. AD Connector (`module.observability` — gated)

| Attribute | Value |
|---|---|
| Resource | `aws_directory_service_directory`, `type = ADConnector`, `size = Small` |
| Directory | `ad_directory_name` (default `corp.mcf.local`) |
| Connect settings | `customer_dns_ips` = `ad_dns_ips` (default `10.247.0.10/11`), bind creds read from `ad/bind-account` secret, ENIs in `ad_subnet_ids` (defaults to private-app subnets) |

> **Gated OFF (`enable_ad_connector = false`).** Needs Site-to-Site VPN
> connectivity to the on-prem DCs at `10.247.x.x` **and** a populated
> `ad/bind-account` secret. Building the VPN is out of scope; this is the
> "written deploy-ready but not applied" piece.

---

## Directory Structure

```
Server Room Inspection Dashboard/
├── README.md                         # This file — whole architecture (Phases 0–6)
├── PHASE1_RDS_SCOPE.md               # Phase 1 RDS design / approval artifact
├── PHASE1_PLAN_PREVIEW.txt           # Saved read-only `terraform plan` for Phase 1
├── PHASE3_DASHBOARD_DESIGN.md        # Approved dashboard + compute design
├── .gitignore                        # Excludes state, .terraform/, secrets
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
    ├── main.tf                       # Root wiring: networking, kms, security, iam,
    │                                 #   secrets, database, migration, glue, compute,
    │                                 #   cognito, notifications, observability
    ├── variables.tf                  # Root input variables (all phases)
    ├── outputs.tf                    # Root outputs (all phases)
    ├── provider.tf                   # AWS provider + default_tags
    ├── versions.tf                   # Terraform >= 1.5; aws ~> 5.0, archive ~> 2.4
    ├── backend.tf                    # S3 remote state + S3-native lockfile
    ├── terraform.tfvars              # Non-secret config
    ├── terraform.tfvars.example      # Template
    ├── .terraform.lock.hcl           # Provider dependency lock
    ├── bootstrap/                    # Creates the state bucket (local state)
    │   ├── main.tf · outputs.tf · variables.tf · terraform.tfvars(.example)
    └── modules/
        ├── networking/               # VPC, subnets, IGW, single NAT, routes   [P0]
        ├── security/                 # 3 reference-wired SGs (+ gated HTTP:80)  [P0]
        ├── kms/                      # CMK + alias (+ CloudWatch Logs grant)    [P0]
        ├── iam/                      # ECS ×2 + Lambda role stubs               [P0]
        ├── secrets/                  # 3 secret placeholders (db populated)     [P0/1]
        ├── database/                 # RDS PostgreSQL 16.14                     [P1]
        ├── migration/                # In-VPC migration Lambda (+ dist/*.zip)   [P2]
        ├── glue/                     # Glue backfill (bucket/job/connection)    [P2]
        ├── compute/                  # ECR + ECS Fargate + ALB + logs + IAM     [P3]
        ├── cognito/                  # User pool + domain + client + auth rule  [P4]
        ├── notifications/            # SES + EventBridge + notifier Lambda      [P5]
        └── observability/            # SNS + dashboard + 8 alarms + AD Connector[P6]
```

> No `app/` folder is committed yet — the dashboard container image is the
> outstanding required artifact (see Component Details §12). Each `modules/<name>/`
> folder contains `main.tf`, `outputs.tf`, and `variables.tf`.

---

## Prerequisites

| Tool | Minimum Version | Install |
|---|---|---|
| Terraform | 1.10 (S3-native locking; `versions.tf` pins `>= 1.5`) | https://developer.hashicorp.com/terraform/install |
| AWS CLI | 2.x | https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html |
| Docker | 24.x (to build/push the dashboard image) | https://docs.docker.com/get-docker/ |
| AWS credentials | — | `aws configure` (or SSO) for account `022499047467` |

**Account-level requirements:**

- Access to AWS account `022499047467`, region `ap-southeast-1`.
- IAM permissions for VPC/EC2, KMS, IAM, Secrets Manager, RDS, ECS, ECR, ELBv2,
  CloudWatch, SNS, Lambda, Glue, S3, Cognito, and (if enabled) SES + Directory
  Service.
- The state bucket `mcf-srid-tfstate-022499047467-apse1` must exist **before**
  the root `terraform init` — created by the `bootstrap/` config.
- **Required-but-not-in-repo:** the dashboard container image; and, for HTTPS, an
  ACM certificate + a domain. For Phase 5, verified SES identities. For the AD
  Connector, a Site-to-Site VPN + populated `ad/bind-account` secret.

---

## Quick Start

```bash
# 1. Enter the terraform directory
cd "Server Room Inspection Dashboard/terraform"

# 2. (First time only) create the remote-state bucket
cd bootstrap && terraform init && terraform apply && cd ..

# 3. Initialise the root against the S3 backend (S3-native lockfile locking)
terraform init

# 4. Review and apply the whole stack (Phases 0–6, gated modules stay OFF)
terraform plan
terraform apply

# 5. Build and push the dashboard image so the ECS service can go healthy
aws ecr get-login-password --region ap-southeast-1 \
  | docker login --username AWS --password-stdin \
    022499047467.dkr.ecr.ap-southeast-1.amazonaws.com
docker build -t mcf-srid-prod-dashboard:latest .
docker tag  mcf-srid-prod-dashboard:latest \
  "$(terraform output -raw ecr_repository_url):latest"
docker push "$(terraform output -raw ecr_repository_url):latest"
aws ecs update-service --cluster "$(terraform output -raw ecs_cluster_name)" \
  --service "$(terraform output -raw ecs_service_name)" --force-new-deployment \
  --region ap-southeast-1

# 6. Grab the URL and hit it
terraform output dashboard_url        # http://<alb_dns_name>/overview
```

Allow **~10–15 minutes** for the RDS instance to reach `available`, then
**~2–3 minutes** after the image is pushed for the Fargate task to start and pass
health checks. Until a healthy image is in ECR the ALB returns `503`.

> Applying with all defaults creates Phases 0–4 and 6; **notifications** and the
> **AD Connector** stay off. To run the schema migration and synthetic backfill,
> invoke the `mcf-srid-prod-migration` Lambda, then start the
> `mcf-srid-prod-backfill` Glue job.

---

## Input Variables

Declared in `terraform/variables.tf`. Gating flags are called out.

| Variable | Type | Default | Description |
|---|---|---|---|
| `region` | `string` | `"ap-southeast-1"` | AWS region |
| `project` | `string` | `"mcf-srid"` | Name-prefix root |
| `environment` | `string` | `"prod"` | Environment |
| `cost_center` | `string` | `"MCF-IT-Ops"` | Chargeback tag |
| `availability_zones` | `list(string)` | `["ap-southeast-1a","ap-southeast-1b"]` | AZs to span |
| `vpc_cidr` | `string` | `"10.20.0.0/16"` | VPC CIDR |
| `public_subnet_cidrs` | `list(string)` | `["10.20.0.0/24","10.20.1.0/24"]` | Public tier CIDRs |
| `app_subnet_cidrs` | `list(string)` | `["10.20.10.0/24","10.20.11.0/24"]` | Private-app CIDRs |
| `data_subnet_cidrs` | `list(string)` | `["10.20.20.0/24","10.20.21.0/24"]` | Private-data CIDRs |
| `single_nat_gateway` | `bool` | `true` | One shared NAT vs one per AZ |
| `app_port` | `number` | `8080` | App/Fargate/container port |
| `db_port` | `number` | `5432` | Data-tier SG port |
| `kms_alias` | `string` | `"alias/mcf-srid"` | CMK alias |
| `db_engine_version` | `string` | `"16.14"` | PostgreSQL version |
| `db_instance_class` | `string` | `"db.t4g.micro"` | RDS instance class |
| `db_name` | `string` | `"inspections"` | Application database name |
| `container_cpu` | `number` | `256` | Fargate CPU units (0.25 vCPU) |
| `container_memory` | `number` | `512` | Fargate memory MiB (0.5 GB) |
| `desired_count` | `number` | `1` | Running dashboard tasks |
| `log_retention_days` | `number` | `30` | Dashboard log retention |
| `image_tag` | `string` | `"latest"` | Image tag the task def references |
| `alb_listener_port` | `number` | `80` | ALB listener port (80 demo / 443 HTTPS) |
| `enable_http_ingress` | `bool` | `true` | **Gate** — add the ALB SG HTTP ingress rule |
| `office_cidr` | `string` | `"0.0.0.0/0"` | CIDR allowed over HTTP — **narrow for prod** |
| `cognito_domain_prefix` | `string` | `""` | Hosted-UI domain prefix (empty = name prefix) |
| `cognito_callback_urls` | `list(string)` | `[]` | OIDC callback URLs (ALB HTTPS URL) |
| `alb_https_enabled` | `bool` | `false` | **Gate** — ALB has an HTTPS listener |
| `enable_cognito_alb_auth` | `bool` | `false` | **Gate** — create the ALB authenticate-cognito rule |
| `enable_notifications` | `bool` | `false` | **Gate** — SES/EventBridge/notifier stack |
| `ses_sender_email` | `string` | `""` | Verified SES sender |
| `ses_recipient_emails` | `list(string)` | `[]` | Breach-digest recipients |
| `notification_schedule` | `string` | `"cron(30 8,20 * * ? *)"` | EventBridge schedule |
| `alarm_email` | `string` | `""` | Email subscribed to the alarms SNS topic |
| `enable_ad_connector` | `bool` | `false` | **Gate** — create the AD Connector |
| `ad_directory_name` | `string` | `"corp.mcf.local"` | On-prem AD domain |
| `ad_dns_ips` | `list(string)` | `["10.247.0.10","10.247.0.11"]` | On-prem AD DNS servers |
| `ad_subnet_ids` | `list(string)` | `[]` | AD Connector ENI subnets (empty = private-app) |

**Validation:** each of `public_subnet_cidrs`, `app_subnet_cidrs`, and
`data_subnet_cidrs` must contain **exactly one CIDR per `availability_zone`** —
Terraform fails `plan` before any AWS call if a tier's count differs from the AZ
count. The Cognito ALB rule and the AD Connector are additionally guarded by
their `enable_*` / `alb_https_enabled` flags at `count`.

---

## Outputs

Declared in `terraform/outputs.tf`.

| Output | Description |
|---|---|
| `vpc_id`, `vpc_cidr`, `igw_id`, `nat_gateway_ids` | Core network IDs |
| `public_subnet_ids`, `app_subnet_ids`, `data_subnet_ids` | Subnet IDs per tier |
| `public_route_table_id`, `private_route_table_id` | Route table IDs |
| `alb_sg_id`, `app_sg_id`, `data_sg_id` | Security group IDs |
| `kms_key_id`, `kms_key_arn`, `kms_alias_name` | CMK identifiers |
| `ecs_task_execution_role_arn`, `ecs_task_role_arn`, `lambda_execution_role_arn` | IAM role ARNs |
| `db_secret_arn`, `smtp_secret_arn`, `ad_bind_secret_arn` | Secret ARNs |
| `name_prefix`, `region` | Convenience |
| `db_instance_id`, `db_endpoint`, `db_port`, `db_name` | RDS connection details |
| `db_parameter_group`, `db_subnet_group`, `app_username` | RDS metadata + `srid_app` |
| `migration_lambda_name` | Migration/verification Lambda |
| `backfill_bucket`, `glue_backfill_job`, `glue_connection_name`, `glue_role_arn` | Glue backfill |
| `dashboard_url`, `alb_dns_name`, `ecr_repository_url` | Dashboard access + image target |
| `ecs_cluster_name`, `ecs_service_name` | ECS identifiers |
| `cognito_user_pool_id`, `cognito_hosted_ui_url` | Cognito |
| `sns_alarms_topic_arn`, `cloudwatch_dashboard_name` | Observability |

```bash
terraform output dashboard_url            # single value
terraform output -raw ecr_repository_url  # unquoted (for scripts)
terraform output -json                    # everything as JSON
```

---

## Scaling Behaviour

SRID has **no Auto Scaling Group** — it is an ECS Fargate service pinned to
`desired_count = 1`. "Scaling" here means where you would attach elasticity and
the resilience levers already in place.

```
ECS Fargate desired-count (today: fixed at 1)

 tasks
   3 ┤                         ┌────────────  (target-tracking scale-out
   2 ┤             ┌───────────┘               on ECS CPUUtilization > 60%,
   1 ┤─────────────┘                           if an aws_appautoscaling
   0 ┼───────────────────────────────────────  target/policy is added)
     └── low traffic ──► sustained load ──► burst
        desired_count var  │  ALB spreads targets across 1a + 1b
```

**Where elasticity attaches:**

- **Fargate task scaling.** Add an `aws_appautoscaling_target` +
  `aws_appautoscaling_policy` (target-tracking on ECS `CPUUtilization` or ALB
  `RequestCountPerTarget`) to scale `desired_count`. The service already
  `ignore_changes = [desired_count]`, so autoscaling won't fight Terraform. The
  ALB target group is `target_type = ip`, so new tasks register automatically.
- **Multi-AZ spread.** The service network config already lists both private-app
  subnets; raising `desired_count` places tasks across `1a` and `1b`.
- **Database growth.** RDS gp3 autoscales `20 → 50` GiB; `multi_az = true` adds a
  synchronous standby with no rebuild; `db.t4g.small` is the next size up if
  Performance Insights shows memory pressure on the 1 GiB micro.
- **Egress resilience.** `single_nat_gateway = false` provisions per-AZ NAT so an
  AZ impairment doesn't cut egress for the surviving AZ — the single most
  impactful pre-prod change.
- **CIDR headroom.** Six `/24`s from a `/16` leave ample room to add tiers (cache,
  bastion) without renumbering.

> The `rds-free-storage-low` (<2 GiB) and `ecs-cpu/memory-high` (>80%) alarms are
> the signals that should trigger a size-up or an autoscaling policy.

---

## Tagging Strategy

Tags come from the provider `default_tags` block plus a per-resource `Name` (and
`Tier` where relevant).

| Tag Key | Value |
|---|---|
| `Name` | Unique per resource (e.g. `mcf-srid-prod-data-sg`) |
| `Project` | `mcf-srid` |
| `Environment` | `prod` |
| `Application` | `ServerRoomInspectionDashboard` |
| `Owner` | `MCF-Facilities` |
| `CostCenter` | `MCF-IT-Ops` |
| `ManagedBy` | `Terraform` |
| `Tier` | `public` / `private-app` / `private-data` (subnet, SG, DB resources) |

> **Chargeback:** `CostCenter = MCF-IT-Ops` propagates to every taggable resource
> via `default_tags`, so Cost Explorer attributes the whole stack to MCF IT Ops.
> A few resources set on snapshots via `copy_tags_to_snapshot = true` (RDS) carry
> these tags onto their snapshots too.

---

## Security Considerations

| Topic | Current posture | Recommended hardening |
|---|---|---|
| Transit encryption (ALB) | **Plain HTTP:80** for the demo | Path A: `alb_listener_port = 443` + ACM cert + `alb_https_enabled = true` |
| Application auth | **Unauthenticated** dashboard (Phase 3) | Narrow `office_cidr` now; enable Cognito ALB auth (Phase 4) once HTTPS is live |
| ALB ingress scope | `office_cidr` defaults to `0.0.0.0/0` | Restrict to the MCF office egress CIDR — mandatory while unauthenticated |
| Data tier isolation | RDS private, no public IP; data SG ingress `5432` from app/Glue SG only; egress VPC-CIDR only | No change — isolation is by design |
| RDS transit | `rds.force_ssl = 1` (TLS forced for every client) | Keep; pin client `sslmode=require` |
| Least privilege (DB) | `srid_app` login; app session is `SELECT`-only | Keep app read-only; the grant includes DML for a future write phase |
| Encryption at rest | CMK `alias/mcf-srid` on RDS/PI, ECR, CloudWatch Logs, Secrets, Glue bucket; rotation on | Add `cloudwatch.amazonaws.com` grant to the CMK to also encrypt the SNS topic |
| Secrets | 3 Secrets Manager containers, CMK-encrypted; passwords generated in-module | Never commit secret material to tfvars; keep state in encrypted S3 |
| IAM | Role stubs + resource-scoped inline policies; no wildcard-admin, no access keys | Keep scoping per phase; review on each new module |
| NAT resilience | Single shared NAT — `1a` impairment kills egress for both AZs | `single_nat_gateway = false` for per-AZ NAT before production |
| Remote state | S3 backend, `encrypt = true`, S3-native lockfile | Restrict bucket IAM; passwords live in state |
| AD / VPN | AD Connector gated OFF; no on-prem VPN | Build Site-to-Site VPN + populate `ad/bind-account` before enabling |
| Deletion safety | RDS `deletion_protection` default `false`, `skip_final_snapshot = true` | Set `deletion_protection = true` + a final snapshot for production |

---

## Cost Estimate

Approximate `ap-southeast-1` on-demand pricing, 730 hrs/month. Reflects the
**default deploy** (Phases 0–4 + 6; notifications and AD Connector OFF).

| Resource | Quantity | Monthly (USD) |
|---|---|---|
| NAT Gateway (hourly) | 1 | ~$32.85 |
| Elastic IP (attached) | 1 | $0.00 |
| KMS CMK | 1 | ~$1.00 |
| Secrets Manager | 3 secrets | ~$1.20 |
| S3 remote state + Glue backfill bucket | negligible | ~$0.10 |
| VPC / subnets / IGW / routes / SGs / IAM | — | $0.00 |
| **Phase 0 subtotal** | | **~$36** |
| RDS `db.t4g.micro` (Single-AZ) | 730 hrs | ~$18.25 |
| RDS gp3 storage | 20 GiB | ~$2.76 |
| RDS logs / PI | low volume / free tier | ~$0.30 |
| **Phase 1 subtotal** | | **~$21** |
| Fargate vCPU + memory | 0.25 vCPU / 0.5 GB × 730 h | ~$11.25 |
| ALB (hourly) | 730 hrs | ~$18.40 |
| ALB LCU | ~1 LCU (low, internal) | ~$1.00 |
| ECR storage | ~0.5 GB image | ~$0.05 |
| CloudWatch Logs (dashboard) | low ingest + 30-day | ~$1.00 |
| NAT data processing | image + secret pulls | ~$0.50 |
| **Phase 3 subtotal** | | **~$32** |
| CloudWatch dashboard + 8 alarms + SNS | 1 + 8 | ~$3.80 |
| **Phase 6 subtotal (default-on)** | | **~$4** |
| **Project running total (active demo path)** | | **≈ $92 / month** |

> The Phase 0/1/3 core is ~$88/mo; Phase 6 observability adds ~$4. **Gated
> phases cost nothing until enabled:** Phase 5 notifications (SES + a tiny Lambda,
> effectively cents when on) and the **AD Connector Small** (~$0.05/hr ≈ **$36/mo**
> only when `enable_ad_connector = true`). ARM64/Graviton Fargate would trim
> compute by ~$2/mo. The NAT Gateway is the single largest fixed cost. Model
> variants with the [AWS Pricing Calculator](https://calculator.aws/).

---

## Destroying the Stack

```bash
cd "Server Room Inspection Dashboard/terraform"

# Pre-step 1 — if RDS deletion protection was enabled, disable it first:
aws rds modify-db-instance --db-instance-identifier mcf-srid-prod-pg \
  --no-deletion-protection --apply-immediately --region ap-southeast-1

# Pre-step 2 — empty the ECR repo (Terraform won't delete a repo with images):
aws ecr batch-delete-image --repository-name mcf-srid-prod-dashboard \
  --image-ids "$(aws ecr list-images --repository-name mcf-srid-prod-dashboard \
    --region ap-southeast-1 --query 'imageIds' --output json)" \
  --region ap-southeast-1 || true

# Tear down the whole stack
terraform destroy
```

**Manual pre-steps / caveats:**

- **In-VPC Lambda / Glue Hyperplane ENIs** (migration Lambda, notifier Lambda,
  Glue connection) hold subnet ENIs that AWS releases lazily — subnet/VPC
  deletion can wait **~10–40 minutes**. A `destroy` may need a re-run if it times
  out on the VPC.
- **KMS CMK** enters a **30-day pending-deletion window** (`deletion_window_in_days`);
  it is not billed during the window but the alias is freed on schedule, not
  immediately.
- **RDS final snapshot:** the module currently sets `skip_final_snapshot = true`,
  so no snapshot is retained by default. If you switch it on for production, the
  snapshot is **not** Terraform-managed and survives — delete it manually.
- **Cognito hosted-UI domain** and the **Glue backfill S3 bucket** (`force_destroy
  = true`, so it empties on destroy) are removed by Terraform.
- **Gated resources are not created by default**, so nothing to clean up for
  notifications or the AD Connector unless you enabled them (an enabled AD
  Connector must reach on-prem DNS to delete cleanly).
- **Not managed by this root config (survives `terraform destroy`):** the
  remote-state bucket `mcf-srid-tfstate-022499047467-apse1` (owned by
  `bootstrap/` — `cd bootstrap && terraform destroy`) and the legacy
  `mcf-srid-tfstate-lock` DynamoDB table (unused; delete manually).

---

## Frequently Asked Questions

**Q: I applied the stack and the ALB returns `503 Service Temporarily Unavailable`
(or `502`). What's wrong?**

A: The ECS service has **no healthy target** because the dashboard container image
hasn't been pushed to ECR yet. `module.compute` creates an empty repo; the task
definition references `…/mcf-srid-prod-dashboard:latest`. Until you build and
push the Flask image (Quick Start step 5) the task can't start, so the target
group is empty and the ALB has nothing to forward to — hence `503`. A transient
`502` can also appear in the seconds between the task starting and passing its
first `/healthz` check.

**Q: Why is the dashboard served over plain HTTP instead of HTTPS?**

A: It's a throwaway demo posture. HTTPS (Path A) needs an **ACM certificate**,
which needs a **domain the Boss controls** for validation. Rather than block the
demo on a domain, the ALB serves HTTP:80 on its `*.elb.amazonaws.com` name — which
also required a gated `tcp/80` ingress rule on the ALB SG (`enable_http_ingress`,
narrowed by `office_cidr`). Treat it as throwaway and retire it once a domain
exists.

**Q: How do I add HTTPS and Cognito authentication?**

A: (1) Request/import an ACM cert in `ap-southeast-1` for your domain; (2) set
`alb_listener_port = 443` and add the `certificate_arn` to the listener; (3) set
`alb_https_enabled = true`; (4) populate `cognito_callback_urls` with the ALB
HTTPS URL and set `enable_cognito_alb_auth = true`. The Cognito user pool, domain,
and client already exist — only the `authenticate-cognito` **listener rule** is
gated, because ALB Cognito auth **requires an HTTPS listener**. Point DNS (Route
53 alias or a CNAME) at the ALB.

**Q: Why is the database single-AZ, and is that safe?**

A: `multi_az = false` is an approved right-sizing choice for a small (2 server
room) internal tool — it halves RDS cost. The trade-off is downtime during an AZ
outage or instance failure until AWS recovers or a restore completes; there is no
synchronous standby. Backups are 7-day with PITR. Flipping to Multi-AZ later is a
one-line, non-destructive `multi_az = true` change.

**Q: Why only one NAT Gateway across two AZs?**

A: Cost — one shared NAT is ~$33/mo versus ~$66 for one per AZ. The trade-off is
that an `1a` impairment removes outbound Internet for private resources in **both**
AZs (image/secret pulls, SES). For a small internal tool this is acceptable; set
`single_nat_gateway = false` before any production cutover needing AZ-independent
egress.

**Q: How do I turn on breach notifications and the AD Connector?**

A: **Notifications (Phase 5):** verify the sender and (in the SES sandbox) every
recipient identity, then set `enable_notifications = true`, `ses_sender_email`,
and `ses_recipient_emails`. The whole module is `count`/`for_each`-gated, so it
creates nothing until enabled; the handler is a documented stub — wire psycopg2
and harden the email body first. **AD Connector (Phase 6):** stand up a
Site-to-Site VPN to the on-prem DCs at `10.247.x.x`, populate the
`ad/bind-account` secret with `{username,password}`, then set
`enable_ad_connector = true`. Both are deploy-ready but OFF because they depend on
real external artifacts Terraform cannot create.

**Q: Where is Terraform remote state, and why S3-native locking instead of
DynamoDB?**

A: State lives in the S3 bucket `mcf-srid-tfstate-022499047467-apse1` under key
`server-room-inspection-dashboard/phase0/terraform.tfstate`, `encrypt = true`.
Locking uses **S3-native conditional writes** (`use_lockfile = true`, GA since
Terraform 1.10) — no DynamoDB lock table required. The legacy
`mcf-srid-tfstate-lock` table is retained but unused and safe to delete. Because
generated DB passwords flow through state, keep the bucket IAM-restricted and
encrypted.

**Q: The migration Lambda and Glue job are created but the schema/data isn't
there — why?**

A: Provisioning the migration Lambda and Glue job does not **run** them. After
`apply`, invoke `mcf-srid-prod-migration` (applies the 5 DDL files and creates
`srid_app`), then start the `mcf-srid-prod-backfill` Glue job (loads the 2,924-row
synthetic CSV into `srid.inspection_log`). Only then do the dashboard views return
data.
```
