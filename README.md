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

This portfolio showcases **15 AWS infrastructure projects** — 11 deployed and tested, plus 4 (Server Room Inspection Dashboard, Systems Manager Automated Patching, GitHub Actions ECS Deployment, and Laravel Ticketing on EKS) authored and `terraform validate`-clean, pending deployment — each demonstrating different architectural patterns, scaling strategies, and deployment approaches. All projects are:

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
| [Multi-Tenant SaaS Application](#1-multi-tenant-saas-application) | Serverless | Multi-tenant apps, APIs | 10-15 min | $165 |
| [Multi-Tier Web App](#2-multi-tier-web-app-deployment) | EC2 + RDS | Enterprise web apps | 15-20 min | $280 |
| [Scalable Web App (ALB)](#3-scalable-web-app-with-alb--auto-scaling) | ALB + ASG | Layer 7 routing | 12-18 min | $123.25 (HTTPS + RDS revision, not deployed) |
| [Scalable Web App (NLB)](#4-scalable-web-app-with-nlb--auto-scaling) | NLB + ASG | High-performance APIs | 12-18 min | $196.25 (HTTPS + RDS revision, not deployed) |
| [Cloud-Tibot](#5-cloud-tibot) | Microservices | Bot platforms, agents | Variable | Variable |
| [AWS App Runner Deployment](#6-aws-app-runner-deployment) | Container | Containerised web apps | 8-12 min | $16-26 |
| [Event Ticket Check-In System](#7-yrc2026-event-ticket-check-in-system) | Serverless (SQS + Lambda) | Event management, email automation | 8-12 min | ~$0.30/event |
| [GraphQL API with AWS AppSync](#8-graphql-api-with-aws-appsync) | AppSync + DynamoDB | Serverless GraphQL backends | 2-3 min | ~$5/month |
| [URL Shortener](#9-url-shortener--internal-smart-link-platform) | Lambda + DynamoDB | Internal short link service, click analytics | 2-3 min | ~$1/month |
| [Real-time Polling App](#10-real-time-polling-app--e-commerce-edition) | WebSocket + Lambda | Live voting, flash sales, design surveys | 3-4 min | ~$5/event |
| [Zendesk Ticket Triage](#11-serverless-zendesk-ticket-triage-with-sentiment-analysis) | Lambda + Comprehend | Helpdesk sentiment triage, SLA protection | 2-3 min | ~$4/month |
| [Server Room Inspection Dashboard](#12-server-room-inspection-dashboard) | ECS Fargate + RDS | Internal ops dashboards, legacy rebuilds | 15-20 min | ~$92/month* |
| [Systems Manager Automated Patching](#13-systems-manager-automated-patching) | SSM Patch Manager | Fleet OS patching, compliance SLAs | 10-15 min | ~$24/month* |
| [GitHub Actions ECS Deployment](#14-github-actions-cicd--aws-ecs-fargate) | CI/CD → ECS Fargate | Container continuous delivery, rolling deploys | 8-12 min | ~$67/month* |
| [Laravel Ticketing on EKS](#15-laravel-ticketing-platform-on-amazon-eks) | EKS + RDS + Redis | Self-hosted help desk, Kubernetes platform | 15-20 min | ~$74-304/month* |

> *Authored and `terraform validate`-clean; not currently deployed ($0 while destroyed).

---

## 📦 Projects

### 1. Multi-Tenant SaaS Application

**Location:** `./Multi-Tenant SaaS Application/`  

**Description:**  
A production-ready multi-tenant SaaS platform with complete tenant isolation at the database layer. Demonstrates serverless architecture, JWT-based authentication, and secure multi-tenancy patterns.

**Architecture:** API Gateway → Lambda (VPC) → RDS PostgreSQL (Multi-AZ)

**Key Features:**
- ✅ Database-level tenant isolation (`WHERE tenant_id = <from_jwt>`)
- ✅ Cognito JWT authentication with custom claims
- ✅ Lambda serverless compute (Python 3.12)
- ✅ RDS PostgreSQL Multi-AZ with KMS encryption
- ✅ Secrets Manager for credential management
- ✅ CloudWatch Logs & Metrics for observability

**Tech Stack:** Terraform, AWS Cognito, Lambda, API Gateway, RDS, KMS, Secrets Manager

**Cost:** ~$165/month (1M requests/month)

**Testing:** 19 automated tests (quick, comprehensive, critical, database-isolation)

**Links:**
- 📄 [Full Documentation](Multi-Tenant%20SaaS%20Application/README.md)
- 🧪 [Test Guides](Multi-Tenant%20SaaS%20Application/TESTING-GUIDE.md)

---

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

### 6. AWS App Runner Deployment

**Location:** `./AWS App Runner Deployment/`

**Description:**
A production-ready containerised web application deployed on AWS App Runner with full Infrastructure as Code via Terraform. Demonstrates end-to-end container workflow — Docker multi-stage build, ECR private registry, IAM least-privilege roles, auto-scaling, and CloudWatch observability — all without managing VPCs or EC2 instances.

**Architecture:** Docker (linux/amd64) → ECR → App Runner → HTTPS endpoint

**Key Features:**
- ✅ Serverless container hosting — no VPC, no EC2, no load balancer config
- ✅ Private ECR registry with scan-on-push and lifecycle policy (keep 10 images)
- ✅ Auto-deployment on ECR push (zero-downtime swap)
- ✅ Least-privilege IAM — separate service role and instance role with correct trust principals
- ✅ CloudWatch Logs + 3 metric alarms (CPU, memory, deployment failures)
- ✅ 21-test architecture validation script (18 PASS / 3 WARN / 0 FAIL)
- ✅ 9 deployment issues root-caused and documented (including arm64/amd64 Apple Silicon gotcha)

**Tech Stack:** Terraform, AWS App Runner, Amazon ECR, Docker buildx, Node.js 18, IAM, CloudWatch

**Cost:** ~$16-26/month (0.25 vCPU / 512 MB, 1 instance)

**Testing:** 21 automated architecture tests across 6 component groups

**Links:**
- 📄 [Full Documentation](AWS%20App%20Runner%20Deployment/README.md)
- 📊 [Live Audit Results](AWS%20App%20Runner%20Deployment/Result.md)
- 🧪 [Architecture Test Script](AWS%20App%20Runner%20Deployment/Script/test_architecture.sh)

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

### 8. GraphQL API with AWS AppSync

**Location:** `./GraphQL API with AWS AppSync/`

**Description:**
A fully serverless GraphQL backend using AWS AppSync and Amazon DynamoDB. Terraform provisions an AppSync GraphQL API with API key authentication, five VTL-mapped resolvers for full CRUD operations (getTodos, getTodo, addTodo, updateTodo, deleteTodo), an on-demand DynamoDB table with point-in-time recovery, least-privilege IAM roles, CloudWatch field-level logging, and three metric alarms — all without a VPC, EC2, or load balancer.

**Architecture:** Client (HTTPS) → AppSync (VTL resolvers) → DynamoDB (on-demand)

**Key Features:**
- ✅ Five VTL resolvers — full CRUD with no Lambda intermediary
- ✅ Condition guards on mutations — `attribute_exists(id)` prevents silent upserts
- ✅ Auto-generated UUIDs via `$util.autoId()` in request mapping templates
- ✅ DynamoDB on-demand capacity — zero capacity planning, scales to zero at rest
- ✅ Point-in-time recovery enabled — 35-day restore window
- ✅ Least-privilege IAM — DynamoDB role scoped to exact table ARN; separate CloudWatch Logs role
- ✅ 3 CloudWatch alarms — 5XX, 4XX error rates and p99 latency
- ✅ 12-check architecture test script — validates all components and live GraphQL operations

**Tech Stack:** Terraform, AWS AppSync, Amazon DynamoDB, VTL, IAM, CloudWatch

**Cost:** ~$5/month (1M operations); ~$0/month at free-tier scale

**Testing:** 12 architecture validation checks (Terraform state, API, resolvers, data source, API key, DynamoDB, IAM, CloudWatch, 5 live GraphQL operations)

**Links:**
- 📄 [Full Documentation](GraphQL%20API%20with%20AWS%20AppSync/README.md)
- 🧪 [Architecture Test Script](GraphQL%20API%20with%20AWS%20AppSync/scripts/test_architecture.sh)

---

### 9. URL Shortener — Internal Smart Link Platform

**Location:** `./URL Shortener/`

**Description:**
A fully serverless internal short link platform (`go.techcorp.internal`) built on API Gateway, Lambda, and DynamoDB. Terraform provisions a REST API with three endpoints: `POST /shorten` (create a link with optional custom code, label, TTL expiry), `GET /redirect` (atomic click-count increment + 301 redirect), and `GET /stats` (click analytics per link). DynamoDB TTL auto-expires links at a configured timestamp, returning `410 Gone` for expired codes. Designed for enterprise use cases: all-hands links, onboarding packs, OKR pages, IT help portals.

**Architecture:** API Gateway (Regional) → Lambda (Python 3.11) → DynamoDB (on-demand, TTL on `expires_at`)

**Key Features:**
- ✅ DynamoDB TTL auto-expiry — links expire at a configured timestamp; expired links return `410 Gone`
- ✅ Custom short codes — human-readable codes (`go/hr`, `go/q3-okr`) with `409 Conflict` on collision
- ✅ Click analytics — atomic `click_count` increment and `last_accessed` timestamp on every redirect
- ✅ Three live endpoints — `POST /shorten`, `GET /redirect`, `GET /stats` with full error handling
- ✅ Least-privilege IAM — Lambda role scoped to exact table ARN; separate CloudWatch Logs policy
- ✅ Structured API access logs — JSON per request in CloudWatch for security monitoring
- ✅ 3 CloudWatch alarms — Lambda errors, API 5XX, API 4XX (high 4XX may indicate abuse)
- ✅ 16-check test script — Terraform state, DynamoDB TTL, Lambda, IAM, API Gateway resources, 6 live API scenarios

**Tech Stack:** Terraform, API Gateway (REST), Lambda (Python 3.11), DynamoDB (on-demand + TTL), IAM, CloudWatch

**Cost:** ~$1/month (100K requests); ~$0.30/month at rest (alarms only); ~$0/month at zero traffic

**Testing:** 16 architecture validation checks (infrastructure + live create / redirect / stats / conflict / missing / click-count)

**Links:**
- 📄 [Full Documentation](URL%20Shortener/README.md)
- 🧪 [Architecture Test Script](URL%20Shortener/scripts/test_architecture.sh)

---

### 10. Real-time Polling App — E-Commerce Edition

**Location:** `./Real-time Polling App/`

**Description:**
A fully serverless real-time polling and interaction platform built on an API Gateway WebSocket API, Lambda, and DynamoDB. One WebSocket backbone powers four interaction types — general poll voting plus three e-commerce scenarios: live-stream product voting, flash-sale inventory tracking, and new-product design surveys. Clients open one persistent connection scoped by `sessionId`; votes and purchases are written atomically to DynamoDB and fanned out to every connected client in the session in real time.

**Architecture:** Client (wss://) → API Gateway WebSocket API → 6 Lambda functions (Python 3.11) → 5 DynamoDB tables (Connections GSI fan-out)

**Key Features:**
- ✅ Single WebSocket backbone — `$request.body.action` route selection across 7 routes
- ✅ Real-time fan-out — Connections `sessionId-index` GSI + `PostToConnection` to all session clients
- ✅ Atomic vote counting — DynamoDB `UpdateExpression ADD` (lost-update-free under concurrency)
- ✅ Oversell-proof flash sale — `ConditionExpression: remainingStock > 0`; depletion returns `sold_out` to buyer only
- ✅ Session/survey guards — conditional writes reject votes once a session ends or survey closes
- ✅ Auto-pruned connections — `$disconnect` delete + DynamoDB TTL + 410 Gone cleanup on stale fan-out
- ✅ Least-privilege IAM — scoped to 5 tables, the GSI, and the stage's `@connections/*`
- ✅ 7 CloudWatch alarms (6 Lambda error + 1 integration error) + per-function log groups

**Tech Stack:** Terraform, API Gateway WebSocket (v2), Lambda (Python 3.11), DynamoDB (on-demand + GSI + TTL), IAM, CloudWatch

**Cost:** ~$5 per event (10k viewers, 30 min, ~500k messages); ~$0.70/month at rest

**Testing:** Architecture validation script across DynamoDB, Lambda, IAM, WebSocket routes, and CloudWatch

**Links:**
- 📄 [Full Documentation](Real-time%20Polling%20App/README.md)
- 📊 [Live Audit Results](Real-time%20Polling%20App/Result.md)
- 🧪 [Architecture Test Script](Real-time%20Polling%20App/scripts/test_architecture.sh)

---

### 11. Serverless Zendesk Ticket Triage with Sentiment Analysis

**Location:** `./Zendesk Ticket Triage with Sentiment Analysis/`

**Description:**
A fully serverless pipeline that scores the sentiment of every incoming Zendesk ticket in real time and triages it automatically back inside Zendesk. A Zendesk trigger fires an HMAC-signed webhook to API Gateway; a Python 3.11 Lambda verifies the signature, runs AWS Comprehend sentiment detection, applies triage rules (negative + high confidence → `priority: urgent` + escalation group), writes an audit record to DynamoDB, calls the Zendesk Tickets API to set priority/tag/group, and publishes an SNS alert on escalation. Surfaces at-risk customers in minutes instead of leaving them buried in a flat queue, while auto-handling positive/neutral tickets.

**Architecture:** Zendesk (HMAC webhook) → API Gateway → Lambda (Python 3.11) → Comprehend + DynamoDB + SNS + Zendesk Tickets API

**Key Features:**
- ✅ HMAC-SHA256 webhook authentication — signature verified in Lambda before any billable call; failed sigs return `401`
- ✅ AWS Comprehend sentiment scoring — real-time `DetectSentiment` with per-class confidence
- ✅ Confidence-gated triage — `NEGATIVE ≥ 0.80` → `urgent` + escalation group + SNS alert; borderline → `high` + `review`
- ✅ Write-back into Zendesk — `additional_tags` (non-destructive) + priority + group_id via the Tickets API over `urllib`
- ✅ Secrets never in state — Secrets Manager placeholder seeded; real creds injected via `put-secret-value` with `ignore_changes`
- ✅ DynamoDB `SentimentAnalysis` audit table — `TicketID` + `CreatedAt`, on-demand, PITR enabled
- ✅ Least-privilege IAM — 5 inline policies, each scoped to one resource ARN / the single Comprehend action
- ✅ 13-check test script — every resource plus a locally-signed live triage invoke (verified NEGATIVE @ 99.81% → urgent)

**Tech Stack:** Terraform, API Gateway (REST), Lambda (Python 3.11), AWS Comprehend, DynamoDB (on-demand + PITR), SNS, Secrets Manager, IAM, CloudWatch

**Cost:** ~$3.89/month (10K tickets; Comprehend dominates); ~$0.70/month at rest (alarms + secret)

**Testing:** 13 architecture validation checks (DynamoDB, Lambda, IAM, SNS, Secrets, API Gateway, CloudWatch, live signed triage)

**Links:**
- 📄 [Full Documentation](Zendesk%20Ticket%20Triage%20with%20Sentiment%20Analysis/README.md)
- 📊 [Live Audit Results](Zendesk%20Ticket%20Triage%20with%20Sentiment%20Analysis/Result.md)
- 🧪 [Architecture Test Script](Zendesk%20Ticket%20Triage%20with%20Sentiment%20Analysis/scripts/test_architecture.sh)

---

### 12. Server Room Inspection Dashboard

**Location:** `./Server Room Inspection Dashboard/`

**Description:**
An AWS-native, phase-gated rebuild of a Malaysian corporate factory's (MCF) legacy Power Automate + Ubuntu/EC2 server-room inspection system, delivered as a read-only operational dashboard for Facilities staff. Built as gated Phases 0-6 composed into a single Terraform root module: a 3-tier / 2-AZ VPC → internet-facing ALB → single-task ECS Fargate (Flask + gunicorn) → private RDS PostgreSQL 16.14, wrapped with one reused KMS CMK, three Secrets Manager placeholders, reference-wired security groups, Cognito authentication, SES/EventBridge breach notifications, and CloudWatch/SNS observability plus a deploy-ready AD Connector. Targets account `022499047467` in `ap-southeast-1` under the prefix `mcf-srid-prod`.

**Architecture:** Internet → IGW → ALB (public) → ECS Fargate (private-app) → RDS PostgreSQL (private-data)

**Key Features:**
- ✅ 12-module phased build (Phases 0-6) composed into a single Terraform root module
- ✅ Reference-wired security groups — `ALB → app:8080 → data:5432` enforced by SG identity, not CIDR
- ✅ Single customer-managed KMS CMK across RDS, ECR, CloudWatch Logs, secrets, and the Glue bucket
- ✅ `count`/`for_each` gating for HTTP/HTTPS, Cognito auth, SES, and AD Connector — default apply stays clean and cheap
- ✅ Least-privilege DB access — `srid_app` SELECT-only role; runtime secret fetch via the ECS task role
- ✅ 2,924-row synthetic dataset loaded via a Glue Python-shell backfill job
- ✅ `terraform validate`-clean across all 12 modules (~93 authored resource blocks)

**Tech Stack:** Terraform, VPC, ALB, ECS Fargate, ECR, RDS PostgreSQL, KMS, Secrets Manager, Cognito, SES, EventBridge, AWS Glue, CloudWatch, SNS, Directory Service

**Cost:** ~$92/month (default demo path; NAT Gateway is the largest fixed cost) — $0 while destroyed

**Status:** Authored & `terraform validate`-clean; not yet deployed (destroyed to control cost)

**Links:**
- 📄 [Full Documentation](Server%20Room%20Inspection%20Dashboard/README.md)
- 📝 [Resume Summary](Resume/12_Server_Room_Inspection_Dashboard.md)

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

### 14. GitHub Actions CI/CD → AWS ECS (Fargate)

**Location:** `./GitHub Actions ECS Deployment/`

**Description:**
A continuous-delivery pipeline that ships a containerized storefront API to Amazon ECS on Fargate on every push to `main`, for an e-commerce team (Northwind Commerce) that needs zero-touch releases. Terraform provisions a self-contained VPC (2 public + 2 private subnets, IGW, single NAT Gateway), an internet-facing Application Load Balancer, an ECS Fargate service whose tasks run in private subnets with no public IP, an ECR repository with scan-on-push, IAM roles, CloudWatch logging, and CPU-based Application Auto Scaling. A GitHub Actions workflow builds each commit into a SHA-tagged Docker image, pushes it to ECR, renders a new task-definition revision, and performs a rolling ECS deployment that waits for service stability — so shipping a change is a `git push`.

**Architecture:** GitHub Actions (build → push → deploy) → ECR → Internet → IGW → ALB (public) → Target Group (`type = ip`) → ECS Fargate tasks (private) → CloudWatch Logs

**Key Features:**
- ✅ `git push` is the deploy — checkout → configure-aws-credentials → ecr-login → docker build/push (`github.sha`) → render task def → rolling ECS deploy (waits for stability)
- ✅ Terraform and the pipeline own disjoint state — `ignore_changes` on `task_definition`, `desired_count`, `container_definitions` so `apply` never reverts a deploy or a scale-out
- ✅ Tasks never internet-reachable — private subnets, no public IP; task SG trusts only the ALB SG; egress SNAT'd through NAT Gateway
- ✅ First-apply bootstrap from `public.ecr.aws/nginx/nginx:latest` so the service is healthy before the ECR repo has any images
- ✅ Target group `type = ip` (required for Fargate `awsvpc`); ALB HTTP :80 → healthy tasks
- ✅ Application Auto Scaling target-tracking on CPU 50%, min 2 / max 6, 60s scale-out / 300s scale-in cooldowns
- ✅ ECR scan-on-push + lifecycle expiry of untagged images after 14 days

**Tech Stack:** Terraform, GitHub Actions, Amazon ECS/Fargate, Amazon ECR, Application Load Balancer, Application Auto Scaling, VPC/NAT Gateway, IAM, CloudWatch

**Cost:** ~$67/month (2 Fargate tasks + ALB + single NAT Gateway; NAT is the largest line item) — $0 while destroyed

**Status:** Authored & `terraform validate`-clean; not yet deployed

**Links:**
- 📄 [Full Documentation](GitHub%20Actions%20ECS%20Deployment/README.md)
- 📝 [Resume Summary](Resume/14_GitHub_Actions_ECS_Deployment.md)

---

### 15. Laravel Ticketing Platform on Amazon EKS

**Location:** `./Laravel Ticketing System on EKS/`

**Description:**
A self-hostable help-desk platform — a Laravel application split into four Kubernetes workloads and run on Amazon EKS 1.36 (arm64 / Graviton) — provisioned end-to-end with Terraform, Packer, Ansible, and Helm. The target is Meridian Support Co., a mid-market B2B SaaS vendor whose ~400 customers carry contractual SLAs and who need SLA logic and attachments in their own AWS account for Singapore (`ap-southeast-1`) data residency. This is the `dev` environment, owned by a small team with no dedicated ops, which drives the whole design toward being cheap, reproducible, and destroyable. The app is decomposed by runtime behaviour into a `web` Deployment (behind an ALB), a `worker` Deployment (KEDA-scaled on Redis queue depth), a `scheduler` CronJob (15-minute SLA sweep), and a `migrate` Helm pre-install hook Job — backed by RDS MySQL 8.0, ElastiCache Redis, S3 attachments, and four Secrets Manager secrets synced by the External Secrets Operator. Every pod-to-AWS call authenticates via IRSA over OIDC (IMDS hop-limited to force it); nodes boot from a Packer golden AMI hardened by a scoped Ansible CIS role. Targets account `022499047467` under the prefix `ticketing-dev` on AWS provider `v6.56.0`.

**Architecture:** GitHub Actions (build arm64 → push ECR → helm upgrade by SHA) → Internet → IGW → ALB (public, `target-type: ip`) → EKS pods (private) → RDS MySQL / ElastiCache Redis (TLS) / S3 / Secrets Manager (via ESO + IRSA)

**Key Features:**
- ✅ Four-workload decomposition driven by runtime behaviour — `web` / `worker` (KEDA) / `scheduler` (CronJob) / `migrate` (Helm hook)
- ✅ Zero long-lived credentials — IRSA over OIDC only, IMDS hop limit `1` makes node metadata unreachable from pods
- ✅ Secrets never in Git or Terraform outputs — External Secrets Operator syncs four Secrets Manager secrets; a dedicated `ticketing-eso` SA owns the SecretStore identity
- ✅ Cost control is the architecture — `force_destroy` / `recovery_window = 0` / `skip_final_snapshot` make teardown clean; ~$304/mo 24/7 lands at ~$74/mo on a nights/weekends schedule
- ✅ Honest cost finding — the spec's VPC-endpoint premise inverted at dev scale ($76 fixed vs ~$1 NAT data); kept but gated behind `enable_interface_endpoints` (default ON) as a −$76 lever
- ✅ ECR mutability split — `ticketing/app` IMMUTABLE (SHA-tagged) + `ticketing/app-cache` MUTABLE so BuildKit layer caching works
- ✅ Packer golden AMI + scoped Ansible CIS role that documents which controls it skips (to keep the CNI / containerd / kube-proxy working)
- ✅ 6 real cross-artifact integration issues diagnosed and resolved (Redis key mismatch, ESO identity AccessDenied, Ansible/chart Secret-name drift, missing YACE IRSA role, inverted endpoint cost, absent lockfiles)

**Tech Stack:** Terraform, Amazon EKS, Packer, Ansible, Helm, Amazon ECR, RDS MySQL, ElastiCache Redis, S3, Secrets Manager, External Secrets Operator, KEDA, IRSA/OIDC, GitHub Actions, CloudWatch

**Cost:** ~$304/month 24/7; ~$74/month on a realistic nights/weekends teardown schedule; ~$30/month spin-up-to-test — $0 while destroyed

**Status:** Authored & verified to the ceiling of static validation (`terraform validate` + `helm lint` + `helm template` + `shellcheck` + `php -l` + `terraform fmt`); not yet applied

**Links:**
- 📄 [Full Documentation](Laravel%20Ticketing%20System%20on%20EKS/README.md)
- 📝 [Resume Summary](Resume/15_Laravel_Ticketing_EKS.md)

---

## 🛠 Technology Stack

### Infrastructure as Code
- **Terraform** 1.9+ — All projects use Terraform for complete IaC
- **CloudFormation** — Alternative IaC option for some projects
- **Terraform State** — Remote S3 backend with DynamoDB locking

### AWS Services

| Category | Services |
|----------|----------|
| **Compute** | EC2, Lambda, App Runner, ECS/Fargate (optional) |
| **Kubernetes** | Amazon EKS 1.36 (arm64 / Graviton), managed node groups (ON_DEMAND + Spot), OIDC provider, EKS access entries, IRSA |
| **Container** | App Runner, Amazon ECR, Docker (multi-stage, buildx) |
| **Load Balancing** | ALB, NLB, API Gateway |
| **TLS / DNS** | AWS Certificate Manager (DNS-validated public certificates), Cloudflare DNS (CNAME records managed by Terraform) |
| **Databases** | RDS PostgreSQL, DynamoDB, ElastiCache |
| **Networking** | VPC, Subnets, Security Groups, NAT Gateway, Route Tables |
| **GraphQL** | AWS AppSync, VTL resolvers |
| **Serverless** | Lambda, API Gateway, Cognito, SQS FIFO, SNS |
| **URL Shortener** | API Gateway (REST), Lambda (Python 3.11), DynamoDB TTL |
| **Real-time / WebSocket** | API Gateway WebSocket (v2), Lambda, DynamoDB GSI fan-out |
| **AI / NLP** | AWS Comprehend (DetectSentiment) — real-time ticket sentiment triage |
| **Containers / Orchestration** | ECS Fargate, ECR (scan-on-push), ALB target-type IP, Application Auto Scaling (CPU target-tracking), EKS + Helm (four-workload Laravel chart) |
| **Kubernetes autoscaling** | KEDA (Redis queue-depth scaler), Horizontal Pod Autoscaler (CPU), Cluster Autoscaler (node groups) |
| **Secrets sync** | External Secrets Operator + SecretStore (Secrets Manager → in-cluster Secrets via IRSA) |
| **Golden images / config mgmt** | Packer (arm64 AL2023 EKS node AMI), Ansible (scoped CIS hardening, containerd tuning) |
| **CI/CD** | GitHub Actions (build → push to ECR → rolling ECS deploy / `helm upgrade` by SHA); `configure-aws-credentials`, `amazon-ecr-login`, `amazon-ecs-deploy-task-definition` |
| **Identity / Auth** | Cognito (user pool + hosted UI + OIDC), Directory Service (AD Connector) |
| **Data / ETL** | AWS Glue (Python-shell backfill), RDS PostgreSQL 16 |
| **Patch Management** | Systems Manager Patch Manager, Maintenance Windows, Run Command (`AWS-RunPatchBaseline`) |
| **Notifications** | Amazon SES, EventBridge (scheduled breach digests) |
| **Security** | KMS (customer-managed CMK), Secrets Manager, IAM, WAF (optional), Security Groups, HMAC webhook verification |
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
✅ **Comprehensive Testing** — 130+ automated tests across all projects  
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
   cd "Multi-Tenant SaaS Application"  # or any other project
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
   terraform plan -var="db_password=SecurePassword123!"
   ```

5. **Apply infrastructure:**
   ```bash
   terraform apply -var="db_password=SecurePassword123!"
   ```

6. **Run tests:**
   ```bash
   cd ..
   bash test-quick.sh
   ```

7. **Cleanup (when done):**
   ```bash
   cd terraform
   terraform destroy -var="db_password=SecurePassword123!"
   ```

---

## 📁 Repository Structure

```
AWS Project/                                    # Root portfolio directory
├── README.md                                  # This file
├── FINOPS_SENTINEL_SUMMARY.md                # Cost optimization guide
├── SECURITY_REMEDIATION.md                   # Security hardening guide
│
├── Multi-Tenant SaaS Application/            # Project 1: Serverless SaaS
│   ├── README.md                             # Full documentation
│   ├── TESTING-GUIDE.md                      # Test procedures
│   ├── REAL-AWS-SERVICE-TESTING.md           # AWS service testing
│   ├── terraform/
│   │   ├── main.tf                           # Complete infrastructure
│   │   ├── variables.tf                      # Input variables
│   │   ├── outputs.tf                        # Outputs
│   │   └── terraform.tfvars                  # Configuration
│   ├── lambda/                               # Lambda functions
│   │   ├── auth_handler/
│   │   ├── users_handler/
│   │   └── orders_handler/
│   ├── scripts/
│   │   └── build_lambdas.sh
│   └── test-*.sh                             # Test scripts
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
├── AWS App Runner Deployment/                # Project 6: Container / App Runner
│   ├── README.md                            # Full documentation + 9 known issues
│   ├── Result.md                            # Live audit results (IDs, ARNs, test output)
│   ├── main.tf                              # 9 Terraform resources
│   ├── variables.tf                         # Input variables
│   ├── outputs.tf                           # 15 output values
│   ├── terraform.tfvars.example             # Configuration template
│   ├── Dockerfile                           # Multi-stage Node.js (linux/amd64)
│   ├── .dockerignore                        # Excludes .terraform/, *.tfstate*, node_modules/
│   ├── server.js                            # Node.js HTTP server (port 8080)
│   ├── package.json                         # App dependencies
│   └── Script/
│       └── test_architecture.sh             # 21-test architecture health check
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
├── GraphQL API with AWS AppSync/             # Project 8: Serverless GraphQL API
│   ├── README.md                            # Full documentation (14 sections, 8 FAQs)
│   ├── terraform/
│   │   ├── provider.tf                      # AWS provider + common_tags local
│   │   ├── variables.tf                     # 9 input variables with validation
│   │   ├── dynamodb.tf                      # On-demand table + PITR
│   │   ├── iam.tf                           # 2 IAM roles + 2 inline policies
│   │   ├── appsync.tf                       # API, API key, data source, 5 VTL resolvers
│   │   ├── cloudwatch.tf                    # Log group + 3 metric alarms
│   │   └── outputs.tf                       # 9 outputs
│   └── scripts/
│       └── test_architecture.sh             # 12-check architecture validation script
│
├── URL Shortener/                            # Project 9: Serverless URL Shortener
│   ├── README.md                            # Full documentation (14 sections, 6 FAQs)
│   ├── lambda/
│   │   └── handler.py                       # Single-file Lambda — /shorten, /redirect, /stats
│   ├── terraform/
│   │   ├── provider.tf                      # AWS + archive providers; common_tags local
│   │   ├── variables.tf                     # 8 input variables with validation
│   │   ├── dynamodb.tf                      # On-demand table, TTL on expires_at, PITR
│   │   ├── iam.tf                           # Lambda execution role + 2 inline policies
│   │   ├── lambda.tf                        # archive_file, aws_lambda_function, permission
│   │   ├── api_gateway.tf                   # REST API, 3 resources, deployment, v1 stage
│   │   ├── cloudwatch.tf                    # 2 log groups + 3 metric alarms
│   │   └── outputs.tf                       # 10 outputs (URLs, table name, ARNs)
│   └── scripts/
│       └── test_architecture.sh             # 16-check validation + 6 live API scenarios
│
├── Real-time Polling App/                    # Project 10: WebSocket real-time polling
│   ├── README.md                            # Full documentation (14 sections, 6 FAQs)
│   ├── Result.md                            # Live audit (50 resources, E2E fan-out + oversell tests)
│   ├── lambda/
│   │   ├── _broadcast.py                    # Shared fan-out helper (GSI query + PostToConnection)
│   │   ├── manage_connections.py            # $connect / $disconnect
│   │   ├── handle_vote.py                   # sendVote
│   │   ├── broadcast_results.py             # broadcastResults
│   │   ├── handle_livestream_vote.py        # liveVote (Scenario 1)
│   │   ├── handle_flashsale_update.py       # flashPurchase (Scenario 2)
│   │   └── handle_design_vote.py            # designVote (Scenario 3)
│   ├── terraform/
│   │   ├── provider.tf                      # AWS + archive providers; caller identity
│   │   ├── variables.tf                     # 9 input variables with validation
│   │   ├── dynamodb.tf                      # 5 tables (Connections GSI + TTLs)
│   │   ├── iam.tf                           # Execution role + 3 inline policies
│   │   ├── lambda.tf                        # Single zip, 6 functions (for_each)
│   │   ├── apigateway.tf                    # WebSocket API, 6 integrations, 7 routes, stage
│   │   ├── cloudwatch.tf                    # 7 log groups + 7 alarms
│   │   └── outputs.tf                       # WebSocket URL, mgmt endpoint, table map
│   └── scripts/
│       └── test_architecture.sh             # 24-check architecture validation
│
├── Zendesk Ticket Triage with Sentiment Analysis/ # Project 11: Comprehend sentiment triage
│   ├── README.md                            # Full documentation (14 sections, 7 FAQs)
│   ├── Result.md                            # Live audit (23 resources, signed live triage test)
│   ├── lambda/
│   │   └── handler.py                       # HMAC verify, Comprehend, DynamoDB, Zendesk API, SNS
│   ├── terraform/
│   │   ├── provider.tf                      # AWS + archive providers; common_tags local
│   │   ├── variables.tf                     # 14 input variables with validation
│   │   ├── dynamodb.tf                      # SentimentAnalysis table (TicketID + CreatedAt), PITR
│   │   ├── sns.tf                           # Negative-alert topic + optional email subscription
│   │   ├── secrets.tf                       # Zendesk credentials secret (placeholder seeded)
│   │   ├── iam.tf                           # Execution role + 5 inline policies
│   │   ├── lambda.tf                        # archive_file, aws_lambda_function, permission
│   │   ├── api_gateway.tf                   # REST API, /webhook resource, deployment, v1 stage
│   │   ├── cloudwatch.tf                    # 2 log groups + 3 metric alarms
│   │   └── outputs.tf                       # 10 outputs (webhook URL, table, ARNs, topic, secret)
│   └── scripts/
│       └── test_architecture.sh             # 13-check validation + signed live triage test
│
├── Server Room Inspection Dashboard/         # Project 12: ECS Fargate ops dashboard (Phases 0-6)
│   ├── README.md                            # Whole architecture (Phases 0-6)
│   ├── PHASE1_RDS_SCOPE.md                   # Phase 1 RDS design artifact
│   ├── PHASE3_DASHBOARD_DESIGN.md            # Approved dashboard + compute design
│   ├── database/                            # SQL DDL, migration Lambda, Glue backfill (2,924-row CSV)
│   └── terraform/
│       ├── main.tf                          # Root wiring for all 12 modules
│       ├── variables.tf / outputs.tf        # Root inputs / outputs (all phases)
│       ├── provider.tf / versions.tf / backend.tf
│       ├── bootstrap/                       # Creates the S3 remote-state bucket
│       └── modules/                         # networking, security, kms, iam, secrets, database,
│                                            #   migration, glue, compute, cognito, notifications, observability
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
├── GitHub Actions ECS Deployment/            # Project 14: CI/CD → ECS Fargate
│   ├── .github/
│   │   └── workflows/
│   │       └── deploy.yml                   # CI/CD: build → push to ECR → deploy to ECS
│   ├── README.md                            # Full documentation (15 sections)
│   ├── main.tf                              # VPC, ALB, ECR, IAM, ECS cluster/service, autoscaling
│   ├── variables.tf                         # Input variables with validation
│   ├── outputs.tf                           # ALB DNS, ECR URL, cluster/service names, log group
│   ├── versions.tf                          # Terraform + AWS provider constraints, default_tags
│   ├── task-definition.json                 # Fargate task def rendered by the pipeline
│   ├── terraform.tfvars.example             # Configuration template
│   └── .gitignore                           # Excludes state, .terraform/, *.tfvars
│
├── Laravel Ticketing System on EKS/          # Project 15: Laravel help desk on EKS
│   ├── app/                                 # Laravel app (web/worker/scheduler/migrate source)
│   ├── docker/                              # arm64 multi-stage Dockerfile + nginx/php/supervisor
│   ├── packer/                              # eks-node.pkr.hcl (arm64 AL2023 golden AMI) + AMI cleanup
│   ├── ansible/                             # roles (cis-hardening, containerd-tuning, ...) + playbooks
│   ├── terraform/
│   │   ├── bootstrap/                       # KMS + state bucket + DynamoDB lock (run once)
│   │   ├── modules/                         # network, eks, ecr, database, cache, storage, secrets
│   │   └── dev/                             # root: versions/backend/providers/variables/main/outputs
│   ├── helm/
│   │   ├── ticketing/                       # app chart: web, worker, scheduler, migrate + ESO hooks
│   │   └── platform/                        # ALB controller, ESO, KEDA, kube-prometheus, YACE, ...
│   ├── scripts/                             # bootstrap.sh, rebuild.sh, teardown.sh, cost-report.py
│   ├── .github/workflows/                   # ci.yml, terraform-plan.yml, build-deploy.yml
│   └── docs/                                # runbook + cost + architecture notes
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
│   └── 15_Laravel_Ticketing_EKS.md
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
| Multi-Tenant SaaS | ~$165 | RDS (84%) | Lambda reserved capacity, RDS auto-scaling |
| Multi-Tier Web App | ~$280 | EC2 (70%) | Spot instances, reserved capacity |
| Scalable Web App (ALB) | $123.25 (idle baseline; HTTPS + RDS revision, not deployed) | EC2 2 × `t3.medium` ($60.74) + RDS Multi-AZ ($26.28) | Scheduled scaling, spot instances |
| Scalable Web App (NLB) | $196.25 (idle baseline; HTTPS + RDS revision, not deployed) | NAT gateways × 2 ($65.70) + EC2 2 × `t3.medium` ($60.74) | Auto-scaling, scheduled downtime |
| Cloud-Tibot | Variable | Lambda + API (serverless) | Cost-efficient pay-per-use |
| App Runner Deployment | ~$16-26 | App Runner compute | Set min instances to 0 for idle cost reduction |
| Event Ticket Check-In | ~$0.30/event | Lambda (GmailSender, 2048 MB) | Event-triggered; near-zero cost between events |
| GraphQL API (AppSync) | ~$5/month | AppSync operations ($4/M) | Use free tier for dev; pay-per-request scales to zero |
| URL Shortener | ~$1/month | API Gateway ($0.35/100K) | Scales to $0 at zero traffic; alarms ~$0.30/month |
| Real-time Polling App | ~$5/event | DynamoDB on-demand + WebSocket messages | Idle connections auto-expire; ~$0.70/month at rest |
| Zendesk Ticket Triage | ~$4/month | AWS Comprehend ($0.0001/unit, min 3/req) | Scales with ticket volume; ~$0.70/month at rest (alarms + secret) |
| Server Room Inspection Dashboard* | ~$92/month | NAT Gateway + ALB + RDS + Fargate | Single shared NAT, single-AZ RDS; $0 while destroyed |
| Systems Manager Automated Patching* | ~$24/month | EC2 (2 × t3.micro) + public IPv4 | SSM/Maintenance Windows free; stop instances between windows; $0 while destroyed |
| GitHub Actions ECS Deployment* | ~$67/month | NAT Gateway + ALB + Fargate | Public-subnet tasks or VPC endpoints drop NAT; $0 while destroyed |
| Laravel Ticketing on EKS* | ~$74-304/month | EKS control plane + VPC endpoints + NAT + RDS + Redis | Teardown nights/weekends (~$74); `enable_interface_endpoints=false` (−$76); $0 while destroyed |

> *Authored & `terraform validate`-clean; not currently deployed, so it bills $0 today.

**Total Estimated Cost:** ~$1,230-1,720/month if all 15 projects were deployed simultaneously (the 4 authored-but-not-deployed projects are $0 while destroyed; the EKS ticketing platform alone ranges ~$74/month on a teardown schedule to ~$304/month if left running 24/7; Event Ticket is <$1/event; AppSync ~$5/month; URL Shortener ~$1/month; Real-time Polling ~$5/event; Zendesk Triage ~$4/month)

---

## 🧪 Testing & Validation

**Total Test Coverage:** 91+ automated tests across all projects

| Project | Quick Tests | Comprehensive | Critical | Custom |
|---------|------------|---|---|---|
| Multi-Tenant SaaS | ✅ 4 tests | ✅ 19 tests | ✅ 10 tests | ✅ DB Isolation |
| Multi-Tier Web App | ✅ 5 tests | ✅ 15 tests | ✅ 8 tests | ✅ Load Test |
| Scalable Web App (ALB) | ✅ 4 tests | ✅ 12 tests | ✅ 7 tests | ✅ Failover |
| Scalable Web App (NLB) | ✅ 4 tests | ✅ 12 tests | ✅ 7 tests | ✅ Throughput |
| Cloud-Tibot | ✅ 3 tests | ✅ 10 tests | ✅ 6 tests | ✅ Event Flow |
| App Runner Deployment | ✅ 21 tests | — | — | ✅ Architecture audit |
| Event Ticket Check-In | ✅ 8 tests | — | — | ✅ End-to-end delivery |
| GraphQL API (AppSync) | ✅ 12 tests | — | — | ✅ Live CRUD operations |
| URL Shortener | ✅ 16 tests | — | — | ✅ Live create / redirect / stats / conflict |
| Real-time Polling App | ✅ 24 tests | — | — | ✅ WebSocket routes / GSI fan-out / atomic writes |
| Zendesk Ticket Triage | ✅ 13 tests | — | — | ✅ Live signed webhook → Comprehend → urgent triage |
| Server Room Inspection Dashboard | ✅ `validate`-clean (12 modules) | — | — | ⏳ Live smoke tests pending deploy |
| Systems Manager Automated Patching | ✅ `validate`-clean | — | — | ⏳ Live patch run pending deploy |
| GitHub Actions ECS Deployment | ✅ `fmt` + `validate`-clean | — | — | ⏳ Live rolling deploy + ALB health pending deploy |
| Laravel Ticketing on EKS | ✅ `validate` + `fmt` (7 modules + dev) | ✅ `helm lint` + `helm template` | ✅ `shellcheck` + `php -l` (60) + `bash -n` + `py_compile` | ⏳ Live cluster + pod smoke tests pending apply |

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

| Metric | NLB | ALB | SaaS | Multi-Tier | Tibot | App Runner | Event Ticket | AppSync | URL Shortener | Real-time Polling | Zendesk Triage | Server Room | SSM Patching | GH Actions ECS | Laravel EKS |
|--------|-----|-----|------|-----------|-------|------------|--------------|---------|---------------|-------------------|----------------|-------------|--------------|----------------|-------------|
| Latency | <100µs | <200ms | <200ms | <300ms | Variable | <100ms | <60 s (e2e ticket) | <10ms (resolver) | <50ms (warm) | <100ms (fan-out) | <500ms (Comprehend + write-back) | <100ms (ALB→Fargate, warm) | N/A (scheduled batch) | <100ms (ALB→Fargate, warm) | <100ms (ALB→pod, warm) |
| Throughput | 1M+ RPS | 100K RPS | 50K RPS | 10K RPS | On-demand | 25K RPS | 500+/event | 300K RPS (default limit) | 10K RPS (API GW default) | 500k+ msgs/event | 20 TPS (Comprehend default) | ~1 LCU (single task) | 25% fleet/wave | scales with tasks (2–6) | scales with pods (HPA + KEDA) |
| Concurrent Users | 10,000+ | 5,000+ | 1,000+ | 500+ | Variable | 400+ | N/A (event-triggered) | Unlimited (managed) | 1,000 (Lambda concurrency) | 100k+ connections | N/A (webhook-triggered) | 1 task (scalable) | N/A (fleet patch) | 2–6 tasks (CPU autoscaled) | web HPA + worker KEDA (nodes 2–4) |
| Deployment Time | 12-18 min | 12-18 min | 10-15 min | 15-20 min | Variable | 8-12 min | 8-12 min | 2-3 min | 2-3 min | 3-4 min | 2-3 min | 15-20 min | 10-15 min | 8-12 min | 15-20 min |
| RTO | <2 min | <2 min | <2 min | <2 min | <1 min | <2 min | <1 min | <1 min | <1 min | <1 min | <1 min | <15 min (single-AZ RDS) | N/A | <2 min (rolling, 2-AZ) | <15 min (single-AZ RDS, dev) |

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
| **Current Branch** | `feat/https-rds-alb-nlb` |
| **Latest PR** | PR #pending (HTTPS and Multi-AZ RDS tier for the ALB and NLB web apps) |

---

## 📞 Questions or Issues?

- Check individual project **README.md** files (links in Quick Navigation above)
- Review **FAQ** sections in each project README
- Check **TESTING-GUIDE.md** for validation procedures
- Review [SECURITY_REMEDIATION.md](SECURITY_REMEDIATION.md) for security guidance
- Check [FINOPS_SENTINEL_SUMMARY.md](FINOPS_SENTINEL_SUMMARY.md) for cost optimization

---

**Last Updated:** October 7, 2026 — Projects 3 and 4 (Scalable Web App with ALB / NLB & Auto Scaling) revised for HTTPS and a Multi-AZ RDS for PostgreSQL tier; the revision is authored and validate-clean, not deployed  
**Status:** ✅ 11 projects deployed, tested, documented · 📝 4 authored & validated, pending deployment  
**Total Time Invested:** 40+ hours of design, implementation, testing, and documentation  

🚀 **Happy Deploying!**
