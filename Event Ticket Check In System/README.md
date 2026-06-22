# YRC2026 — Serverless Event Ticketing & Check-In System

Serverless event registration, QR code ticketing, and staff check-in system for Youth Revival Conference 2026, built entirely on AWS managed services. Attendees register via Google Form; an Apps Script trigger calls API Gateway, which enqueues a job on an SQS FIFO queue; a Lambda function generates a personalised HTML email with an embedded QR code ticket and delivers it via the Gmail API; at the event, staff scan QR codes against a Google Spreadsheet to mark attendance.

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Service Communication & Request Routing](#2-service-communication--request-routing)
3. [Component Details](#3-component-details)
4. [Directory Structure](#4-directory-structure)
5. [Prerequisites](#5-prerequisites)
6. [Quick Start](#6-quick-start)
7. [Input Variables](#7-input-variables)
8. [Outputs](#8-outputs)
9. [Scaling Behaviour](#9-scaling-behaviour)
10. [Tagging Strategy](#10-tagging-strategy)
11. [Security Considerations](#11-security-considerations)
12. [Cost Estimate](#12-cost-estimate)
13. [Destroying the Stack](#13-destroying-the-stack)
14. [Frequently Asked Questions](#14-frequently-asked-questions)

---

## 1. Architecture Overview

```
┌──────────────────────────────────────────────────────────────────────────┐
│  REGISTRATION FLOW                                                       │
│                                                                          │
│  Google Form ──onFormSubmit──► Apps Script                               │
│                                     │                                    │
│                               POST /send_email/private                   │
│                               x-api-key header                           │
│                                     ▼                                    │
│                          ┌─────────────────────┐                         │
│                          │   API Gateway (REST)  │                       │
│                          │  prod stage · TLS 1.0 │                       │
│                          └──────────┬──────────┘                         │
│                                     │ Lambda Proxy                       │
│                                     ▼                                    │
│                     ┌───────────────────────────────┐                    │
│                     │  Lambda: SubmitGmailSenderSQS  │                   │
│                     │  Validates token · Enqueues    │                   │
│                     └───────────────┬───────────────┘                    │
│                                     │                                    │
│                         ┌───────────┴────────────┐                       │
│                         │  DynamoDB              │  SQS FIFO             │
│                         │  gmail_api_access_tokens│  python-gmail-       │
│                         │  (token validation)    │  sender.fifo ◄─────── ┤
│                         └────────────────────────┘        │              │
│                                                            │ batch: 1    │
│                                                            ▼             │
│                                           ┌───────────────────────────┐  │
│                                           │  Lambda: GmailSender       │ │
│                                           │  max concurrency: 2        │ │
│                                           └─────────┬─────────────────┘  │
│                                  ┌──────────────────┼──────────────────┐ │
│                                  ▼                  ▼                  ▼ │
│                      S3: gmail-sender-tokens  Gmail API        DynamoDB  │
│                      (OAuth token r/w)        (send HTML email) ticket_  │
│                                  │                                status │
│                      S3: email-templates      S3: qr-codes               │
│                      (HTML template read)     (QR image write)           │
└──────────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────────┐
│  CHECK-IN FLOW                                                           │
│                                                                          │
│  Staff scans QR ──► Google Spreadsheet ──► Apps Script lookup            │
│                     (已付费 / 已签到 columns)   ► Mark 已签到 = true        │
└──────────────────────────────────────────────────────────────────────────┘
```

Traffic flow: Google Form submission → Apps Script → API Gateway → `SubmitGmailSenderSQS` Lambda (token validation + SQS enqueue) → SQS FIFO → `GmailSender` Lambda (QR generation + Gmail API send + DynamoDB status write). Check-in is entirely offline via Google Spreadsheet and does not touch AWS.

---

## 2. Service Communication & Request Routing

### API Endpoints

| Endpoint | Method | Auth | Integration | Purpose |
|---|---|---|---|---|
| `/send_email/private` | `POST` | API key (`x-api-key`) | Lambda Proxy | Submit email task from Apps Script or bulk sender |

### Inter-Service Permissions

| Source | Target | Actions |
|---|---|---|
| `SubmitGmailSenderSQS` | SQS `python-gmail-sender.fifo` | `SendMessage`, `GetQueueAttributes` |
| `SubmitGmailSenderSQS` | DynamoDB `gmail_api_access_tokens` | `GetItem`, `UpdateItem` |
| `GmailSender` | SQS `python-gmail-sender.fifo` | `ReceiveMessage`, `DeleteMessage`, `GetQueueAttributes` |
| `GmailSender` | S3 `yrc2027-gmail-sender-tokens` | `GetObject`, `PutObject` |
| `GmailSender` | S3 `yrc2027-email-templates` | `GetObject` |
| `GmailSender` | S3 `yrc2027-qr-codes` | `PutObject` |
| `GmailSender` | DynamoDB `yrc2027_ticket_status` | `GetItem`, `PutItem`, `UpdateItem` |
| `GetTicketStatus` | DynamoDB `yrc2027_ticket_status` | `GetItem`, `Query`, `Scan` |

### Request Flow

```
Internet ──► API Gateway (HTTPS/TLS)
                 │
                 ▼
         SubmitGmailSenderSQS
                 │
         ┌───────┴──────────┐
         ▼                  ▼
   DynamoDB              SQS FIFO
 (token check)          (enqueue)
                            │
                            ▼
                      GmailSender
                            │
               ┌────────────┼──────────┐
               ▼            ▼          ▼
             S3           Gmail       DynamoDB
          (token/tpl)     API        (status)
```

> All traffic between Lambda functions and AWS services travels over AWS private endpoints via IAM-authenticated API calls — no public internet traversal after the initial API Gateway entry point.

---

## 3. Component Details

### 3.1 SQS FIFO Queue — `python-gmail-sender.fifo`

| Attribute | Value |
|---|---|
| Type | FIFO |
| Content-based deduplication | Enabled |
| Visibility timeout | 35 s (5 s buffer over Lambda timeout) |
| Message ordering | Per message group ID |

> Visibility timeout must exceed the Lambda timeout. At 30 s Lambda timeout, 35 s ensures a message stays hidden while being processed and is not retried prematurely.

### 3.2 DynamoDB — `gmail_api_access_tokens`

| Attribute | Value |
|---|---|
| Partition key | `token` (String) |
| Billing mode | On-demand (PAY\_PER\_REQUEST) |
| TTL attribute | `expires_at` (Unix timestamp) |

| Item attribute | Type | Description |
|---|---|---|
| `token` | String | Partition key — the token value |
| `email` | String | Email address the token is scoped to |
| `max_usage` | Number | Maximum allowed invocations |
| `used_count` | Number | Atomic counter incremented on each use |
| `expires_at` | Number | TTL expiry as Unix timestamp |

### 3.3 DynamoDB — `yrc2027_ticket_status`

| Attribute | Value |
|---|---|
| Partition key | `email` (String) |
| Billing mode | On-demand (PAY\_PER\_REQUEST) |

| Item attribute | Type | Description |
|---|---|---|
| `email` | String | Attendee email — partition key |
| `name` | String | Full name used for QR payload and bulk sends |
| `status` | String | `queued` / `sent` / `failed` |
| `qr_link` | String | Public S3 URL to the attendee's QR code image |

### 3.4 Lambda — `SubmitGmailSenderSQS`

| Attribute | Value |
|---|---|
| Runtime | Python 3.11 |
| Timeout | 30 s |
| Memory | 128 MB |
| Trigger | API Gateway Lambda Proxy |

| Environment variable | Description |
|---|---|
| `PRIVATE_RESOURCE_PATH` | API path that bypasses token validation (`/send_email/private`) |
| `QUEUE_URL` | SQS FIFO queue URL |
| `TOKEN_TABLE` | DynamoDB access token table name |

### 3.5 Lambda — `GmailSender`

| Attribute | Value |
|---|---|
| Runtime | Python 3.11 |
| Timeout | 30 s |
| Memory | 2048 MB |
| Ephemeral storage | 4096 MB |
| Trigger | SQS FIFO (batch size 1, max concurrency 2) |

| Environment variable | Description |
|---|---|
| `HTML_CREDENTIAL` | Secret string enabling the HTML+QR email path |
| `TOKEN_BUCKET` | S3 bucket for OAuth token persistence |
| `TEMPLATE_BUCKET` | S3 bucket for the HTML email template |
| `QR_CODES_BUCKET` | S3 bucket for generated QR code images |
| `TICKET_TABLE` | DynamoDB ticket status table name |

> 2048 MB memory and 4096 MB ephemeral storage are required for Pillow image processing when compositing the QR code onto the ticket template image.

### 3.6 Lambda — `GetTicketStatus`

| Attribute | Value |
|---|---|
| Runtime | Python 3.11 |
| Timeout | 30 s |
| Memory | 128 MB |

| Environment variable | Description |
|---|---|
| `TICKET_TABLE` | DynamoDB ticket status table name |

### 3.7 API Gateway — `Submit Gmail Sender SQS API`

| Attribute | Value |
|---|---|
| Type | REST API |
| Stage | `prod` |
| Security Policy | TLS\_1\_0 |
| Authentication | API key (`x-api-key` header) |
| Integration | Lambda Proxy |

### 3.8 S3 Buckets

| Bucket | Access | Purpose |
|---|---|---|
| `yrc2027-gmail-sender-tokens` | Private (versioning enabled) | Gmail OAuth `token_gmail_v1.json` persisted across cold starts |
| `yrc2027-email-templates` | Private | HTML email template read at send time — update without redeploying Lambda |
| `yrc2027-qr-codes` | Public read | Generated QR code images embedded as permanent links in ticket emails |

---

## 4. Directory Structure

```
Event Ticket Check In System/
├── README.md                                        ← This file
├── terraform/
│   ├── provider.tf                                  ← AWS provider + Terraform version constraints
│   ├── variables.tf                                 ← Input variable definitions
│   ├── sqs.tf                                       ← SQS FIFO queue
│   ├── dynamodb.tf                                  ← Access token and ticket status tables
│   ├── s3.tf                                        ← Three S3 buckets (tokens, templates, QR codes)
│   ├── iam.tf                                       ← IAM roles and least-privilege policies
│   ├── lambda.tf                                    ← Three Lambda functions + SQS event source mapping
│   ├── api_gateway.tf                               ← REST API, stage, API key, usage plan
│   └── outputs.tf                                   ← API URL, bucket names, table names, Lambda ARNs
└── Setup/
    ├── lambda_function.py                           ← Lambda 1: SubmitGmailSenderSQS
    ├── upload_template.sh                           ← Quick template upload to S3
    ├── YRC2027 Google Form AppsScript.gs            ← Apps Script onFormSubmit trigger
    ├── GetTicketStatus/
    │   └── lambda_function.py                       ← Lambda 3: GetTicketStatus
    ├── bulk_send/
    │   ├── bulk_send.py                             ← Upload template + bulk send to DynamoDB recipients
    │   ├── requirements.txt                         ← boto3, requests
    │   └── recipients.example.csv                   ← Sample email,name CSV
    └── GmailSender-6f0f5b36-84fe-4c40-a7ac-36496e077aa8/
        ├── lambda_function.py                       ← Lambda 2: GmailSender (entry point)
        ├── gmail_api.py                             ← Gmail API MIME message builder + send
        ├── google_apis.py                           ← Google OAuth service factory (S3-backed)
        ├── s3.py                                    ← S3 token persistence helper
        ├── utils.py                                 ← QR embedding + HTML generation (Pillow)
        ├── content.html                             ← Standalone promotional email template
        └── images/
            ├── 1 qr code.jpg                        ← QR ticket template image
            ├── 2 unnamed-gif.gif                    ← Animated conference GIF
            ├── 3 content.jpg                        ← Event content/schedule image
            └── 4 banner.jpg                         ← Branding banner image
```

---

## 5. Prerequisites

| Tool | Minimum Version | Install |
|---|---|---|
| Terraform | 1.5.0 | https://developer.hashicorp.com/terraform/install |
| AWS CLI | 2.x | https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html |
| Python | 3.11 | https://www.python.org/downloads/ |

**Account-level requirements:**

- AWS credentials configured (`aws configure`) with permissions to create Lambda, SQS, DynamoDB, S3, API Gateway, IAM, and CloudWatch Logs resources.
- A Google Cloud project with Gmail API and Google Sheets API enabled, plus an OAuth 2.0 Client ID for the check-in web application.
- A Gmail account authorised to send via the Gmail API. The OAuth flow must be completed locally before deployment to generate `token_gmail_v1.json`.

---

## 6. Quick Start

```bash
# 1. Clone and enter the project
cd "Event Ticket Check In System"

# 2. Complete the Gmail OAuth flow locally (one-time step)
#    This generates token_gmail_v1.json — required before apply
pip install google-auth google-auth-oauthlib google-api-python-client
#    Run the OAuth helper from the GmailSender source directory:
python3 Setup/GmailSender-6f0f5b36-84fe-4c40-a7ac-36496e077aa8/google_apis.py

# 3. Initialise Terraform
cd terraform
terraform init

# 4. Create a terraform.tfvars file (never commit this file)
cat > terraform.tfvars <<'EOF'
html_credential = "<your-secret-credential-string>"
EOF

# 5. Preview the plan
terraform plan

# 6. Deploy
terraform apply

# 7. Upload the OAuth token to S3 (the bucket name is shown in Terraform outputs)
aws s3 cp ../Setup/GmailSender-6f0f5b36-84fe-4c40-a7ac-36496e077aa8/token_gmail_v1.json \
    s3://$(terraform output -raw s3_gmail_tokens_bucket)/token_gmail_v1.json

# 8. Upload the HTML email template
aws s3 cp ../Setup/GmailSender-6f0f5b36-84fe-4c40-a7ac-36496e077aa8/template.html \
    s3://$(terraform output -raw s3_email_templates_bucket)/email_template.html

# 9. Retrieve the API key value
aws apigateway get-api-key \
    --api-key $(terraform output -raw api_key_id) \
    --include-value \
    --query value --output text

# 10. Set the Apps Script constants
#     SENDER_API_URL = terraform output -raw api_gateway_invoke_url
#     API_KEY        = value from step 9

# Allow 1-2 minutes for the SQS event source mapping to become active
```

---

## 7. Input Variables

| Variable | Type | Default | Description |
|---|---|---|---|
| `aws_region` | `string` | `"us-east-1"` | AWS region for all resources |
| `project_name` | `string` | `"yrc2027"` | Prefix applied to all resource names and tags |
| `environment` | `string` | `"prod"` | Deployment environment label |
| `html_credential` | `string` | — | Secret value enabling HTML+QR email mode in `GmailSender`; **required, no default** |
| `lambda_runtime` | `string` | `"python3.11"` | Python runtime for all three Lambda functions |
| `submit_sqs_source_file` | `string` | `"../Setup/lambda_function.py"` | Relative path to `SubmitGmailSenderSQS` source |
| `gmail_sender_source_dir` | `string` | `"../Setup/GmailSender-6f0…"` | Relative path to `GmailSender` source directory |
| `get_ticket_status_source_dir` | `string` | `"../Setup/GetTicketStatus"` | Relative path to `GetTicketStatus` source directory |

> `html_credential` must be supplied via `terraform.tfvars` or an environment variable (`TF_VAR_html_credential`). Do not hardcode it in any committed file.

---

## 8. Outputs

| Output | Description |
|---|---|
| `api_gateway_invoke_url` | Full `POST` endpoint URL for Apps Script and bulk sender |
| `api_key_id` | API Gateway key ID — retrieve the key value with the AWS CLI command shown below |
| `sqs_queue_url` | SQS FIFO queue URL |
| `sqs_queue_arn` | SQS FIFO queue ARN |
| `dynamodb_access_tokens_table` | DynamoDB table name for API access token management |
| `dynamodb_ticket_status_table` | DynamoDB table name for per-recipient ticket status |
| `s3_gmail_tokens_bucket` | S3 bucket for Gmail OAuth token persistence |
| `s3_email_templates_bucket` | S3 bucket for HTML email templates |
| `s3_qr_codes_bucket` | S3 bucket for public QR code images |
| `lambda_submit_sqs_arn` | ARN of `SubmitGmailSenderSQS` |
| `lambda_gmail_sender_arn` | ARN of `GmailSender` |
| `lambda_get_ticket_status_arn` | ARN of `GetTicketStatus` |

```bash
# View all outputs
terraform output

# Retrieve the API key value (not exposed as a Terraform output for security)
aws apigateway get-api-key \
    --api-key $(terraform output -raw api_key_id) \
    --include-value \
    --query value --output text
```

---

## 9. Scaling Behaviour

Lambda and SQS scale automatically. The only explicit concurrency cap in this deployment is `maximum_concurrency = 2` on the SQS-to-`GmailSender` event source mapping.

```
Queue depth (messages)
 10 ┤
  8 ┤        ●
  6 ┤      ● │  ●
  4 ┤    ●   │    ●
  2 ┤  ●     │      ● ●
  1 ┤●       │          ●
    └────────┬────────────────────► time
             │
        GmailSender
        concurrency: 2
        (both workers
         active above
         depth 1)
```

**Concurrency cap rationale:** Gmail API enforces per-user sending quotas. Running more than 2 concurrent `GmailSender` instances risks hitting rate limits and causing partial send failures. The cap of 2 keeps throughput high enough for bulk sends (hundreds of attendees) while staying within quota.

**DynamoDB:** PAY\_PER\_REQUEST billing mode scales read/write capacity on demand with no pre-provisioning required.

**SQS FIFO:** Up to 300 transactions/second per message group ID, well above any realistic event registration volume.

**Evaluation note:** Lambda concurrency is capped at the Lambda account level (default 1000 unreserved). `GmailSender` reserves no concurrency beyond the SQS mapping cap, so other functions are not affected.

---

## 10. Tagging Strategy

| Tag Key | Value | Applied to |
|---|---|---|
| `Project` | `yrc2027` (from `var.project_name`) | All resources via provider `default_tags` |
| `Environment` | `prod` (from `var.environment`) | All resources via provider `default_tags` |
| `ManagedBy` | `Terraform` | All resources via provider `default_tags` |
| `Name` | Resource-specific slug (e.g. `GmailSender`) | Each resource individually |
| `Module` | `GmailSender` | All resources in this stack |

> CloudWatch Log Groups created by `aws_cloudwatch_log_group` inherit the provider `default_tags`. Lambda functions created via `aws_lambda_function` do not automatically propagate tags to their managed log groups — log groups are created explicitly in `lambda.tf` to ensure consistent tagging.

---

## 11. Security Considerations

| Topic | Current posture | Recommended hardening |
|---|---|---|
| **API authentication** | API key in `x-api-key` header; internal callers only (Apps Script) | Rotate the API key periodically; consider AWS Cognito or Lambda authoriser for public-facing routes |
| **Access token design** | DynamoDB tokens with `max_usage` counter and TTL expiry; atomic `UpdateItem` prevents race conditions | Set short TTLs (hours, not days) for one-time bulk send tokens |
| **Gmail OAuth token** | Stored in private S3 bucket with versioning; downloaded on Lambda cold start | Enable S3 server-side encryption (SSE-S3 or SSE-KMS); restrict bucket access to `GmailSender` IAM role only |
| **`html_credential` secret** | Passed as Lambda environment variable via `terraform.tfvars` (sensitive = true) | Migrate to AWS Secrets Manager or Systems Manager Parameter Store (SecureString); removes secret from Lambda environment |
| **QR code bucket** | Public read via bucket policy; objects are publicly accessible by URL | QR links are embedded in emails already sent — consider time-limited CloudFront signed URLs if attendee QR codes must expire |
| **IAM roles** | One role per Lambda function; least-privilege policies scoped to specific table ARNs and bucket prefixes | Scope S3 policies further by object key prefix per function |
| **Lambda ephemeral storage** | 4096 MB `/tmp` in `GmailSender` for Pillow processing | Pillow writes to `/tmp` — ensure no attendee PII is written to disk; scrub `/tmp` at function end if reusing execution environments |
| **TLS policy** | API Gateway stage uses `TLS_1_0` (includes TLS 1.0 and 1.1) | Upgrade to `TLS_1_2` to drop support for deprecated protocol versions |

---

## 12. Cost Estimate

All figures assume 500 registration emails per event (one-time bulk send) plus low ongoing traffic.

| Resource | Quantity / Month | Monthly Cost (USD) |
|---|---|---|
| Lambda — `SubmitGmailSenderSQS` | 600 invocations × 128 MB × 1 s | < $0.01 |
| Lambda — `GmailSender` | 500 invocations × 2048 MB × 15 s | ~$0.26 |
| Lambda — `GetTicketStatus` | 200 invocations × 128 MB × 1 s | < $0.01 |
| SQS FIFO | 600 messages | $0.00 (free tier: 1 M/month) |
| DynamoDB — `gmail_api_access_tokens` | ~600 writes + reads | < $0.01 |
| DynamoDB — `yrc2027_ticket_status` | ~2,000 reads/writes (send + check-in) | < $0.01 |
| S3 — 3 buckets | < 50 MB storage | < $0.01 |
| API Gateway | ~600 requests | $0.00 (free tier: 1 M/month first 12 months) |
| CloudWatch Logs | ~10 MB log ingestion | < $0.01 |
| **Total** | | **~$0.30 / event** |

> Pricing based on `us-east-1` rates as of mid-2025. Lambda free tier (1 M invocations, 400,000 GB-s/month) is not applied above. Actual cost varies with event size and OAuth token refresh frequency.

---

## 13. Destroying the Stack

```bash
# From the terraform/ directory
terraform destroy
```

**Resources NOT managed by Terraform that will survive:**

- `token_gmail_v1.json` uploaded to `yrc2027-gmail-sender-tokens` S3 bucket — delete manually before bucket destruction, or empty the bucket first.
- Any QR code images in `yrc2027-qr-codes` — the bucket policy blocks deletion of non-empty buckets. Empty the bucket before running `terraform destroy`:

```bash
aws s3 rm s3://yrc2027-qr-codes --recursive
aws s3 rm s3://yrc2027-gmail-sender-tokens --recursive
aws s3 rm s3://yrc2027-email-templates --recursive
terraform destroy
```

- The Google Cloud OAuth credentials (Client ID, Client Secret) and Google Spreadsheet are outside AWS and are not affected.
- CloudWatch Log Groups with `retention_in_days = 14` will be destroyed by Terraform. Historical logs beyond the retention window are already expired.

---

## 14. Frequently Asked Questions

**Q: The Apps Script trigger fires but attendees receive no email. API Gateway returns 502.**

A: A 502 from API Gateway on a Lambda Proxy integration means the Lambda function returned a malformed response (not the expected `{statusCode, headers, body}` shape) or timed out. Check `/aws/lambda/SubmitGmailSenderSQS` in CloudWatch Logs. Common causes: (1) missing `QUEUE_URL` environment variable — the Lambda cannot reach SQS; (2) IAM role missing `sqs:SendMessage` permission; (3) function timeout exceeded (default 30 s).

**Q: Emails reach the SQS queue but GmailSender never sends them. Messages pile up.**

A: First check `/aws/lambda/GmailSender` in CloudWatch Logs. The most common cause is a missing or expired `token_gmail_v1.json` in the `yrc2027-gmail-sender-tokens` S3 bucket. The Lambda cannot perform the interactive OAuth browser flow — you must re-run the local OAuth helper and re-upload the token. A second cause is the SQS event source mapping being disabled; verify it is active in the Lambda console under Configuration > Triggers.

**Q: How do I update the email template without redeploying Lambda?**

A: The `GmailSender` Lambda reads the template from S3 at send time. Upload a new template directly to the `yrc2027-email-templates` bucket and the next send will use it immediately:

```bash
aws s3 cp path/to/new_template.html \
    s3://$(terraform output -raw s3_email_templates_bucket)/email_template.html
```

**Q: Is the API already HTTPS? Do I need to add a certificate?**

A: Yes. API Gateway stages are HTTPS-only by default — AWS manages the TLS certificate on the `execute-api.amazonaws.com` domain. No ACM certificate is required unless you add a custom domain. The current stage uses `TLS_1_0` policy (permits TLS 1.0–1.3). To restrict to TLS 1.2+, update the `aws_api_gateway_domain_name` or set a client certificate minimum TLS version via a usage plan.

**Q: How do I store Terraform state remotely so the team can share it?**

A: Create an S3 bucket and DynamoDB lock table, then add a `backend` block to `provider.tf`:

```hcl
terraform {
  backend "s3" {
    bucket         = "my-terraform-state-bucket"
    key            = "yrc2027/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "terraform-state-lock"
    encrypt        = true
  }
}
```

Run `terraform init -migrate-state` to move existing local state into the remote backend.

**Q: Why is `GmailSender` capped at 2 concurrent instances instead of scaling freely?**

A: The Gmail API enforces a per-user sending quota (default: 10,000 emails/day for Workspace accounts, lower for personal Gmail). More importantly, the Gmail OAuth token is shared across all concurrent Lambda instances — concurrent refreshes can cause one instance to invalidate another's token mid-send. A cap of 2 balances throughput (500 emails in ~60 minutes at 15 s/email with 2 workers) against race conditions and quota consumption.
