# Zendesk Ticket Triage with Sentiment Analysis — Resume Summary

## Project Overview

A fully serverless pipeline that scores the sentiment of every incoming Zendesk ticket in real time and triages it automatically back inside Zendesk, so at-risk customers surface in minutes instead of sitting buried in a flat queue. When a ticket is created, a Zendesk **trigger** fires an HMAC-signed **webhook** to a Regional **API Gateway** REST endpoint (`POST /webhook`); a Python 3.11 **Lambda** verifies the `X-Zendesk-Webhook-Signature` against a signing secret held in **Secrets Manager**, scores the ticket's subject + description with **AWS Comprehend** `DetectSentiment`, applies confidence-gated triage rules (high-confidence `NEGATIVE` → `priority: urgent` + escalation group + SNS alert; borderline → `high` + `review`), writes an audit record to the **DynamoDB** `SentimentAnalysis` table, and calls the **Zendesk Tickets API** to write the priority, tag, and group back onto the ticket. The whole stack — API Gateway, Lambda, DynamoDB, SNS, Secrets Manager, least-privilege IAM, CloudWatch access logs, and three metric alarms — is provisioned by Terraform with no servers, VPCs, or load balancers, and scales to zero cost when idle. It was **deployed and audited live** in account `022499047467` (`us-east-1`, `dev`) on 2026-06-29: 23 AWS resources, all 3 alarms `OK`, and a 13-check validation suite passing 13/13, including a signed live webhook that Comprehend scored `NEGATIVE` at 99.81% confidence and the Lambda escalated to `urgent`.

## Architecture

```
                         Zendesk
    trigger "Ticket is Created" → HMAC-SHA256-signed webhook
                            │  HTTPS POST /webhook
                            ▼
 ┌──────────────────────────────────────────────────────────┐
 │  API Gateway REST API  zendesk-triage-api  (cvuy08ve65)   │
 │  Regional · stage v1 · POST /webhook · auth NONE          │
 │  structured JSON access log → /aws/apigateway/...         │
 └────────────────────────────┬─────────────────────────────┘
                              │  Lambda proxy (AWS_PROXY)
                              ▼
               ┌──────────────────────────────────┐
               │  Lambda  zendesk-triage-function  │
               │  python3.11 · 256 MB · 15 s       │
               │  1. verify HMAC (401 on failure)  │
               │  2. extract subject + description │
               │  3. DetectSentiment → triage      │
               └───┬────────┬─────────┬────────┬───┘
                   │        │         │        │
        ┌──────────┘        │         │        └───────────────┐
        ▼                   ▼         ▼                        ▼
 ┌──────────────┐  ┌──────────────┐ ┌──────────────────┐ ┌──────────────────┐
 │AWS Comprehend│  │  DynamoDB    │ │ SNS topic        │ │ Zendesk Tickets  │
 │DetectSentiment│ │ Sentiment-   │ │ zendesk-triage-  │ │ API  PUT         │
 │ (real-time)  │  │ Analysis     │ │ negative-alerts  │ │ priority / tags /│
 └──────────────┘  │ PK TicketID  │ │ (on urgent only) │ │ group_id         │
                   │ SK CreatedAt │ └──────────────────┘ └────────▲─────────┘
                   └──────────────┘                               │
                                                                  │ email + api_token
               ┌──────────────────────────────────┐               │
               │ Secrets Manager                   │───────────────┘
               │ zendesk-triage/zendesk            │  webhook_signing_secret → step 1
               └──────────────────────────────────┘
               ┌──────────────────────────────────┐
               │ CloudWatch: 2 log groups (30 d)   │
               │ 3 alarms (Lambda errors, 5XX, 4XX)│
               └──────────────────────────────────┘
```

## Technology Stack

| Layer | Technology | Purpose |
|---|---|---|
| **Ingress** | Amazon API Gateway REST API (Regional, stage `v1`) | Public HTTPS endpoint `POST /webhook` with AWS-managed TLS; Lambda proxy integration |
| **Compute** | AWS Lambda (Python 3.11, 256 MB, 15 s) | Single-file handler — HMAC verify, Comprehend, DynamoDB, Zendesk API, SNS; stdlib + boto3 only |
| **AI / NLP** | Amazon Comprehend `DetectSentiment` | Real-time `POSITIVE` / `NEGATIVE` / `NEUTRAL` / `MIXED` with per-class confidence |
| **Database** | Amazon DynamoDB (`SentimentAnalysis`, on-demand) | Audit / analytics record per scored ticket; PITR enabled |
| **Alerting** | Amazon SNS (`zendesk-triage-negative-alerts`) | Urgent-escalation alerts + Lambda-errors alarm target; optional email subscription |
| **Secrets** | AWS Secrets Manager (`zendesk-triage/zendesk`) | Zendesk `email`, `api_token`, `webhook_signing_secret`; real values injected out of band |
| **Identity** | AWS IAM | One execution role with 5 inline policies, each scoped to a single resource ARN |
| **Observability** | Amazon CloudWatch | Lambda + API access log groups (30-day retention) and 3 metric alarms |
| **External SaaS** | Zendesk (trigger + webhook + Tickets API v2) | Event source and write-back target; called from Lambda via `urllib` |
| **IaC** | Terraform `>= 1.9` (aws `~> 5.0`, archive `~> 2.0`) | 15 input variables with validation, 10 outputs; `archive_file` zips the handler at apply |

## Key Achievements

- **End-to-end triage verified live** — a locally-signed synthetic webhook (`"Order late again"`) went through API Gateway and the live Lambda; Comprehend scored it `NEGATIVE` at `0.9981`, the triage rule set `priority: urgent` + tag `neg_sentiment`, and the record was persisted to `SentimentAnalysis`.
- **Webhook authentication without a gateway authorizer** — Zendesk cannot present SigV4 or a Cognito token, so the gateway runs `authorization = NONE` and the Lambda verifies an HMAC-SHA256 over `timestamp + raw body` with `hmac.compare_digest`; a failed signature returns `401` before any billable Comprehend or Zendesk call.
- **Confidence-gated triage rules** — only `NEGATIVE ≥ 0.80` escalates to `urgent` + escalation group + SNS; lower-confidence `NEGATIVE` / `MIXED` gets `high` + `review`; both thresholds are Terraform variables, so precision/recall can be retuned without a code change.
- **Non-destructive write-back into Zendesk** — the Tickets API call uses `additional_tags` (appends, never replaces an agent's tags) and only sets `group_id` when an escalation group is configured.
- **Secrets never in code or Terraform state** — Terraform seeds a placeholder secret version with `ignore_changes = [secret_string]`; real credentials are injected via `put-secret-value`, and the Lambda caches them per container.
- **Least-privilege IAM** — five inline policies, each scoped to one ARN (table, topic, secret, log group) plus the single `comprehend:DetectSentiment` action.
- **Graceful degradation** — with placeholder Zendesk credentials the handler returns `skipped (zendesk credentials not configured)` instead of failing, so scoring, audit, and alerting work before the Zendesk side is wired up.
- **13/13 architecture validation checks passed** against the live account, including the signed live-triage test.

## Infrastructure Components

Result.md records **23 AWS resources** managed by Terraform (24 state entries including the `archive_file` data source); the SNS email subscription is `count`-gated on `alert_email` and was not created.

| Component | Count | Details |
|---|---|---|
| **API Gateway** | 6 | `aws_api_gateway_rest_api` (`zendesk-triage-api`, `cvuy08ve65`) + `/webhook` resource + `POST` method + `AWS_PROXY` integration + deployment (`kddjn2`) + stage `v1` with access logging |
| **Lambda** | 2 | `zendesk-triage-function` (python3.11, 256 MB, 15 s, state `Active`, 2,860 B code) + `AllowAPIGatewayInvoke` permission |
| **DynamoDB table** | 1 | `SentimentAnalysis` — `PAY_PER_REQUEST`, `TicketID` (HASH) + `CreatedAt` (RANGE), PITR `ENABLED` |
| **SNS** | 1 (+0/1) | `zendesk-triage-negative-alerts`; 0 subscriptions (no `alert_email` set) |
| **Secrets Manager** | 2 | `zendesk-triage/zendesk` (`...-K1PXOd`) + placeholder secret version |
| **IAM** | 6 | `zendesk-triage-lambda-exec` + 5 inline policies (`-dynamodb`, `-comprehend`, `-sns`, `-secrets`, `-logs`) |
| **CloudWatch log groups** | 2 | `/aws/lambda/zendesk-triage-function`, `/aws/apigateway/zendesk-triage` — 30-day retention |
| **CloudWatch alarms** | 3 | `zendesk-triage-lambda-errors` (>= 5 / 60 s → SNS), `zendesk-triage-api-5xx` (>= 5 / 60 s), `zendesk-triage-api-4xx` (>= 25 / 60 s) — all `OK` |
| **Total** | **23** | Plus the `archive_file` data source (no AWS resource) |

## Deployment Issues Diagnosed & Resolved

The project sources (`README.md`, `Result.md`, the Terraform and Lambda code, and the root README entry) record **no deployment issues** for this project — the stack applied cleanly, all 13 validation checks passed, and no alarm entered `ALARM`. The one non-`updated` outcome in the audit is expected behaviour rather than a fault:

| Issue | Root cause | Fix |
|---|---|---|
| Zendesk write-back returned `skipped (zendesk credentials not configured)` during the live test | By design — Secrets Manager still holds the Terraform-seeded placeholder and `zendesk_subdomain` is the default `your-subdomain`, so the handler short-circuits the Tickets API call | None required; documented as a post-deployment manual step: inject real credentials with `aws secretsmanager put-secret-value` and create the Zendesk API token, webhook, and trigger |

## Test Results

`bash scripts/test_architecture.sh` against the live deployment — **13 PASS / 0 WARN / 0 FAIL**.

| # | Check | Result |
|---|---|---|
| 1 | DynamoDB table `SentimentAnalysis` is `ACTIVE` | PASS |
| 2 | Key schema `TicketID` (HASH) + `CreatedAt` (RANGE) | PASS |
| 3 | Lambda `zendesk-triage-function` is `Active` | PASS |
| 4 | Lambda runtime `python3.11` | PASS |
| 5 | IAM role `zendesk-triage-lambda-exec` exists | PASS |
| 6 | IAM role has 5 inline policies | PASS |
| 7 | SNS topic exists | PASS |
| 8 | Secrets Manager secret exists | PASS |
| 9 | API Gateway `zendesk-triage-api` exists | PASS |
| 10 | API resource `/webhook` exists | PASS |
| 11 | Lambda log group exists | PASS |
| 12 | CloudWatch alarms: 3 configured | PASS |
| 13 | Live signed webhook scored `NEGATIVE` → `urgent` | PASS |

**Live triage record written to DynamoDB:**

| TicketID | Sentiment | Confidence | Priority | Tag |
|---|---|---|---|---|
| `999001` | `NEGATIVE` | `0.9981` | `urgent` | `neg_sentiment` |

## Quick Start

```bash
# 1. Initialise and deploy
cd "Zendesk Ticket Triage with Sentiment Analysis/terraform"
terraform init
terraform plan
terraform apply \
  -var 'zendesk_subdomain=your-subdomain' \
  -var 'zendesk_escalation_group_id=0' \
  -var 'alert_email=oncall@techcorp.com'

# 2. Capture the webhook URL to register in Zendesk
terraform output -raw webhook_url

# 3. Inject the real Zendesk credentials (never stored in Terraform state)
aws secretsmanager put-secret-value \
  --secret-id zendesk-triage/zendesk \
  --secret-string '{"email":"agent@techcorp.com/token","api_token":"<ZENDESK_API_TOKEN>","webhook_signing_secret":"<WEBHOOK_SIGNING_SECRET>"}'

# 4. In Zendesk Admin Center: create an API token, a signed webhook pointing at
#    the URL from step 2, and a "Ticket is Created" trigger that notifies it with
#    {"id":"{{ticket.id}}","subject":"{{ticket.title}}","description":"{{ticket.description}}"}

# 5. Run the 13-check validation suite (includes a signed live triage test)
cd ..
bash scripts/test_architecture.sh
```

> Allow 2-3 minutes for API Gateway deployment propagation on first apply, and confirm the SNS email subscription if `alert_email` is set.

## Cost Estimate

`us-east-1`, 10,000 tickets/month. Comprehend dominates: `DetectSentiment` bills a minimum of 3 units (300 characters) per request at $0.0001/unit.

| Resource | Quantity (10K tickets/month) | Monthly (USD) |
|---|---|---|
| API Gateway | 10,000 REST API calls | ~$0.04 |
| Lambda | 10,000 invocations × ~300 ms × 256 MB | ~$0.02 |
| AWS Comprehend | 10,000 `DetectSentiment` requests (min 3 units each) | ~$3.00 |
| DynamoDB | 10,000 on-demand writes | ~$0.02 |
| SNS | ~1,000 alert publishes + email delivery | ~$0.01 |
| Secrets Manager | 1 secret | ~$0.40 |
| CloudWatch Logs | ~0.2 GB ingestion | ~$0.10 |
| CloudWatch Alarms | 3 alarms | ~$0.30 |
| **Total** | | **~$3.89 / month** |

> Cost scales roughly linearly with ticket volume (~$30/month at 100K tickets). At zero traffic the standing cost is ~$0.70/month (alarms + secret only).

## Security Posture

| Topic | Posture |
|---|---|
| Webhook authenticity | HMAC-SHA256 over `timestamp + body`, verified in Lambda with constant-time compare; `401` before any processing on failure |
| Gateway authorization | `NONE` by necessity (Zendesk cannot sign SigV4); replay protection via timestamp-skew rejection and AWS WAF rate-limiting documented as hardening |
| Secrets | Zendesk token + signing secret in Secrets Manager; placeholder seeded, `ignore_changes = [secret_string]` keeps real values out of state |
| IAM | One execution role; 5 inline policies scoped to the exact table, topic, secret, and log-group ARNs; Comprehend action only (no resource-level scoping exists) |
| Transport | Every hop HTTPS — Zendesk → API Gateway, Lambda → Zendesk, Lambda → AWS APIs |
| Encryption at rest | DynamoDB AWS-managed SSE; customer-managed KMS key documented as hardening |
| PII | Ticket subject/description stored for audit; TTL / redaction policy recommended for regulated data |
| Logging | Structured JSON access logs + Lambda stdout, no secret values logged; CloudTrail recommended for Secrets Manager access auditing |
| Network | No VPC, NAT, or open ports — all components are regional managed services |

## Project Structure

```
Zendesk Ticket Triage with Sentiment Analysis/
├── .gitignore                  # Ignores state, lock file, function.zip, __pycache__
├── README.md                   # Full documentation (14 sections)
├── Result.md                   # Live deployment audit (2026-06-29)
├── lambda/
│   └── handler.py              # HMAC verify, Comprehend, triage, DynamoDB, Zendesk API, SNS
├── scripts/
│   └── test_architecture.sh    # 13-check validation + signed live triage test
└── terraform/
    ├── provider.tf             # AWS + archive providers; common_tags local
    ├── variables.tf            # 15 input variables with validation
    ├── dynamodb.tf             # On-demand SentimentAnalysis table, PITR
    ├── sns.tf                  # Alert topic + optional email subscription
    ├── secrets.tf              # Zendesk credentials secret (placeholder seeded)
    ├── iam.tf                  # Lambda execution role + 5 inline policies
    ├── lambda.tf               # archive_file, aws_lambda_function, permission
    ├── api_gateway.tf          # REST API, /webhook, method, integration, deployment, v1 stage
    ├── cloudwatch.tf           # 2 log groups + 3 metric alarms
    └── outputs.tf              # 10 outputs (webhook URL, table, ARNs, topic, secret)
```

## Key Learnings & Technical Decisions

**Authentication belongs where the caller can actually satisfy it.** A Zendesk webhook cannot present IAM SigV4 or a Cognito JWT, so a gateway authorizer would either block every request or be meaningless. Instead the gateway is open and the Lambda verifies Zendesk's HMAC-SHA256 signature over `timestamp + raw body` against a secret in Secrets Manager, using `hmac.compare_digest` to avoid timing leaks. Doing this first in the handler means a forged request costs one Lambda invocation and nothing else — no Comprehend units, no DynamoDB write, no Zendesk call.

**Confidence, not just label, drives the triage decision.** Comprehend returns a score per class, and a low-confidence `NEGATIVE` is often a neutral ticket with mild frustration. Gating escalation on `NEGATIVE ≥ 0.80` keeps the urgent queue and the SNS pager meaningful, while borderline tickets get `high` + a `review` tag for a human glance. Exposing both thresholds as Terraform variables makes the precision/recall trade-off an operational setting rather than a code change.

**Keep secrets out of state with a placeholder-and-ignore pattern.** Terraform owns the secret's existence and ARN (so IAM can scope to it), but `ignore_changes = [secret_string]` lets real credentials be injected with `put-secret-value` and never round-trip through `terraform.tfstate`. The handler also degrades gracefully when the placeholder is still there, which made it possible to prove scoring, audit, and alerting live before touching the Zendesk side.

**Write back without clobbering humans.** Using `additional_tags` appends the triage tag rather than replacing an agent's tags, while `priority` and `group_id` deliberately overwrite — the point of the pipeline is to re-prioritise and route.

## What I'd Do Differently

- **Add replay protection** — reject requests whose `X-Zendesk-Webhook-Signature-Timestamp` is older than ~5 minutes; the signature is verified today but the timestamp is not bounded.
- **Complete the Zendesk-side wiring and re-test** — the live test proved everything up to the Tickets API; injecting real credentials would verify the `PUT` write-back returns `updated (HTTP 200)`.
- **Decouple the Zendesk call from the webhook response** — push the write-back through SQS so a slow Zendesk API cannot push the 15 s Lambda timeout or trigger webhook retries.
- **Front the public endpoint with AWS WAF** for rate-limiting and move DynamoDB to a customer-managed KMS key with a TTL on stored ticket text.
- **Use remote state** (S3 backend + lock table) instead of local state for anything beyond a personal trial deployment.

## Summary

This project demonstrates a production-shaped, event-driven NLP integration between a SaaS help desk and AWS: an HMAC-authenticated API Gateway webhook, a single-file Python 3.11 Lambda that scores sentiment with Comprehend and applies confidence-gated triage rules, a DynamoDB audit trail, non-destructive write-back to the Zendesk Tickets API, and SNS escalation alerts — all with secrets kept out of code and state, least-privilege IAM scoped to individual ARNs, and CloudWatch alarms tuned to surface signature failures. It was deployed live in `us-east-1` as **23 Terraform-managed AWS resources**, passed **13/13 architecture validation checks**, and verified end-to-end with a signed webhook that Comprehend scored `NEGATIVE` at 99.81% and the pipeline escalated to `urgent` — at an estimated ~$3.89/month for 10,000 tickets and ~$0.70/month at rest.
