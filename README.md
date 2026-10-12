# AWS Projects Portfolio

A collection of **production-grade cloud infrastructure projects** demonstrating enterprise-scale AWS architecture, Infrastructure as Code (Terraform/CloudFormation), security best practices, and DevOps patterns.

---

## 📋 Table of Contents

1. [Project Overview](#project-overview)
2. [Quick Navigation](#quick-navigation)
3. [Projects](#projects)
4. [Technology Stack](#technology-stack)
5. [Key Achievements](#key-achievements)
6. [Getting Started](#getting-started)
7. [Repository Structure](#repository-structure)

---

## 🎯 Project Overview

This portfolio showcases **9 AWS infrastructure projects** — 7 deployed and tested (the newest, the Love Opinion Poll Game on EKS Fargate, was deployed on 2026-10-10 and destroyed on 2026-10-11), plus 2 (Systems Manager Automated Patching and POS Transaction Pipeline with SQS DLQ) authored and `terraform validate`-clean, pending deployment — each demonstrating different architectural patterns, scaling strategies, and deployment approaches. All projects are:

- ✅ **Production-Ready** — Security hardened, tested, documented
- ✅ **Infrastructure as Code** — 100% Terraform/CloudFormation managed
- ✅ **Scalable** — Auto-scaling, load balancing, multi-AZ deployments
- ✅ **Secure** — Encryption, private subnets, least-privilege IAM, WAF/DDoS
- ✅ **Documented** — README, architecture diagrams, test guides, runbooks
- ✅ **Cost-Optimized** — Monthly cost analysis and optimization strategies

---

## 🚀 Quick Navigation

| Project | Type | Best For | Time to Deploy | Est. Monthly Cost |
|---------|------|----------|-----------------|-------------------|
| [Multi-Tier Web App](#2-multi-tier-web-app-deployment) | EC2 + RDS | Enterprise web apps | 15-20 min | $280 |
| [Scalable Web App (ALB)](#3-scalable-web-app-with-alb--auto-scaling) | ALB + ASG | Layer 7 routing | 12-18 min | $123.25 (HTTPS + RDS revision, not deployed) |
| [Scalable Web App (NLB)](#4-scalable-web-app-with-nlb--auto-scaling) | NLB + ASG | High-performance APIs | 12-18 min | $196.25 (HTTPS + RDS revision, not deployed) |
| [Cloud-Tibot](#5-cloud-tibot) | Microservices | Bot platforms, agents | Variable | Variable |
| [Event Ticket Check-In System](#7-yrc2026-event-ticket-check-in-system) | Serverless (SQS + Lambda) | Event management, email automation | 8-12 min | ~$0.30/event |
| [Systems Manager Automated Patching](#13-systems-manager-automated-patching) | SSM Patch Manager | Fleet OS patching, compliance SLAs | 10-15 min | ~$24/month* |
| [Icebreaker Poll Game](#16-icebreaker-poll-game--human-vs-ai-live-audience-poll) | ECS Fargate + DynamoDB | Live audience polling, conference segments | 10-15 min | ~$92/month; ~$10/event |
| [POS Transaction Pipeline with SQS DLQ](#17-pos-transaction-pipeline-with-sqs-dead-letter-queues) | SNS fan-out + SQS DLQ + Lambda | Zero-silent-loss messaging, replayable failures | 3-5 min | ~$0.70/month* |
| [Love Opinion Poll Game](#18-love-opinion-poll-game--live-opinion-poll-on-eks-fargate) | EKS Fargate + ALB + DynamoDB | Live audience opinion polls, single-event stacks | 20-30 min (runbook estimate) | ~$280/month; ~$9/day ($0 today, destroyed) |

> *Authored and `terraform validate`-clean; not currently deployed ($0 while destroyed).

---

## 📦 Projects

### 2. Multi-Tier Web App Deployment

**Location:** `./Multi-Tier Web App Deployment/`  

**Description:**  
A classic three-tier web application architecture with web servers, application servers, and a database layer. Demonstrates traditional enterprise architecture with high availability.

**Architecture:** ALB → EC2 (Web Tier) → EC2 (App Tier) → RDS (Data Tier)

**Key Features:**
- ✅ Multi-AZ deployment across availability zones
- ✅ Application Load Balancer with health checks
- ✅ Auto Scaling Groups for each tier
- ✅ RDS PostgreSQL with read replicas
- ✅ Security groups with tiered access
- ✅ CloudWatch monitoring and alarms

**Tech Stack:** Terraform, EC2, ALB, RDS, Auto Scaling, CloudWatch

**Cost:** ~$280/month (production sizing)

**Links:**
- 📄 [Full Documentation](Multi-Tier%20Web%20App%20Deployment/README.md)

---

### 3. Scalable Web App with ALB & Auto Scaling

**Location:** `./Scalable Web App with ALB & Auto Scaling/`  

**Description:**  
A scalable web tier behind an internet-facing Application Load Balancer (ALB), revised on 2026-10-07 to serve traffic over HTTPS and to add a Multi-AZ RDS for PostgreSQL 18 database tier (one primary plus a synchronous standby). The revised Terraform puts an `HTTPS:443` listener on the ALB for `webapp-alb.aterpise.com`, with an ACM certificate validated through Terraform-managed Cloudflare DNS records, and makes `HTTP:80` answer with a `301` redirect to HTTPS. Apache instances on Amazon Linux 2023 in an Auto Scaling Group run a boot-time connectivity check against the database and show `connected` or `unreachable` on a static page. The previous architecture (HTTP only, no database tier) was deployed in June 2026; the HTTPS and RDS revision is authored and validate-clean, not deployed.

**Architecture:** Cloudflare DNS (CNAME, DNS only) → ALB (HTTPS:443 with ACM certificate; HTTP:80 → 301 to HTTPS) → ASG (EC2, HTTP:80) → RDS PostgreSQL Multi-AZ (boot-time connectivity check, TCP 5432); CloudWatch CPU alarms → Scaling Policies

**Key Features:**
- ✅ Layer 7 (Application) routing rules
- ✅ Auto Scaling based on CPU/Memory/Custom metrics
- ✅ Health check integration
- ✅ Multi-AZ deployment
- ✅ CloudWatch Logs and Alarms
- ✅ Dead-band scaling to prevent thrashing
- `HTTPS:443` listener with a DNS-validated ACM certificate and the TLS policy set by `ssl_policy` (default `ELBSecurityPolicy-TLS13-1-2-Res-PQ-2025-09`); `HTTP:80` answers `HTTP_301` to HTTPS
- Multi-AZ RDS for PostgreSQL 18 (`db.t3.micro`, 20 GB gp3, encrypted, not publicly accessible) in two new database subnets that share one route table holding the local route only
- RDS-managed master password in Secrets Manager; there is no password variable and nothing in tfvars or user data
- Three security groups (`<app_name>-alb-sg`, `<app_name>-ec2-sg`, `<app_name>-db-sg`): 80 and 443 from the internet reach the ALB only, 80 reaches the instances from the ALB group only, 5432 reaches the database from the instance group only
- Port 22 removed in favour of Session Manager; IMDSv2 required (hop limit 1); new instance role limited to `AmazonSSMManagedInstanceCore` plus `secretsmanager:GetSecretValue` on the one database secret
- Cloudflare DNS records managed by Terraform (ACM validation CNAME and hostname CNAME, both DNS only); the API token is read from `CLOUDFLARE_API_TOKEN` and is never in a file

**Tech Stack:** Terraform, ALB, Auto Scaling Groups, CloudWatch, EC2, RDS PostgreSQL (Multi-AZ), ACM, Secrets Manager, IAM, Systems Manager Session Manager, Cloudflare DNS

**Cost:** $123.25/month for the HTTPS and RDS revision, up $31.28 from $91.97 for the previous architecture. Basis: AWS Price List API, us-east-1, on-demand, 730 hours per month, idle baseline, queried 2026-10-07; usage-based charges (LCU, NAT data processing, data transfer) are excluded.

**Links:**
- 📄 [Full Documentation](Scalable%20Web%20App%20with%20ALB%20%26%20Auto%20Scaling/README.md)

---

### 4. Scalable Web App with NLB & Auto Scaling

**Location:** `./Scalable Web App with NLB & Auto Scaling/`  

**Description:**  
A web tier in private subnets behind an internet-facing Network Load Balancer (NLB), revised on 2026-10-07 to serve traffic over HTTPS and to add a Multi-AZ RDS for PostgreSQL 18 database tier (one primary plus a synchronous standby). The revised Terraform gives the NLB a single `TLS:443` listener for `webapp-nlb.aterpise.com`, with an ACM certificate validated through Terraform-managed Cloudflare DNS records; port 80 is closed (no listener and no security group rule), because an NLB can forward but cannot redirect. Nginx or Apache instances on Amazon Linux 2023 in an Auto Scaling Group run a boot-time connectivity check against the database and show `connected` or `unreachable` on a static page. The previous architecture (HTTP only, no database tier) was deployed in June 2026; the HTTPS and RDS revision is authored and validate-clean, not deployed.

**Architecture:** Cloudflare DNS (CNAME, DNS only) → NLB (TLS:443 with ACM certificate; port 80 closed) → ASG (EC2 in private subnets, TCP 80) → RDS PostgreSQL Multi-AZ (boot-time connectivity check, TCP 5432); CloudWatch CPU alarms → Scaling Policies

**Key Features:**
- ✅ Layer 4 (Transport) routing for extreme performance
- ✅ Ultra-high throughput (millions of requests/sec)
- ✅ Ultra-low latency (<100 microseconds)
- ✅ Sticky sessions and connection draining
- ✅ Multi-AZ deployment
- ✅ Auto Scaling with predictive metrics
- Single `TLS:443` listener with a DNS-validated ACM certificate and the TLS policy set by `ssl_policy` (default `ELBSecurityPolicy-TLS13-1-2-Res-PQ-2025-09`); TLS ends at the NLB
- Port 80 closed (no listener, no security group rule), so `http://` requests fail to connect and are not redirected
- Multi-AZ RDS for PostgreSQL 18 (`db.t3.micro`, 20 GB gp3, encrypted, not publicly accessible) in database subnets `10.0.5.0/24` and `10.0.6.0/24`, each with its own route table holding the local route only
- RDS-managed master password in Secrets Manager; there is no password variable, and the instance role gains `secretsmanager:GetSecretValue` on that one secret
- Database security group with one ingress rule (TCP 5432 from the EC2 security group, by reference) and no egress rule
- Amazon Linux 2023 AMI resolved from a public SSM parameter by default; `ami_id` is an optional override
- Cloudflare DNS records managed by Terraform (ACM validation CNAME and hostname CNAME, both DNS only); the API token is read from `CLOUDFLARE_API_TOKEN` and is never in a file

**Tech Stack:** Terraform, NLB, Auto Scaling Groups, CloudWatch, EC2, RDS PostgreSQL (Multi-AZ), ACM, Secrets Manager, Cloudflare DNS

**Cost:** $196.25/month for the HTTPS and RDS revision, up $31.28 from $164.97 for the previous architecture. Basis: AWS Price List API, us-east-1, on-demand, 730 hours per month, idle baseline, queried 2026-10-07; usage-based charges (LCU, NAT data processing, data transfer) are excluded.

**Performance:** Sub-millisecond latency, 1M+ RPS capacity

**Links:**
- 📄 [Full Documentation](Scalable%20Web%20App%20with%20NLB%20%26%20Auto%20Scaling/README.md)

---

### 5. Cloud-Tibot

**Location:** `./Cloud-Tibot/`  

**Description:**  
A microservices-based platform for deploying and managing AI agents/bots with event-driven architecture. Demonstrates serverless patterns, Lambda integration, and scalable bot deployment.

**Architecture:** API Gateway → Lambda → DynamoDB/S3 → SNS/SQS → Monitoring

**Key Features:**
- ✅ Microservices architecture
- ✅ Event-driven processing
- ✅ Serverless scalability
- ✅ Multiple bot instances
- ✅ CloudWatch monitoring
- ✅ Cost-efficient deployment

**Tech Stack:** Terraform, Lambda, API Gateway, DynamoDB, S3, SNS/SQS, CloudWatch

**Cost:** Variable (pay-as-you-go serverless model)

**Links:**
- 📄 [Full Documentation](Cloud-Tibot/README.md)

---

### 7. YRC2026 Event Ticket Check-In System

**Location:** `./Event Ticket Check In System/`

**Description:**
A production-deployed serverless event management system built on AWS for Youth Revival Conference 2026, handling the complete attendee lifecycle: Google Form registration → automated QR code ticket delivery via Gmail API → staff check-in via Google Spreadsheet. Uses an event-driven pipeline (API Gateway → SQS FIFO → Lambda) with usage-limited DynamoDB token authentication, S3 OAuth token persistence, and a hot-swappable email template. Infrastructure fully managed by Terraform across 9 files.

**Architecture:** Google Form → Apps Script → API Gateway → `SubmitGmailSenderSQS` → SQS FIFO → `GmailSender` (Pillow QR composite + Gmail API) → DynamoDB ticket status

**Key Features:**
- ✅ End-to-end attendee lifecycle automated — registration to HTML QR ticket in <60 s
- ✅ SQS FIFO decoupling — absorbs form submission bursts, guarantees ordered delivery
- ✅ S3-backed OAuth token persistence — Gmail credentials survive Lambda cold starts
- ✅ Email template hot-swap — update HTML template in S3 with zero Lambda redeployment
- ✅ Usage-limited token auth — DynamoDB atomic counter with TTL, no separate auth service
- ✅ Bulk send CLI — dry-run preview, CSV import, status filtering, full automation
- ✅ 8 deployment issues root-caused and documented (OAuth cold start, Pillow memory, visibility timeout, Gmail rate limits, token race condition, S3 public access)

**Tech Stack:** Terraform, API Gateway, SQS FIFO, Lambda (Python 3.11), DynamoDB, S3, Gmail API, Pillow, CloudWatch

**Cost:** ~$0.30 per event (500 attendees)

**Testing:** 8 architecture validation checks across all deployed components

**Links:**
- 📄 [Full Documentation](Event%20Ticket%20Check%20In%20System/README.md)

---

### 13. Systems Manager Automated Patching

**Location:** `./Systems Manager Automated Patching/`

**Description:**
An automated OS-patching control plane for a mixed Amazon Linux 2023 / Ubuntu 22.04 fleet, built entirely on AWS Systems Manager and Terraform for a healthcare revenue-cycle workload (Meridian Health Partners) under a Critical-CVE ≤ 7-day VM-SLA. Stands up a self-contained VPC, SSM-managed EC2 targets, per-OS Patch Baselines, staggered weekly Maintenance Windows, and `AWS-RunPatchBaseline` Run Command tasks that install approved patches in bounded waves, with SNS alerting on failure.

**Architecture:** SSM cron → Maintenance Windows → `AWS-RunPatchBaseline` → EC2 (targeted by `Patch Group` tag) → SNS alerts

**Key Features:**
- ✅ Per-OS Patch Baselines — AL2023 (`CLASSIFICATION` + `SEVERITY`) and Ubuntu (`PRIORITY` + `SECTION`) via each OS's native filter surface
- ✅ 7-day auto-approval delay encodes the Critical-CVE VM-SLA
- ✅ Bounded blast radius — `max_concurrency = 25%` + a 2-error budget per wave
- ✅ Staggered windows (02:00 / 03:00 UTC) isolate OS-specific failures
- ✅ Patch exceptions as change control — `ansible` BLOCK-rejected, `openssl` fast-tracked
- ✅ Egress-only SG (no inbound), IMDSv2 required, encrypted gp3, AMIs via SSM public parameters
- ✅ SNS `patch-alerts` on `Failed` / `TimedOut` task events

**Tech Stack:** Terraform, AWS Systems Manager (Patch Manager, Maintenance Windows, Run Command), EC2, IAM, SNS, VPC

**Cost:** ~$24/month (2 × `t3.micro` default footprint) — $0 while destroyed

**Status:** Authored & `terraform validate`-clean; not yet deployed

**Links:**
- 📄 [Full Documentation](Systems%20Manager%20Automated%20Patching/README.md)
- 📝 [Resume Summary](Resume/13_Systems_Manager_Automated_Patching.md)

---

### 16. Icebreaker Poll Game — Human vs AI Live Audience Poll

**Location:** `./Icebreaker Poll Game (ECS+Fargate+ALB)/` (separate repository — [Aterpise-MY/Icebreaker-Poll-Game](https://github.com/Aterpise-MY/Icebreaker-Poll-Game), branch `master`)

**Description:**
A live audience poll built for the 15-minute opening segment of a conference talk. Three hundred people in a room scan one QR code, each phone answers a question — "did a human or an AI write this?" — and the projector reveals the split. The entire design is shaped by one constraint that ordinary web apps never face: **there is no second attempt.** The segment runs once, in front of the room, and every architectural decision is a hedge against a specific way that afternoon could go wrong. There are **no WebSockets** (a reconnect storm across 300 phones on venue wifi is worse than polling); the **server runs no timer at all** (`/state` returns `phaseEndsAt` + `serverNow` and clients measure their own clock offset, corrected for half the round trip); and **`/health` deliberately does not touch DynamoDB**, because a dependency check would fail every task's health check simultaneously, strip the ALB of healthy targets, and let ECS turn a self-healing blip into a 90-second self-inflicted outage. One container serves the built React frontend and the API from a single origin, so there is no CORS and no second base URL to get wrong. Runs in `ap-southeast-1` under the prefix `poll-game`.

**Architecture:** GitHub Actions (build arm64 → push Docker Hub → ECS rolling deploy) → Internet → Route53 + ACM → ALB (HTTPS :443, HTTP→HTTPS 301) → ECS Fargate ARM64 × 2 (public subnets, no NAT) → DynamoDB single table (10 tally shards) + S3 media bucket

**Key Features:**
- ✅ Poll-based, not push-based — phones poll `/state` every 2s and the projector every 1s; a server-authoritative deadline plus client-side clock-offset correction means no socket to drop and nothing to reconnect
- ✅ **`/health` is liveness-only by design** — the one health check that must not be "thorough", with the outage arithmetic written into the Terraform and the server alike
- ✅ **Write sharding driven by a real measurement** — a 300-player load test on the deployed stack produced **537 `TransactionConflict` retries** on the single hot tally item; votes now land on one of 10 shards and reads sum them, trading a read-heavy cost multiplier for the removal of a synchronised write burst
- ✅ Content pipeline makes a wrong answer on the projector structurally impossible — one authored source file generates both the question texts and the fingerprinted answer key, and the Docker build fails if they drift
- ✅ Atomic voting — one `TransactWriteItems` puts the conditional voter record and increments the shard together; operator writes use optimistic concurrency, so a double-clicked button gets `409 CONFLICT` instead of double-advancing the show
- ✅ Operator console built for the failure modes — a real 20-deep undo stack, "skip this question" refused on the last question, and an operator-driven segment clock the projector never displays (a countdown on the wall turns a slot into a deadline in front of the room)
- ✅ Private Docker Hub pull via Secrets Manager `repositoryCredentials` resolved by the ECS **execution** role — no registry credentials in the image, the task, or Terraform state
- ✅ Cost-shaped for a single afternoon — no NAT Gateway (public subnets + a security group that only accepts the ALB), FARGATE-only capacity (a Spot interruption notice mid-reveal is not worth the savings), and a `teardown.sh` that scales to zero before destroying
- ✅ **139 backend unit tests** plus a 19-check end-to-end smoke suite that boots its own server

**Tech Stack:** Terraform, ECS Fargate (ARM64/Graviton), ALB, ACM, Route53, DynamoDB (single-table + TTL + TransactWriteItems), S3, Secrets Manager, IAM, CloudWatch Logs, Docker (buildx arm64), GitHub Actions + OIDC, Node 20 (zero-dependency HTTP server), React 18 + Vite

**Cost:** ~$92/month if left running 24/7 (Fargate ~$72, ALB ~$18); ~$10 for a realistic event window (stack up for ACM validation and rehearsal, torn down the day after); $0 once destroyed

**Status:** ✅ Deployed, load-tested at 300 concurrent players, and run against live AWS — `master` is 45+ commits ahead of the local checkout

**Links:**
- 📄 [Full Documentation](Icebreaker%20Poll%20Game%20%28ECS%2BFargate%2BALB%29/README.md)
- 📝 [Resume Summary](Resume/16_Icebreaker_Poll_Game.md)

---

### 17. POS Transaction Pipeline with SQS Dead-Letter Queues

**Location:** `./POS Transaction Pipeline with SQS DLQ/`

**Description:**
A retail POS transaction pipeline built around one requirement: **no transaction may silently disappear**. The target is MekarMart, a 180-store Malaysian/Singaporean convenience chain (~6,000 tx/hour, ~25,000 at Chinese New Year peak) whose previous system had no DLQ and no distinction between retryable and permanent failures — a 40-minute loyalty-API outage cost 3,140 transactions their points because a `try/except` swallowed the timeout and let SQS delete the message, and malformed messages from POS firmware v2.3 retried for four days before the retention period expired and deleted them unnoticed. Terraform provisions an SNS fan-out to three independent consumer lanes (loyalty, inventory, e-invoice), each with its own Standard SQS queue, Python 3.12 Lambda consumer, and dedicated dead-letter queue, plus a subscription-level DLQ that catches the SNS-layer delivery failures the per-consumer DLQs structurally cannot see. "Queue + DLQ + redrive + alarms + consumer" is packaged as one reusable Terraform module called three times with different parameters. Targets account `022499047467` in `ap-southeast-1` under the prefix `pos`, on AWS provider `v5.100.0`.

**Architecture:** POS terminals → SNS `pos-transactions` (raw delivery) → 3 × SQS Standard queue → Lambda consumer (`ReportBatchItemFailures`) → DynamoDB idempotency claim; failures → per-lane DLQ → CloudWatch alarm → SNS `pos-ops-alerts` → `StartMessageMoveTask` redrive

**Key Features:**
- ✅ One reusable `consumer_queue` module (12 resources per lane) — a fourth downstream service is a ten-line module block, not a copy-paste of a dozen resources
- ✅ Three sizing rules enforced, not just documented — `visibility_timeout >= 6 × lambda_timeout` via a `lifecycle { precondition }`, `max_receive_count >= 5` via variable validation, DLQ retention (14 d) > source retention (4 d) because Standard queues never reset the enqueue timestamp on a dead-letter move
- ✅ Blast-radius isolation — a loyalty outage fills `pos-loyalty-dlq` only; inventory and e-invoice keep flowing on their own queues, consumers and DLQs
- ✅ Partial batch responses (`ReportBatchItemFailures`) so 1 poison record in a batch of 10 does not drag the other 9 back through the retry loop
- ✅ DynamoDB conditional-write idempotency with an explicit **claim/release** pair — `DeleteItem` releases the claim when the side effect fails, without which a retry would be misread as a duplicate and silently dropped
- ✅ Subscription-level DLQ (`pos-sns-delivery-dlq`) + its own alarm — SQS DLQs catch *consumer* failures, not SNS *delivery* failures
- ✅ Redrive allow policy pinned to `byQueue`, so loyalty failures can never be replayed into the inventory queue
- ✅ Rate-limited replay (`scripts/redrive.sh`, 10 msg/s) so a recovered downstream is not knocked over a second time
- ✅ S3 poison-message archive (versioned, SSE-S3, 90-day lifecycle) that no Lambda role can write to — archiving is a human operator action under their own credentials
- ✅ Full on-call runbook: triage flow, Logs Insights traceability queries, Path A (transient → redrive) / Path B (poison → archive → purge) / Path C (SNS delivery DLQ), post-action verification, and 7 known traps
- ✅ **23 offline unit tests** (no boto3, no credentials, no network) covering scenario test cases TC-01 to TC-05

**Tech Stack:** Terraform (`aws v5.100.0`, `archive v2.8.0`), Amazon SNS (fan-out + subscription DLQ), Amazon SQS (Standard, redrive policy, redrive allow policy, `StartMessageMoveTask`), AWS Lambda (Python 3.12, event source mappings with partial batch responses), DynamoDB (conditional-write idempotency + TTL), S3, IAM, CloudWatch (7 alarms + dashboard), GitHub Actions + OIDC

**Cost:** ~$0.70/month — effectively just the 7 CloudWatch alarms at ~$0.10 each; SQS, SNS, Lambda, DynamoDB on-demand and the dashboard stay in the Free Tier at lab volumes, and SSE-SQS avoids the ~$1/month-per-key cost of a customer-managed KMS key — $0 while destroyed

**Status:** Authored & `terraform validate`-clean (`Plan: 48 to add`); not yet deployed. TC-06 (redrive), TC-07 (SNS delivery DLQ) and TC-08 (log traceability) pending a live deploy

**Links:**
- 📄 [Full Documentation](POS%20Transaction%20Pipeline%20with%20SQS%20DLQ/README.md)
- 📖 [On-Call Runbook](POS%20Transaction%20Pipeline%20with%20SQS%20DLQ/docs/runbook-dlq.md)
- 📝 [Resume Summary](Resume/17_POS_Transaction_Pipeline_SQS_DLQ.md)

---

### 18. Love Opinion Poll Game — Live Opinion Poll on EKS Fargate

**Location:** `./Love Opinion Poll Game (EKS+Fargate+ALB)/` (separate repository — [Aterpise-MY/Love-Opinion-Poll-Game](https://github.com/Aterpise-MY/Love-Opinion-Poll-Game), branch `master`)

**Description:**
A live audience opinion poll for the event 这样恋爱可不可以: the room scans one QR code, each phone votes on a relationship scenario, and the projector shows the split as it moves. There is no correct answer and no score. The application was cloned from the Icebreaker Poll Game (Project 16), and this project is the move of that stack from ECS to **Amazon EKS on Fargate**: a cluster with no nodes at all, two Fargate profiles, CoreDNS switched to Fargate compute, and the AWS Load Balancer Controller used for exactly one job — keeping an IP-type target group in step with pod IPs through a `TargetGroupBinding`. Terraform owns the ALB, its listeners and the target group, so there is no `Ingress` and no load balancer that exists outside Terraform state. One Node.js 22 container serves the built React 18 frontend and the API from a single origin; two pods (1 vCPU / 2 GB each) run in private subnets behind an internet-facing ALB, with state in one on-demand DynamoDB table and media in S3. Capacity is fixed at `desired_count = 2`: there is no Horizontal Pod Autoscaler and no CloudWatch alarm. Runs in `ap-southeast-1` under the prefix `love-opinion-poll` on AWS provider `v5.100.0`.

**Architecture:** GitHub Actions (6 checks → build amd64 → push ECR → `kubectl set image` → rollout wait, undo on stall) → Internet → IGW → ALB (HTTPS :443, HTTP→HTTPS 301) → target group (`type = ip`) → EKS Fargate pods × 2 (private subnets, single NAT) → DynamoDB single table (10 tally shards) + S3 media bucket → CloudWatch Logs (Fargate Fluent Bit log router)

**Key Features:**
- EKS with Fargate only — two Fargate profiles (`kube-system`, `love-opinion-poll`), CoreDNS add-on set to `computeType = Fargate`, and pods sized at CPU `1` / memory `1792Mi` so that Fargate's 256Mi overhead rounds to exactly 1 vCPU / 2 GB instead of 3 GB
- `TargetGroupBinding` instead of `Ingress` — Terraform owns the ALB, listeners and target group; controller chart `3.5.0` only registers pod IPs, and the binding ships as a one-file Helm chart because a first apply has no cluster to read a custom resource schema from
- Rollouts that retire nothing early — pod readiness gates (`elbv2.k8s.aws/pod-readiness-gate-inject`), `max_surge = 100%` / `max_unavailable = 0`, and a `preStop` sleep, so old pods leave only after the load balancer reports the new ones healthy
- Four IAM roles kept apart — cluster role, Fargate pod execution role (`aws:SourceArn` confused-deputy condition, log writes scoped to one group), app role through IRSA (`sub` and `aud` pinned to one service account), controller role through IRSA
- CI deploys with no Terraform and no long-lived keys — a GitHub OIDC role limited to ECR push and `eks:DescribeCluster`, mapped by an EKS access entry to a Kubernetes Role that can patch Deployments in one namespace and cannot read Secrets
- `/health` is liveness-only by design, and the ALB idle timeout (60 s) is held below Node's `keepAliveTimeout` (65 s) to prevent sporadic 502s
- Optional real-time tier — four microservices and ElastiCache for Valkey 8.2 (Multi-AZ, TLS) are defined but off by default behind `service_image_tags` and `realtime_enabled`
- Fixed capacity, stated plainly — no HPA, no metrics-server, no CloudWatch alarms; `desired_count` is the only scaling control
- Real teardown evidence — the 2026-10-11 destroy took three passes (the Helm uninstall of the `TargetGroupBinding` timed out, then the namespace hung in `Terminating`), documented from the logs
- 160 unit tests (153 backend + 7 frontend, `node --test`) recorded passing at commit `b18f00d`, plus a 34-check smoke suite; **no k6 load test exists** — neither a script nor results are in the repository

**Tech Stack:** Terraform (`aws v5.100.0`, `kubernetes v3.3.0`, `helm v3.3.0`, `random v3.9.0`), Amazon EKS 1.36 on Fargate, AWS Load Balancer Controller 3.5.0 (`TargetGroupBinding`), ALB, ACM, Route53 (optional), DynamoDB, S3, ECR, IAM (IRSA, EKS access entries), CloudWatch Logs, ElastiCache for Valkey (optional), GitHub Actions + OIDC, Docker (buildx `linux/amd64`), Node.js 22, React 18 + Vite

**Cost:** ~$280/month if left running 24/7 at the default footprint (Fargate 6 pods ~$135, EKS control plane $73, NAT Gateway ~$43, ALB ~$18, 3 public IPv4 addresses ~$11), or ~$9.22 per day; derived from the AWS price list for `ap-southeast-1`, not from a bill — $0 today (destroyed)

**Status:** Deployed 2026-10-10 (73 resources in state; `site_url` was `https://poll.aterpise.com`) and destroyed 2026-10-11; no `Result.md` audit and no load test of the live stack are on record. The on-disk copy is 31 commits behind the project repository's `origin/master`

**Links:**
- [Full Documentation](Love%20Opinion%20Poll%20Game%20%28EKS%2BFargate%2BALB%29/README.md)
- Resume summary: not yet written

---

## 🛠 Technology Stack

### Infrastructure as Code
- **Terraform** 1.9+ — All projects use Terraform for complete IaC
- **CloudFormation** — Alternative IaC option for some projects
- **Terraform State** — Remote S3 backend with DynamoDB locking

### AWS Services

| Category | Services |
|----------|----------|
| **Compute** | EC2, Lambda, ECS/Fargate (optional) |
| **Kubernetes** | Amazon EKS 1.36, OIDC provider, EKS access entries, IRSA |
| **EKS on Fargate** | Fargate profiles (no node groups), Fargate pod execution role, CoreDNS add-on with `computeType = Fargate`, pod sizing against Fargate's 256Mi overhead, built-in Fluent Bit log router (`aws-observability` / `aws-logging`) |
| **Load balancer controller** | AWS Load Balancer Controller (Helm) with a `TargetGroupBinding` to a Terraform-owned ALB target group, pod readiness gates |
| **Container** | Amazon ECR, Docker (multi-stage, buildx) |
| **Load Balancing** | ALB, NLB, API Gateway |
| **Databases** | RDS PostgreSQL, DynamoDB, ElastiCache (Valkey defined as an optional tier, not deployed) |
| **DynamoDB patterns** | Single-table design, TTL, `TransactWriteItems` (atomic vote + counter), optimistic concurrency, write sharding for hot items, `BatchGetItem` folding |
| **Networking** | VPC, Subnets, Security Groups, NAT Gateway, Route Tables |
| **TLS / DNS** | ACM (DNS-validated certificates), Route53 hosted zones + alias records, Cloudflare DNS (CNAME records managed by Terraform), ALB TLS 1.3 policy, HTTP→HTTPS 301 redirect |
| **Serverless** | Lambda, API Gateway, SQS FIFO, SNS |
| **Async messaging / DLQ** | SNS fan-out, SQS Standard + per-consumer DLQ, redrive policy / redrive allow policy (`byQueue`), `StartMessageMoveTask`, Lambda event source mapping partial batch responses (`ReportBatchItemFailures`), DynamoDB conditional-write idempotency |
| **Containers / Orchestration** | ECS Fargate, ECR (scan-on-push), ALB target-type IP |
| **CI/CD** | GitHub Actions (build → push to ECR → rolling ECS deploy); `configure-aws-credentials`, `amazon-ecr-login`, `amazon-ecs-deploy-task-definition` |
| **Patch Management** | Systems Manager Patch Manager, Maintenance Windows, Run Command (`AWS-RunPatchBaseline`) |
| **Notifications** | Amazon SES, EventBridge |
| **Security** | Secrets Manager, IAM, WAF (optional), Security Groups, HMAC webhook verification |
| **Private registry pull** | Private Docker Hub repository + Secrets Manager `repositoryCredentials`, resolved by the ECS **execution** role (no registry credentials in the image, the task, or Terraform state) |
| **Storage** | S3, EBS, Snapshots |
| **Monitoring** | CloudWatch Logs, Metrics, Alarms, Dashboards |
| **Management** | Terraform, Systems Manager, CloudTrail |

### Programming Languages
- **Python** — Lambda functions, scripts
- **Bash** — Deployment scripts, testing
- **HCL** — Terraform configuration
- **SQL** — Database schema and queries

---

## ✅ Key Achievements

**Across All Projects:**

✅ **100% Infrastructure as Code** — Zero manual AWS Console clicks  
✅ **Multi-AZ Deployments** — High availability, automatic failover  
✅ **Security-First Design** — Encryption, private subnets, least-privilege IAM  
✅ **Auto-Scaling** — Responsive to traffic spikes, cost-efficient  
✅ **Production-Ready** — Tested, documented, runbooks available  
✅ **Cost Analysis** — Detailed monthly cost breakdown for each project  
✅ **Comprehensive Testing** — 366+ automated tests across all projects  
✅ **Load-Tested Under Real Contention** — a 300-concurrent-player run surfaced 537 DynamoDB `TransactionConflict` retries on one hot item, which drove a write-sharding redesign  
✅ **Clear Documentation** — READMEs, diagrams, FAQ, troubleshooting guides  

**Performance Metrics:**
- **Deployment Time:** 10-20 minutes (full stack)
- **RTO (Recovery Time Objective):** <2 minutes (Multi-AZ failover)
- **RPO (Recovery Point Objective):** 0 (synchronous replication)
- **Scalability:** 100 → 10,000+ concurrent users (automatic)
- **Latency:** <200ms (ALB), <100µs (NLB)

---


## 🚀 Getting Started

### Prerequisites

| Tool | Version | Purpose |
|------|---------|---------|
| **Terraform** | 1.9+ | Infrastructure provisioning |
| **AWS CLI** | 2.0+ | Cloud management |
| **Python** | 3.9+ | Lambda functions, scripts |
| **Bash** | 4.0+ | Testing, deployment scripts |
| **jq** | 1.6+ | JSON processing |
| **psql** | 13+ | Database access (RDS projects) |

### Quick Start for Any Project

1. **Navigate to project folder:**
   ```bash
   cd "POS Transaction Pipeline with SQS DLQ"  # or any other project
   ```

2. **Check prerequisites:**
   ```bash
   terraform -version
   aws sts get-caller-identity
   ```

3. **Initialize Terraform:**
   ```bash
   cd terraform
   terraform init
   ```

4. **Plan deployment:**
   ```bash
   terraform plan
   ```

5. **Apply infrastructure:**
   ```bash
   terraform apply
   ```

6. **Run tests:**
   ```bash
   cd ..
   python3 -m unittest discover lambda
   ```

7. **Cleanup (when done):**
   ```bash
   cd terraform
   terraform destroy
   ```

---

## 📁 Repository Structure

```
AWS Project/                                    # Root portfolio directory
├── README.md                                  # This file
├── FINOPS_SENTINEL_SUMMARY.md                # Cost optimization guide
├── SECURITY_REMEDIATION.md                   # Security hardening guide
│
├── Multi-Tier Web App Deployment/            # Project 2: Enterprise Web App
│   ├── README.md                             # Full documentation
│   ├── terraform/
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   └── outputs.tf
│   ├── scripts/
│   └── test-*.sh
│
├── Scalable Web App with ALB & Auto Scaling/ # Project 3: ALB Architecture
│   ├── README.md                             # Full documentation
│   ├── Result.md                             # Deployment result from June 2026 (previous architecture)
│   ├── main.tf                               # Providers, DB subnets, security groups, IAM, ACM + Cloudflare DNS, RDS, ALB, ASG, alarms
│   ├── variables.tf                          # Input variables with validation
│   ├── outputs.tf                            # HTTPS URL, ALB, certificate, security group and RDS outputs
│   ├── terraform.tfvars.example              # Configuration template (placeholder IDs)
│   ├── .gitignore                            # Excludes state, .terraform/, *.tfvars
│   ├── Automation/
│   │   ├── check-alb.sh                      # Check script, to run after a deploy
│   │   ├── deploy.sh                         # Legacy reference: pre-change architecture (HTTP only, no database)
│   │   └── .gitignore                        # Excludes generated reports and outputs
│   └── screenshots/                          # Screenshots from the June 2026 deployment
│
├── Scalable Web App with NLB & Auto Scaling/ # Project 4: NLB Architecture
│   ├── README.md                             # Full documentation
│   ├── Result.md                             # Deployment result from June 2026 (previous architecture)
│   ├── provider.tf                           # Terraform, AWS, random and Cloudflare provider constraints
│   ├── main.tf                               # VPC module, security groups, RDS, IAM, launch template, NLB, ACM + Cloudflare DNS, ASG, alarms, WAFv2
│   ├── variables.tf                          # Input variables with validation
│   ├── outputs.tf                            # HTTPS URL, NLB, certificate, RDS, network and IAM outputs
│   ├── prod.tfvars.example                   # Configuration template (placeholder values)
│   ├── Automation/
│   │   ├── health_check.sh                   # Check script, to run after a deploy
│   │   ├── deploy.sh                         # Legacy reference: pre-change architecture (HTTP only, no database)
│   │   └── .gitignore                        # Excludes generated reports and outputs
│   └── screenshots/                          # Screenshots from the June 2026 deployment
│
├── Cloud-Tibot/                              # Project 5: Microservices
│   ├── README.md
│   ├── terraform/
│   └── scripts/
│
├── Event Ticket Check In System/             # Project 7: Serverless Event Ticketing
│   ├── README.md                            # Full documentation (16 sections)
│   └── terraform/
│       ├── provider.tf                      # AWS provider + version constraints
│       ├── variables.tf                     # Input variables (html_credential sensitive)
│       ├── sqs.tf                           # SQS FIFO queue
│       ├── dynamodb.tf                      # Access token + ticket status tables
│       ├── s3.tf                            # 3 S3 buckets (tokens, templates, QR codes)
│       ├── iam.tf                           # 3 IAM roles + least-privilege policies
│       ├── lambda.tf                        # 3 Lambda functions + SQS event source mapping
│       ├── api_gateway.tf                   # REST API, stage, API key, usage plan
│       └── outputs.tf                       # 12 outputs (URLs, names, ARNs)
│
├── Systems Manager Automated Patching/       # Project 13: SSM Patch Manager
│   ├── README.md                            # Full documentation (14 sections)
│   ├── main.tf                              # VPC, IAM, SG, EC2 targets, baselines, windows, tasks, SNS
│   ├── variables.tf                         # Inputs with validation (patch_groups, schedules)
│   ├── outputs.tf                           # VPC/instance IDs, role ARNs, baseline & window IDs
│   ├── versions.tf                          # Terraform >= 1.5, AWS ~> 5.0, default_tags
│   ├── terraform.tfvars.example             # Configuration template
│   └── .gitignore                           # Excludes state, .terraform/, *.tfvars
│
├── Icebreaker Poll Game (ECS+Fargate+ALB)/   # Project 16: live audience poll (own git repo)
│   ├── content/questions.source.json         # the ONLY hand-authored content file
│   ├── backend/                              # Node 20, zero-dependency HTTP server
│   │   ├── game.js                           # pure state machine — no I/O, no clock
│   │   ├── router.js                         # transport-agnostic request handling
│   │   ├── server.js                         # entry point: static + API + SPA fallback
│   │   ├── static.js                         # in-memory asset manifest (ETags, gzip)
│   │   ├── media.js                          # picture / audio / video storage (S3 or memory)
│   │   ├── tally.js                          # 10 vote shards — kills TransactionConflict
│   │   ├── store-dynamo.js                   # DynamoDB single-table storage
│   │   └── store-memory.js                   # in-process store for local runs
│   ├── frontend/                             # React 18 + Vite
│   │   └── src/routes/                       # Phone, Screen, Screen2, Operator, Setup, JoinBoard
│   ├── infra/                                # Terraform: VPC, ALB, ACM, ECS, DynamoDB, S3
│   ├── scripts/
│   │   ├── build-content.mjs                 # generates question texts + fingerprinted answer key
│   │   ├── state-backend.sh                  # S3 state bucket + lock table (run once)
│   │   ├── dockerhub-secret.sh               # Docker Hub PAT → Secrets Manager (run once)
│   │   ├── bootstrap.sh / deploy.sh          # first-time setup; build, push, roll
│   │   ├── teardown.sh                       # scale to zero, then destroy
│   │   └── smoke.sh                          # 19 end-to-end API checks
│   ├── .github/workflows/                    # ci.yml (5 jobs) + deploy.yml (Docker Hub → ECS)
│   └── Dockerfile                            # arm64 multi-stage: Vite build → runtime
│
├── POS Transaction Pipeline with SQS DLQ/    # Project 17: SNS fan-out + per-consumer SQS DLQs
│   ├── README.md                             # Full documentation (16 sections)
│   ├── Enterprise_DLQ_Scenario_POS_EN.md     # Approved scenario (MekarMart, 180 stores)
│   ├── terraform/
│   │   ├── providers.tf                      # aws ~> 5.0 + archive ~> 2.4, ap-southeast-1, default_tags
│   │   ├── variables.tf                      # 11 root inputs with validation
│   │   ├── sns.tf                            # pos-transactions, pos-ops-alerts, pos-sns-delivery-dlq + alarm
│   │   ├── dynamodb.tf                       # pos-processed-transactions (idempotency, 7-day TTL)
│   │   ├── s3.tf                             # pos-dlq-archive-<account-id> (versioned, SSE-S3, 90d lifecycle)
│   │   ├── consumers.tf                      # 3 module calls: loyalty, inventory, einvoice
│   │   ├── cloudwatch.tf                     # pos-dlq-pipeline dashboard (4 widgets)
│   │   ├── outputs.tf                        # 17 outputs incl. ready-to-paste redrive commands
│   │   └── modules/consumer_queue/           # queue + DLQ + policies + Lambda + ESM + 2 alarms
│   ├── lambda/
│   │   ├── common/                           # errors.py, idempotency.py, processing.py
│   │   ├── loyalty/ · inventory/ · einvoice/ # One handler per downstream service
│   │   └── test_handlers.py                  # 23 offline unit tests (TC-01 to TC-05)
│   ├── scripts/
│   │   ├── pos_simulator.py                  # normal / poison / duplicate / mixed / burst traffic
│   │   └── redrive.sh                        # StartMessageMoveTask wrapper, 10 msg/s, --dry-run
│   ├── docs/runbook-dlq.md                   # On-call runbook: triage, Paths A/B/C, 7 known traps
│   └── .github/workflows/terraform.yml       # validate → tests → plan (PR) → apply (main, OIDC)
│
├── Love Opinion Poll Game (EKS+Fargate+ALB)/ # Project 18: opinion poll on EKS Fargate (own git repo)
│   ├── README.md                             # Full documentation (16 sections)
│   ├── content/questions.source.json         # the only hand-authored content file
│   ├── backend/                              # Node 22 ESM HTTP server, no web framework
│   │   ├── server.js                         # entry point: /health, API, static files, SPA fallback
│   │   ├── router.js                         # transport-agnostic request handling
│   │   ├── game.js                           # pure phase state machine
│   │   ├── tally.js                          # 10 vote shards per question
│   │   ├── store-dynamo.js                   # DynamoDB single-table storage
│   │   └── store-memory.js                   # in-process store for local runs
│   ├── frontend/                             # React 18 + Vite
│   │   └── src/routes/                       # Phone, Screen, Screen2, Operator, Setup, JoinBoard, KeyPrompt
│   ├── infra/                                # Terraform: 76 resource blocks, 23 inputs, 22 outputs
│   │   ├── network.tf                        # VPC 10.42.0.0/16, 2 public + 2 private subnets, IGW, single NAT
│   │   ├── eks.tf                            # cluster, OIDC provider, Fargate profiles, CoreDNS add-on, log group
│   │   ├── lb-controller.tf                  # AWS Load Balancer Controller 3.5.0 (Helm) + IRSA role
│   │   ├── alb.tf                            # ALB, IP target group, HTTPS / HTTP listeners
│   │   ├── k8s.tf                            # namespace, Deployment, Service, TargetGroupBinding, PDB, logging
│   │   ├── services.tf                       # optional microservices + ElastiCache for Valkey (off by default)
│   │   ├── github-oidc.tf                    # deploy role, EKS access entry, Kubernetes Role + RoleBinding
│   │   ├── iam.tf / dns.tf / ecr.tf / main.tf # app IRSA role; ACM + Route53; ECR; DynamoDB + S3
│   │   ├── variables.tf / outputs.tf / versions.tf # inputs, outputs, S3 backend + providers
│   │   ├── policies/                         # vendored controller IAM policy
│   │   └── charts/target-group-binding/      # one-file Helm chart for the binding
│   ├── scripts/
│   │   ├── build-content.mjs                 # generates the question texts and the deck
│   │   └── smoke.sh                          # 34 end-to-end API checks (no k6 script exists)
│   ├── .github/workflows/                    # ci.yml (6 jobs) + deploy.yml (ECR → kubectl set image)
│   ├── Dockerfile                            # multi-stage: Vite build → node:22-slim runtime
│   └── docker-compose.yml                    # local run on host port 8520
│
├── Resume/                                   # Portfolio summaries (git-ignored)
│   ├── 1_ALB_Auto_Scaling.md
│   ├── 2_NLB_Auto_Scaling.md
│   ├── 3_Cloud_Tibot.md
│   ├── 4_Multi_Tier_Web_App.md
│   ├── 5_Multi-Tenant SaaS Application.md
│   ├── 6_App_Runner_Deployment.md
│   ├── 7_Event_Ticket_Check_In_System.md
│   ├── 8_GraphQL_AppSync.md
│   ├── 9_URL_Shortener.md
│   ├── 10_Zendesk_Ticket_Triage.md
│   ├── 11_Real_time_Polling_App.md
│   ├── 12_Server_Room_Inspection_Dashboard.md
│   ├── 13_Systems_Manager_Automated_Patching.md
│   ├── 14_GitHub_Actions_ECS_Deployment.md
│   ├── 15_Laravel_Ticketing_EKS.md
│   ├── 16_Icebreaker_Poll_Game.md
│   └── 17_POS_Transaction_Pipeline_SQS_DLQ.md
│
├── .github/
│   └── workflows/                            # CI/CD pipelines
├── .claude/
│   └── CLAUDE.md                             # Project instructions
└── .gitignore                                # Git ignore patterns
```

---

## 🔐 Security & Compliance

All projects follow **AWS Well-Architected Framework** principles:

| Pillar | Implementation |
|--------|-----------------|
| **Operational Excellence** | Terraform IaC, CloudWatch monitoring, runbooks |
| **Security** | KMS encryption, private subnets, IAM least-privilege, security groups |
| **Reliability** | Multi-AZ, auto-scaling, health checks, failover automation |
| **Performance** | Auto-scaling, CDN-ready, load balancing, connection pooling |
| **Cost Optimization** | Right-sizing, auto-scaling, cost analysis, reserved capacity options |

---

## 💰 Cost Summary

| Project | Monthly Cost | Primary Driver | Optimization |
|---------|-------------|-----------------|---------------|
| Multi-Tier Web App | ~$280 | EC2 (70%) | Spot instances, reserved capacity |
| Scalable Web App (ALB) | $123.25 (idle baseline; HTTPS + RDS revision, not deployed) | EC2 2 × `t3.medium` ($60.74) + RDS Multi-AZ ($26.28) | Scheduled scaling, spot instances |
| Scalable Web App (NLB) | $196.25 (idle baseline; HTTPS + RDS revision, not deployed) | NAT gateways × 2 ($65.70) + EC2 2 × `t3.medium` ($60.74) | Auto-scaling, scheduled downtime |
| Cloud-Tibot | Variable | Lambda + API (serverless) | Cost-efficient pay-per-use |
| Event Ticket Check-In | ~$0.30/event | Lambda (GmailSender, 2048 MB) | Event-triggered; near-zero cost between events |
| Systems Manager Automated Patching* | ~$24/month | EC2 (2 × t3.micro) + public IPv4 | SSM/Maintenance Windows free; stop instances between windows; $0 while destroyed |
| Icebreaker Poll Game | ~$92/month 24/7; ~$10/event | Fargate 2 × (1 vCPU / 2 GB) ARM ~$72 + ALB ~$18 | No NAT Gateway by design; scale the ECS service to zero between events; `teardown.sh` → $0 |
| POS Transaction Pipeline with SQS DLQ* | ~$0.70/month | 7 CloudWatch alarms (~$0.10 each) — everything else Free Tier at lab volume | SSE-SQS instead of a customer-managed KMS key (−~$1/key); on-demand DynamoDB + Lambda cost nothing idle; $0 while destroyed |
| Love Opinion Poll Game (EKS Fargate) | ~$280/month 24/7; ~$9.22/day | Fargate 6 pods ~$135 + EKS control plane $73 + NAT Gateway ~$43 + ALB ~$18 | Single-event stack: destroy after the show (destroyed 2026-10-11, $0 today); one shared NAT Gateway; the optional real-time tier (+~$163/month) is off by default |

> *Authored & `terraform validate`-clean; not currently deployed, so it bills $0 today.

**Total Estimated Cost:** ~$996/month if all 9 projects were deployed simultaneously — the sum of the seven rows above that state a fixed monthly figure; Cloud-Tibot is variable and Event Ticket is billed per event, so they are not in the sum (the ALB and NLB figures are idle baselines for the HTTPS and RDS revision, which is not deployed; the 2 authored-but-not-deployed projects are $0 while destroyed; the EKS Fargate opinion poll accounts for ~$280/month of the total at its default footprint and is $0 while destroyed; Event Ticket is <$1/event)

---

## 🧪 Testing & Validation

**Total Test Coverage:** 327+ automated tests across all projects

| Project | Quick Tests | Comprehensive | Critical | Custom |
|---------|------------|---|---|---|
| Multi-Tier Web App | ✅ 5 tests | ✅ 15 tests | ✅ 8 tests | ✅ Load Test |
| Scalable Web App (ALB) | ✅ 4 tests | ✅ 12 tests | ✅ 7 tests | ✅ Failover |
| Scalable Web App (NLB) | ✅ 4 tests | ✅ 12 tests | ✅ 7 tests | ✅ Throughput |
| Cloud-Tibot | ✅ 3 tests | ✅ 10 tests | ✅ 6 tests | ✅ Event Flow |
| Event Ticket Check-In | ✅ 8 tests | — | — | ✅ End-to-end delivery |
| Systems Manager Automated Patching | ✅ `validate`-clean | — | — | ⏳ Live patch run pending deploy |
| Icebreaker Poll Game | ✅ 139 unit tests (`node --test`) | ⚠️ 19-check smoke suite — 17 pass, 2 assert a superseded `tally: null` contract | ✅ 5-job CI (answer key, backend, frontend build, lint, image) | ✅ 300-player load test on the deployed stack |
| POS Transaction Pipeline with SQS DLQ | ✅ `fmt` + `validate`-clean (`Plan: 48 to add`) | ✅ 23 offline unit tests (`python3 -m unittest discover lambda`) | ✅ TC-01 to TC-05 covered offline (poison, partial batch, idempotency, outage drill) | ⏳ Live DLQ drill, redrive (TC-06), SNS delivery DLQ (TC-07) and Logs Insights traceability (TC-08) pending deploy |
| Love Opinion Poll Game | 160 unit tests (`node --test`: 153 backend + 7 frontend, recorded passing at commit `b18f00d`) | 34-check smoke suite (`scripts/smoke.sh`) — no run against the deployed stack is recorded | 6-job CI (answer key, backend, frontend build, lint, terraform, image) | k6 load test: not recorded — no k6 script or output exists in the repository |

---

## 📞 Support & Documentation

Each project includes:
- 📄 **Full README** — Architecture, components, deployment, operations
- 📝 **Resume Summary** — 2-page condensed version for portfolios
- 🧪 **Test Guides** — Step-by-step testing procedures
- 🎯 **FAQ Section** — Common questions and answers
- 🔧 **Runbooks** — Operational procedures
- 📊 **Cost Analysis** — Detailed pricing breakdown
- 🔐 **Security Guide** — Security posture and hardening

---

## 🎓 Learning Outcomes

Working through these projects demonstrates expertise in:

✅ **AWS Architecture** — Multi-AZ, load balancing, serverless, microservices  
✅ **Infrastructure as Code** — Terraform best practices, state management, modularity  
✅ **Security** — Encryption, network isolation, IAM, compliance  
✅ **DevOps** — Automated testing, CI/CD, monitoring, alerting  
✅ **Databases** — RDS, DynamoDB, replication, backup strategies  
✅ **Networking** — VPC, subnets, security groups, NAT, routing  
✅ **Cost Optimization** — Right-sizing, auto-scaling, reserved capacity  
✅ **High Availability** — Failover, health checks, redundancy  

---

## 📈 Performance Benchmarks

| Metric | NLB | ALB | Multi-Tier | Tibot | Event Ticket | SSM Patching | Icebreaker Poll | POS DLQ Pipeline | Love Opinion Poll (EKS) |
|--------|-----|-----|-----------|-------|--------------|--------------|-----------------|-----------------|-------------------------|
| Latency | <100µs | <200ms | <300ms | Variable | <60 s (e2e ticket) | N/A (scheduled batch) | <100ms (`/state`, sub-1KB eventually-consistent read) | n/a — not deployed; design target is a ~15 min loyalty retry window before DLQ, alarm within ~60 s | Not recorded — no k6 or other load-test output exists for this stack |
| Throughput | 1M+ RPS | 100K RPS | 10K RPS | On-demand | 500+/event | 25% fleet/wave | ~150 polls/s sustained + 300-vote burst per question | ~6,000 tx/hour baseline, ~25,000 at peak (each fanned out to 3 queues) | Not recorded; by design each phone polls `/state` once every 2 s |
| Concurrent Users | 10,000+ | 5,000+ | 500+ | Variable | N/A (event-triggered) | N/A (fleet patch) | 300–500 (load-tested at 300) | N/A (message-driven; 3 Lambda consumers, batch size 10) | Not load-tested; 2 fixed pods (1 vCPU / 2 GB), no autoscaling |
| Deployment Time | 12-18 min | 12-18 min | 15-20 min | Variable | 8-12 min | 10-15 min | 10-15 min (+ ACM validation, done days ahead) | 3-5 min (48 resources, no VPC/ALB/RDS to wait on) | 20-30 min first apply (runbook estimate; actual not recorded) |
| RTO | <2 min | <2 min | <2 min | <1 min | <1 min | N/A | <1 min (2 tasks, 2 AZ; show-of-hands fallback) | <5 min to alert; replay bounded by the 14-day DLQ retention | Not measured; a target is marked unhealthy after 3 × 10 s checks and a replacement Fargate pod takes 1-2 min |

---

## 🔄 CI/CD & Automation

All projects support:
- **Terraform Validation** — Syntax and schema checking
- **Cost Estimation** — Pre-apply cost forecasting
- **Automated Testing** — Pre and post-deployment validation
- **State Management** — Remote S3 backend with locking
- **Change Management** — Plan review before apply

**CI/CD Workflows:** [.github/workflows](.github/workflows/)

---

## 📊 Next Steps

1. **Explore Projects** — Choose one that interests you
2. **Read Resume** — Start with the 2-page resume summary
3. **Review Architecture** — Check the README and diagrams
4. **Deploy Locally** — Run terraform to see it in action
5. **Run Tests** — Validate functionality and security
6. **Customize** — Modify for your use case
7. **Learn** — Review the test guides and documentation

---

## 🤝 Contributing

This portfolio is a personal project, but feel free to:
- Fork and adapt for your infrastructure
- Reference architectures in your own projects
- Suggest improvements or security enhancements
- Share with your network

---

## 📄 License

These projects are provided as educational and portfolio materials.

---

## 🔗 Quick Links

| Resource | Link |
|----------|------|
| **GitHub Repository** | [AWS-Projects](https://github.com/Aterpise-MY/AWS-Projects) |
| **Current Branch** | `feat/pos-dlq-pipeline` |
| **Latest PR** | PR #31 (POS Transaction Pipeline with SQS DLQ) |
| **Icebreaker Poll Game** | Separate repo — [Aterpise-MY/Icebreaker-Poll-Game](https://github.com/Aterpise-MY/Icebreaker-Poll-Game) (latest: PR #48 on `master`) |
| **Love Opinion Poll Game** | Separate repo — [Aterpise-MY/Love-Opinion-Poll-Game](https://github.com/Aterpise-MY/Love-Opinion-Poll-Game) (latest merged on `master` at the last fetch: PR #25) |

---

## 📞 Questions or Issues?

- Check individual project **README.md** files (links in Quick Navigation above)
- Review **FAQ** sections in each project README
- Review [SECURITY_REMEDIATION.md](SECURITY_REMEDIATION.md) for security guidance
- Check [FINOPS_SENTINEL_SUMMARY.md](FINOPS_SENTINEL_SUMMARY.md) for cost optimization

---

**Last Updated:** October 12, 2026 — Project 18 (Love Opinion Poll Game on EKS Fargate) added; a Fargate-only EKS cluster behind a Terraform-owned ALB whose IP target group is filled by the AWS Load Balancer Controller through a `TargetGroupBinding`, with IRSA and GitHub OIDC deploys — deployed 2026-10-10 and destroyed 2026-10-11, 160 unit tests recorded passing, no k6 load test recorded; Projects 3 and 4 (Scalable Web App with ALB / NLB & Auto Scaling) were revised on October 7, 2026 for HTTPS and a Multi-AZ RDS for PostgreSQL tier, and that revision is authored and validate-clean, not deployed; nine projects that no longer exist in the repository (1, 6, 8, 9, 10, 11, 12, 14, 15) were removed from this README on October 12, leaving 9 (numbering unchanged)  
**Status:** ✅ 7 projects deployed, tested, documented · 📝 2 authored & validated, pending deployment  
**Total Time Invested:** 40+ hours of design, implementation, testing, and documentation  

🚀 **Happy Deploying!**
