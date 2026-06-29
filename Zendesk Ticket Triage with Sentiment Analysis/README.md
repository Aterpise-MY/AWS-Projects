# Serverless Zendesk Ticket Triage with Sentiment Analysis

Deploy a fully serverless pipeline that scores the sentiment of every incoming Zendesk ticket in real time and triages it automatically back inside Zendesk. When a ticket is created, a Zendesk **trigger** fires an HMAC-signed **webhook** to an **API Gateway** endpoint; a Python 3.11 **Lambda** verifies the signature, runs **AWS Comprehend** sentiment detection, applies triage rules (negative + high confidence → `priority: urgent` + escalation group), writes an audit record to **DynamoDB**, calls the **Zendesk Tickets API** to set the priority/tag/group, and publishes an **SNS** alert on escalation. This Terraform configuration provisions all of it — API Gateway, Lambda, DynamoDB (`SentimentAnalysis`), SNS, a Secrets Manager secret for the Zendesk credentials, least-privilege IAM, CloudWatch structured access logs, and three metric alarms — with no servers, VPCs, or load balancers, and cost that scales to zero when idle.

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
                        Zendesk
   trigger "ticket is created" fires an HMAC-signed webhook
                           │
                           │  HTTPS POST /webhook
                           ▼
┌──────────────────────────────────────────────────────────┐
│            API Gateway REST API (Regional)               │
│                     POST /webhook                        │
└───────────────────────────┬──────────────────────────────┘
                            │  Lambda Proxy (AWS_PROXY)
                            ▼
              ┌──────────────────────────────┐
              │   Lambda Function            │
              │   (Python 3.11, 256 MB)      │
              │  1. verify HMAC-SHA256 sig   │
              │  2. extract ticket text      │
              │  3. triage rules             │
              └───┬─────┬──────┬──────┬───────┘
                  │     │      │      │
        ┌─────────┘     │      │      └──────────────┐
        ▼               ▼      ▼                      ▼
┌──────────────┐ ┌───────────┐ ┌──────────────┐ ┌──────────────────┐
│AWS Comprehend│ │ DynamoDB  │ │ SNS topic    │ │ Zendesk Tickets  │
│DetectSentiment│ │Sentiment- │ │(alert on     │ │ API (PUT priority│
│              │ │ Analysis  │ │ NEGATIVE)    │ │ /tag/group_id)   │
└──────────────┘ └───────────┘ └──────────────┘ └──────────────────┘
        ▲                                                 ▲
        │           ┌──────────────────────┐              │
        └───────────│ Secrets Manager      │──────────────┘
                    │ (Zendesk credentials │
                    │  + signing secret)   │
                    └──────────────────────┘
                            │
                    ┌──────────────────────┐
                    │ Amazon CloudWatch    │
                    │ Lambda + API logs,   │
                    │ 3 metric alarms      │
                    └──────────────────────┘
```

Traffic flow: Zendesk trigger → HMAC-signed webhook → API Gateway HTTPS endpoint (TLS managed by AWS) → Lambda proxy integration passes the full event → Lambda verifies the signature against the secret in Secrets Manager → Comprehend returns sentiment + confidence → Lambda applies triage rules → writes the scored record to DynamoDB → calls the Zendesk Tickets API to set `priority`/`tags`/`group_id` → publishes an SNS alert when the ticket is escalated to urgent → CloudWatch captures a structured access log per request.

---

## Networking & Routing

### API Endpoint Configuration

| Property | Value |
|---|---|
| **Endpoint type** | Regional HTTPS (AWS-managed TLS) |
| **URL format** | `https://<api-id>.execute-api.<region>.amazonaws.com/v1/webhook` |
| **Protocol** | HTTP/1.1 (REST over HTTPS) |
| **Authentication** | None at the gateway; authenticity enforced in Lambda via HMAC-SHA256 signature verification |
| **VPC required** | No — API Gateway, Lambda, Comprehend, DynamoDB, SNS and Secrets Manager are fully managed regional services |
| **Outbound to Zendesk** | Lambda reaches `https://<subdomain>.zendesk.com` over the public internet (no VPC/NAT) |

### Traffic Flow

```
┌──────────────────────────────────────────────────────────┐
│  Zendesk webhook (HTTPS, HMAC-signed)                    │
│  POST https://<id>.execute-api.us-east-1.amazonaws.com/v1/webhook │
│  Headers: X-Zendesk-Webhook-Signature,                  │
│           X-Zendesk-Webhook-Signature-Timestamp         │
└────────────────────────┬─────────────────────────────────┘
                         │
              (TLS Termination — AWS-managed)
                         │
                         ▼
          ┌──────────────────────────────┐
          │       API Gateway            │
          │  Route match: /webhook POST  │
          │  Integration: AWS_PROXY      │
          └──────────────┬───────────────┘
                         │  Invoke with full HTTP event
                         ▼
          ┌──────────────────────────────┐
          │       Lambda Function        │
          │  verify HMAC → Comprehend →  │
          │  DynamoDB → Zendesk API →SNS │
          └──────────────┬───────────────┘
                         │  HTTPS PUT /api/v2/tickets/{id}.json
                         ▼
          ┌──────────────────────────────┐
          │       Zendesk Tickets API    │
          │  priority / tags / group_id  │
          └──────────────────────────────┘
```

---

## Component Details

### 1. API Gateway REST API

| Attribute | Value |
|---|---|
| **Name** | `zendesk-triage-api` |
| **Type** | REST API — Regional |
| **Stage** | `v1` |
| **Endpoint** | `POST /webhook` |
| **Integration** | Lambda proxy (`AWS_PROXY`) |
| **Authorization** | `NONE` at the gateway — the request is authenticated downstream by HMAC verification in Lambda |
| **Access logs** | Structured JSON to CloudWatch log group `/aws/apigateway/zendesk-triage` |

> The gateway intentionally uses `authorization = NONE`. Zendesk webhooks cannot present IAM SigV4 or a Cognito token, so authenticity is established by verifying the `X-Zendesk-Webhook-Signature` HMAC inside the function. A failed signature returns `401` before any Comprehend or Zendesk call is made.

### 2. Lambda Function

| Attribute | Value |
|---|---|
| **Name** | `zendesk-triage-function` |
| **Runtime** | Python 3.11 |
| **Memory** | 256 MB (configurable via `lambda_memory_mb`) |
| **Timeout** | 15 seconds (configurable via `lambda_timeout_seconds`) |
| **Handler** | `handler.lambda_handler` |
| **Dependencies** | Standard library + boto3 only (no packaged third-party libs); Zendesk API called via `urllib` |
| **Packaging** | `archive_file` data source zips `lambda/handler.py` during `terraform apply` |

**Environment variables injected at deploy time:**

| Variable | Purpose |
|---|---|
| `TABLE_NAME` | DynamoDB audit table (`SentimentAnalysis`) |
| `SNS_TOPIC_ARN` | Topic for urgent-escalation alerts |
| `SECRET_ARN` | Secrets Manager secret holding Zendesk credentials |
| `ZENDESK_SUBDOMAIN` | Builds the Tickets API base URL |
| `ZENDESK_ESCALATION_GROUP_ID` | Group assigned to urgent negative tickets (`0` = unchanged) |
| `COMPREHEND_LANGUAGE_CODE` | Language passed to DetectSentiment (default `en`) |
| `NEGATIVE_CONFIDENCE_THRESHOLD` | Min NEGATIVE confidence to escalate (default `0.80`) |
| `POSITIVE_CONFIDENCE_THRESHOLD` | Min POSITIVE confidence to tag positive (default `0.80`) |

**Triage rules** (`_triage` in `handler.py`; Zendesk priority values are `low`/`normal`/`high`/`urgent`):

| Sentiment | Confidence | Priority | Tag | Escalation group | SNS alert |
|---|---|---|---|---|---|
| `NEGATIVE` | ≥ threshold (0.80) | `urgent` | `neg_sentiment` | Assigned | Yes |
| `NEGATIVE` / `MIXED` | < 0.80 | `high` | `review` | No | No |
| `POSITIVE` | ≥ threshold (0.80) | `normal` | `positive_sentiment` | No | No |
| `NEUTRAL` (or low-confidence positive) | any | `normal` | `neutral_sentiment` | No | No |

### 3. AWS Comprehend

| Attribute | Value |
|---|---|
| **API** | `DetectSentiment` (synchronous, real-time) |
| **Input** | Ticket `subject` + `description`, truncated to Comprehend's 5,000-byte limit |
| **Output** | One of `POSITIVE` / `NEGATIVE` / `NEUTRAL` / `MIXED` plus a per-class confidence score (0–1) |
| **Language** | Configurable via `comprehend_language_code` (default `en`) |
| **IAM** | `comprehend:DetectSentiment` only (no resource-level scoping is supported by the action) |

### 4. DynamoDB Table

| Attribute | Value |
|---|---|
| **Name** | `SentimentAnalysis` |
| **Billing mode** | PAY_PER_REQUEST (on-demand) |
| **Partition key** | `TicketID` (String) |
| **Sort key** | `CreatedAt` (String, ISO-8601 timestamp) |
| **PITR** | Enabled — 35-day continuous backup window |
| **Deletion protection** | Disabled (dev default; enable for production) |

**Schema per item:**

| Attribute | Type | Set by |
|---|---|---|
| `TicketID` | String (PK) | Webhook payload `id` |
| `CreatedAt` | String (SK) | Lambda — ISO-8601 UTC timestamp at scoring time |
| `Subject` | String | Webhook payload `subject` |
| `Description` | String | Webhook payload `description` |
| `Sentiment` | String | Comprehend result |
| `Confidence` | String | Comprehend confidence score for the winning class |
| `Priority` | String | Triage rule output |
| `Tag` | String | Triage rule output |
| `ZendeskGroupID` | String | Escalation group id (`0` when unchanged) |

### 5. SNS Topic

| Attribute | Value |
|---|---|
| **Name** | `zendesk-triage-negative-alerts` |
| **Publishers** | Lambda (on every urgent escalation) and the Lambda-errors CloudWatch alarm |
| **Subscription** | Optional email subscription created when `alert_email` is set (must be confirmed via the email AWS sends) |
| **Use** | Pushes a Slack/email alert so an agent picks up an at-risk ticket in minutes |

### 6. Secrets Manager

| Attribute | Value |
|---|---|
| **Name** | `zendesk-triage/zendesk` |
| **Keys** | `email` (`agent@corp.com/token`), `api_token`, `webhook_signing_secret` |
| **Seeding** | Terraform creates the secret with a placeholder version; real values are injected out-of-band via `put-secret-value` (state never holds the real secret — `ignore_changes = [secret_string]`) |
| **IAM** | Lambda role granted `secretsmanager:GetSecretValue` on this secret ARN only |

### 7. IAM Roles

| Role | Trust | Inline Policies |
|---|---|---|
| `zendesk-triage-lambda-exec` | `lambda.amazonaws.com` | `lambda-dynamodb` (PutItem, GetItem, Query on the table ARN), `lambda-comprehend` (DetectSentiment), `lambda-sns` (Publish to topic ARN), `lambda-secrets` (GetSecretValue on secret ARN), `lambda-logs` (CreateLogGroup, CreateLogStream, PutLogEvents on log group ARN) |

### 8. CloudWatch

| Resource | Name | Purpose |
|---|---|---|
| **Log group** | `/aws/lambda/zendesk-triage-function` | Lambda stdout/stderr; retention 30 days |
| **Log group** | `/aws/apigateway/zendesk-triage` | API access logs (JSON per request) |
| **Alarm** | `zendesk-triage-lambda-errors` | Lambda `Errors` >= 5 in 60 s — notifies the SNS topic |
| **Alarm** | `zendesk-triage-api-5xx` | API Gateway `5XXError` >= 5 in 60 s |
| **Alarm** | `zendesk-triage-api-4xx` | API Gateway `4XXError` >= 25 in 60 s — sustained 4XX may indicate failed HMAC verification or a webhook misconfiguration |

---

## Directory Structure

```
Zendesk Ticket Triage with Sentiment Analysis/
├── README.md                       # This file
├── .gitignore                      # Ignores state, lock file, and function.zip
├── lambda/
│   ├── handler.py                  # Single-file Lambda — HMAC verify, Comprehend, DynamoDB, Zendesk API, SNS
│   └── function.zip                # Auto-generated by Terraform archive_file (git-ignored)
├── terraform/
│   ├── provider.tf                 # AWS + archive providers; common_tags local
│   ├── variables.tf                # 14 input variables with validation
│   ├── dynamodb.tf                 # On-demand SentimentAnalysis table, PITR
│   ├── sns.tf                      # Negative-alert topic + optional email subscription
│   ├── secrets.tf                  # Zendesk credentials secret (placeholder seeded)
│   ├── iam.tf                      # Lambda execution role + 5 inline policies
│   ├── lambda.tf                   # archive_file, aws_lambda_function, Lambda permission
│   ├── api_gateway.tf              # REST API, /webhook resource, deployment, v1 stage
│   ├── cloudwatch.tf               # 2 log groups + 3 metric alarms
│   └── outputs.tf                  # 10 outputs (webhook URL, table, ARNs, topic, secret)
└── scripts/
    └── test_architecture.sh        # Architecture validation + signed live triage test
```

---

## Prerequisites

| Tool | Minimum Version | Install |
|---|---|---|
| **Terraform** | 1.9 | [developer.hashicorp.com/terraform/install](https://developer.hashicorp.com/terraform/install) |
| **AWS CLI** | 2.0 | [docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html) |
| **Python** | 3.11 | [python.org/downloads](https://www.python.org/downloads/) |
| **jq** | 1.6 | `brew install jq` / `apt install jq` |
| **openssl** | Any | Pre-installed on macOS/Linux (used by the test script to sign the synthetic webhook) |

**Account requirements:**
- IAM permissions to create: DynamoDB tables, Lambda functions, IAM roles and inline policies, API Gateway REST APIs, SNS topics, Secrets Manager secrets, and CloudWatch log groups and alarms.
- AWS Comprehend available in the chosen region (`us-east-1` by default).
- A **Zendesk** account — the [14-day Suite Professional free trial](https://www.zendesk.com/register/) (no credit card) is sufficient. Trial accounts allow up to **10 webhooks** and **60 webhook invocations/minute**.
- No VPC, NAT Gateway, EC2, or special service quotas required.

---

## Quick Start

```bash
# 1. Navigate to the Terraform directory
cd "Zendesk Ticket Triage with Sentiment Analysis/terraform"

# 2. Initialise providers (downloads AWS + archive plugins)
terraform init

# 3. Preview the deployment
terraform plan

# 4. Deploy all resources (optionally pass your Zendesk subdomain / escalation group / alert email)
terraform apply \
  -var 'zendesk_subdomain=your-subdomain' \
  -var 'zendesk_escalation_group_id=0' \
  -var 'alert_email=oncall@techcorp.com'

# 5. Capture the webhook URL to register in Zendesk
terraform output -raw webhook_url

# 6. Inject the real Zendesk credentials into Secrets Manager (never stored in state)
aws secretsmanager put-secret-value \
  --secret-id zendesk-triage/zendesk \
  --secret-string '{"email":"agent@techcorp.com/token","api_token":"<ZENDESK_API_TOKEN>","webhook_signing_secret":"<WEBHOOK_SIGNING_SECRET>"}'

# 7. In Zendesk Admin Center:
#    a. Apps and integrations → APIs → Zendesk API → enable token access, create an API token.
#    b. Apps and integrations → Webhooks → create a webhook pointing at the URL from step 5,
#       enable "Signing secret", and copy the secret into step 6.
#    c. Objects and rules → Triggers → create a trigger:
#         Condition: Ticket is Created
#         Action:    Notify active webhook (the one above)
#         JSON body: {"id":"{{ticket.id}}","subject":"{{ticket.title}}","description":"{{ticket.description}}"}

# 8. Run the full architecture validation suite (includes a signed live triage test)
cd ..
bash scripts/test_architecture.sh
```

Allow 2-3 minutes for API Gateway deployment propagation on first apply, and confirm the SNS email subscription if you set `alert_email`.

---

## Input Variables

| Variable | Type | Default | Description |
|---|---|---|---|
| `aws_region` | string | `us-east-1` | AWS region to deploy all resources |
| `project_name` | string | `zendesk-triage` | Prefix for all resource names |
| `environment` | string | `dev` | Deployment environment (`dev`, `staging`, `prod`) |
| `lambda_memory_mb` | number | `256` | Lambda memory in MB (128–10240) |
| `lambda_timeout_seconds` | number | `15` | Lambda max execution time in seconds (1–900) |
| `comprehend_language_code` | string | `en` | Language passed to Comprehend DetectSentiment |
| `negative_confidence_threshold` | number | `0.80` | Min NEGATIVE confidence (0–1) that escalates to `urgent` |
| `positive_confidence_threshold` | number | `0.80` | Min POSITIVE confidence (0–1) that tags `positive_sentiment` |
| `zendesk_subdomain` | string | `your-subdomain` | Zendesk subdomain used to build the Tickets API URL |
| `zendesk_escalation_group_id` | number | `0` | Group assigned to urgent tickets (`0` = leave unchanged) |
| `alert_email` | string | `""` | Email subscribed to the SNS alert topic (empty = no subscription) |
| `cloudwatch_retention_days` | number | `30` | Log retention for both log groups |
| `alarm_lambda_error_threshold` | number | `5` | Lambda errors per 60 s before alarm fires |
| `alarm_api_5xx_threshold` | number | `5` | API 5XX errors per 60 s before alarm fires |
| `alarm_api_4xx_threshold` | number | `25` | API 4XX errors per 60 s before alarm fires |

Cross-variable notes: `cloudwatch_retention_days` must be one of the values accepted by CloudWatch (1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1827, 3653); both confidence thresholds must be in the range `(0, 1]`. Terraform validation enforces all three.

---

## Outputs

| Output | Description |
|---|---|
| `webhook_url` | Full URL to register as the Zendesk webhook endpoint (POST) |
| `api_base_url` | Base invoke URL of the API Gateway v1 stage |
| `dynamodb_table_name` | Name of the DynamoDB audit table (`SentimentAnalysis`) |
| `dynamodb_table_arn` | ARN of the DynamoDB audit table |
| `lambda_function_name` | Name of the triage Lambda function |
| `lambda_function_arn` | ARN of the triage Lambda function |
| `sns_topic_arn` | ARN of the negative-sentiment SNS alert topic |
| `secret_arn` | ARN of the Secrets Manager secret holding Zendesk credentials |
| `rest_api_id` | ID of the API Gateway REST API |
| `lambda_log_group` | CloudWatch log group name for Lambda logs |

```bash
# Usage
terraform output webhook_url
terraform output -json   # all outputs as JSON
```

---

## Scaling Behaviour

This project is fully serverless — there are no instances, clusters, or capacity settings to manage. Throughput is gated by the Zendesk trigger rate, not by AWS.

```
Tickets/min
     │
 1K  ┤                                   ████   (outage / incident spike)
 500 ┤                          ████████
 100 ┤              ████████████
  10 ┤  ████████████
     └───────────────────────────────────────── time
        T+0        T+1min      T+5min    T+60min

Lambda:     Cold start ~250 ms on first request; warm pool grows automatically.
Comprehend: DetectSentiment is real-time; default 20 TPS (raisable via Support).
DynamoDB:   On-demand — no capacity planning; absorbs any write burst.
API Gateway:Managed; default 10,000 RPS per region (increasable).
Zendesk:    Trial accounts cap webhooks at 60 invocations/minute.
```

**Scaling notes:**
- Lambda concurrency scales automatically per request; default regional limit is 1,000 concurrent executions.
- The practical ceiling is whichever of **Comprehend's TPS quota** or **Zendesk's webhook rate** is lower — both are raisable. On a Zendesk trial the 60 invocations/minute cap is the binding limit.
- DynamoDB on-demand and SNS absorb spikes without pre-provisioning.
- At zero traffic the only standing cost is the three CloudWatch alarms and the Secrets Manager secret — no compute charges accrue.

---

## Tagging Strategy

| Tag Key | Value | Applied To |
|---|---|---|
| `Project` | `Zendesk Ticket Triage` | All resources |
| `Environment` | `dev` / `staging` / `prod` | All resources |
| `ManagedBy` | `Terraform` | All resources |
| `Name` | Resource-specific (e.g. `SentimentAnalysis`, `zendesk-triage-function`) | DynamoDB, Lambda, SNS, Secret |

> API Gateway stages support tags via the `aws_api_gateway_stage` resource. IAM roles inherit `local.common_tags`. The `archive_file` data source produces no AWS resource and carries no tags. The SNS email subscription is a configuration of the topic and is not separately taggable.

---

## Security Considerations

| Topic | Current Posture | Recommended Hardening |
|---|---|---|
| **Webhook authenticity** | HMAC-SHA256 signature verified in Lambda against the Secrets Manager signing secret before any processing | Add timestamp-skew rejection (e.g. discard requests older than 5 min) to prevent replay |
| **Gateway authorization** | `NONE` (authenticity handled downstream) | Optionally front with AWS WAF to rate-limit and geo-fence the public endpoint |
| **Secrets** | Zendesk token + signing secret in Secrets Manager; never in code or state (`ignore_changes`) | Enable automatic rotation and a resource policy restricting `GetSecretValue` to the Lambda role |
| **IAM scope** | Lambda role scoped to the exact table, topic, secret, and log group ARNs; Comprehend action only | Already least-privilege; review periodically with IAM Access Analyzer |
| **DynamoDB encryption** | AWS-managed keys (SSE) by default | Switch to a customer-managed KMS key for CMK control and audit |
| **Transport** | All hops are HTTPS (Zendesk→API GW, Lambda→Zendesk, Lambda→AWS APIs) | No change needed |
| **PII handling** | Ticket subject/description stored in DynamoDB for audit | Apply a TTL or redaction policy if tickets contain regulated PII; restrict table read access |
| **Logging** | Structured JSON access logs + Lambda stdout (no secret values logged) | Enable CloudTrail for management-plane events and Secrets Manager access auditing |

---

## Cost Estimate

| Resource | Quantity (10K tickets/month) | Monthly Cost (USD) |
|---|---|---|
| **API Gateway** | 10,000 REST API calls | ~$0.04 |
| **Lambda** | 10,000 invocations × ~300 ms × 256 MB | ~$0.02 |
| **AWS Comprehend** | 10,000 DetectSentiment units (min 3 units/req, $0.0001/unit) | ~$3.00 |
| **DynamoDB** | 10,000 writes (on-demand) | ~$0.02 |
| **SNS** | ~1,000 negative-alert publishes + email delivery | ~$0.01 |
| **Secrets Manager** | 1 secret | ~$0.40 |
| **CloudWatch Logs** | ~0.2 GB ingestion | ~$0.10 |
| **CloudWatch Alarms** | 3 alarms | ~$0.30 |
| **Total** | | **~$3.89/month** |

Comprehend dominates the cost: DetectSentiment bills a minimum of 3 units (300 characters) per request at $0.0001/unit, so cost scales roughly linearly with ticket volume — ~$30/month at 100K tickets. At zero traffic the standing cost is ~$0.70/month (alarms + secret only).

[AWS Pricing Calculator](https://calculator.aws/)

---

## Destroying the Stack

```bash
cd "Zendesk Ticket Triage with Sentiment Analysis/terraform"
terraform destroy
```

All resources (Lambda, API Gateway, DynamoDB table and all its items, SNS topic and subscription, Secrets Manager secret, IAM role, CloudWatch log groups and alarms) are managed by Terraform and will be deleted on destroy.

> **Data loss warning:** `terraform destroy` permanently deletes the `SentimentAnalysis` table and all stored sentiment records. Export them with `aws dynamodb scan --table-name SentimentAnalysis` first if you need the audit history.

> **Secret recovery window:** Secrets Manager schedules secret deletion with a recovery window (7–30 days) rather than deleting immediately. Re-applying within the window restores the same secret name.

Resources **not** managed by Terraform that survive destroy:
- The `lambda/function.zip` file created locally by the `archive_file` data source — delete manually if needed.
- The Zendesk-side **webhook** and **trigger** — remove these in Zendesk Admin Center so the trigger does not keep firing at a dead endpoint.

---

## Frequently Asked Questions

**Q: I'm getting 502 / 4XX errors at the webhook endpoint — what's wrong?**
A: A `502` from API Gateway means Lambda returned a malformed response or timed out — check the `/aws/lambda/zendesk-triage-function` log group. A wave of `401`/`4XX` almost always means **HMAC verification is failing**: the `webhook_signing_secret` in Secrets Manager does not match the secret Zendesk shows for the webhook, or the Zendesk trigger is sending a body that differs byte-for-byte from what was signed. Re-copy the signing secret via `put-secret-value` and ensure the trigger posts the exact JSON body shown in Quick Start. The `zendesk-triage-api-4xx` alarm is tuned to surface exactly this condition.

**Q: Everything is in a single region/AZ set of managed services — is that a concern?**
A: All services here (API Gateway, Lambda, Comprehend, DynamoDB, SNS, Secrets Manager) are **regional, multi-AZ by design** — AWS spreads them across Availability Zones for you, so there is no single-AZ concentration to mitigate. The only single-region consideration is a full regional outage; for cross-region resilience you would deploy a second stack in another region and point a second Zendesk webhook at it (Zendesk trial accounts allow up to 10 webhooks).

**Q: How do I add HTTPS / a custom domain to the webhook endpoint?**
A: The endpoint is already HTTPS (AWS-managed TLS on the `execute-api` domain). To use a branded URL such as `triage.techcorp.com`, create an API Gateway Custom Domain Name, request an ACM certificate for it, map it to this API's `v1` stage, then add a CNAME/ALIAS record in Route 53 and register that URL as the Zendesk webhook target.

**Q: How do I update the triage logic or thresholds after deployment?**
A: Edit the rules in `lambda/handler.py` (the `_triage` function) and run `terraform apply` — the `archive_file` data source re-zips the function and `source_code_hash` triggers a new deployment. Confidence thresholds and the escalation group are plain Terraform variables, so you can also retune them with `-var 'negative_confidence_threshold=0.90'` without touching code.

**Q: Should I use remote state for this project?**
A: For a personal/trial deployment local state is fine. For team or production use, configure an S3 backend with a DynamoDB lock table so state (which references the secret and topic ARNs, though not the secret value) is shared safely and never committed. The `.gitignore` already excludes `terraform.tfstate*` to prevent accidental commits.

**Q: Why escalate only on NEGATIVE ≥ 0.80 instead of every negative ticket?**
A: Comprehend returns a confidence score per class; a low-confidence `NEGATIVE` (e.g. 0.55) is often a neutral ticket with mild frustration and does not warrant paging an agent. The 0.80 floor routes only high-confidence complaints to `urgent` + the escalation group + an SNS alert, while borderline negatives get `high` + a `review` tag for an agent to glance at. Both thresholds are variables, so you can tighten or loosen them per the precision/recall trade-off your team wants.

**Q: Does the Zendesk API call overwrite an agent's existing tags?**
A: No. The Lambda sends `additional_tags`, which Zendesk **appends** to the ticket's existing tags rather than replacing them. `priority` and `group_id` are set fields and will overwrite, so the triage decision wins for those two — by design, since the whole point is to (re)prioritise and route the ticket.
