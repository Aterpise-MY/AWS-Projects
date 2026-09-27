# Event Ticket Check-In System — Resume Summary

> Status: documented in the portfolio as a production-deployed system for Youth Revival Conference 2026. The project folder contains the Terraform IaC and README only — there is no `Result.md` audit, no test script, and no recorded test output, so the resource IDs and live test results of that deployment are not reproduced here.

## Project Overview

A serverless event registration, QR-code ticketing, and staff check-in system built for Youth Revival Conference 2026 (YRC2026), handling the full attendee lifecycle on AWS managed services. Attendees register through a Google Form; an Apps Script `onFormSubmit` trigger calls an API Gateway REST endpoint (`POST /send_email/private`, API-key protected), which invokes the `SubmitGmailSenderSQS` Lambda to validate the caller and enqueue a job on the SQS FIFO queue `python-gmail-sender.fifo`. A second Lambda, `GmailSender`, consumes the queue one message at a time (maximum concurrency 2), composites a personalised QR code onto a ticket template image with Pillow, writes the QR image to S3, sends an HTML email via the Gmail API, and records per-attendee send status in DynamoDB. A third Lambda, `GetTicketStatus`, reads that status table. At the event, staff scan QR codes against a Google Spreadsheet to mark attendance — the check-in flow runs entirely outside AWS. All AWS infrastructure is defined in 9 Terraform files (`us-east-1` by default, resource prefix `yrc2027`), and the whole footprint is estimated at roughly $0.30 per 500-attendee event.

## Architecture

```
┌──────────────────────────────────────────────────────────────────────────┐
│  REGISTRATION FLOW                                                       │
│                                                                          │
│  Google Form ──onFormSubmit──► Apps Script                               │
│                                     │  POST /send_email/private          │
│                                     │  x-api-key header                  │
│                                     ▼                                    │
│                      ┌──────────────────────────────┐                    │
│                      │  API Gateway (REST)  prod     │                   │
│                      │  API key + usage plan         │                   │
│                      └──────────────┬───────────────┘                    │
│                                     │ Lambda proxy (AWS_PROXY)           │
│                                     ▼                                    │
│                      ┌──────────────────────────────┐                    │
│                      │  Lambda  SubmitGmailSenderSQS │                   │
│                      │  128 MB · 30 s                │                   │
│                      └──────┬───────────────┬───────┘                    │
│                             │               │                            │
│                             ▼               ▼                            │
│              ┌─────────────────────┐  ┌───────────────────────────┐      │
│              │ DynamoDB            │  │ SQS FIFO                   │     │
│              │ gmail_api_access_   │  │ python-gmail-sender.fifo   │     │
│              │ tokens (TTL)        │  │ visibility 35 s · dedup on │     │
│              └─────────────────────┘  └─────────────┬─────────────┘      │
│                                                     │ batch 1 · max 2    │
│                                                     ▼                    │
│                                ┌──────────────────────────────────┐      │
│                                │  Lambda  GmailSender              │     │
│                                │  2048 MB · 4096 MB /tmp · Pillow  │     │
│                                └──┬─────────┬─────────┬─────────┬─┘      │
│                                   ▼         ▼         ▼         ▼        │
│                          S3 tokens   S3 templates  S3 qr-codes  Gmail API│
│                          (OAuth r/w) (HTML read)   (public read)(send)   │
│                                                         │                │
│                                                         ▼                │
│                                            DynamoDB yrc2027_ticket_status│
│                                            ▲                             │
│                                            │ GetItem / Query / Scan      │
│                                  Lambda GetTicketStatus (128 MB)         │
└──────────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────────┐
│  CHECK-IN FLOW (outside AWS)                                             │
│  Staff scans QR ──► Google Spreadsheet ──► Apps Script lookup            │
│                     (paid / checked-in columns) ──► mark checked-in      │
└──────────────────────────────────────────────────────────────────────────┘
```

## Technology Stack

| Layer | Technology | Purpose |
|---|---|---|
| **Ingress** | Amazon API Gateway (REST, `prod` stage) | `POST /send_email/private` with `api_key_required = true`, API key + usage plan |
| **Compute** | AWS Lambda (Python 3.11) × 3 | `SubmitGmailSenderSQS` (enqueue), `GmailSender` (render + send), `GetTicketStatus` (read) |
| **Queueing** | Amazon SQS FIFO (`python-gmail-sender.fifo`) | Decouples form bursts from sending; content-based deduplication; 35 s visibility timeout |
| **Database** | Amazon DynamoDB (on-demand) × 2 | `gmail_api_access_tokens` (TTL on `expires_at`) and `yrc2027_ticket_status` (per-attendee state) |
| **Object storage** | Amazon S3 × 3 | OAuth token (private, versioned), HTML templates (private), QR images (public read) |
| **Email** | Gmail API + Google OAuth 2.0 | HTML ticket delivery from an authorised Gmail account |
| **Image processing** | Pillow | QR code composited onto the ticket template image |
| **Front end / check-in** | Google Form, Apps Script, Google Spreadsheet | Registration trigger and staff scan-to-check-in |
| **Observability** | Amazon CloudWatch Logs | One explicit log group per function, 14-day retention |
| **IaC** | Terraform `>= 1.5.0` (AWS provider `~> 5.0`) | 9 `.tf` files, 38 resource blocks, provider `default_tags` |

## Key Achievements

- **End-to-end attendee lifecycle automated** — Google Form registration through to an HTML QR ticket in the attendee's inbox, described in the portfolio as under 60 seconds end to end.
- **Queue-decoupled send pipeline** — API Gateway only enqueues; the SQS FIFO queue absorbs registration bursts and the `GmailSender` consumer drains it at a controlled rate (`batch_size = 1`, `maximum_concurrency = 2`, `ReportBatchItemFailures`).
- **Gmail credentials survive cold starts** — the OAuth `token_gmail_v1.json` is persisted in a private, versioned S3 bucket and read/written by `GmailSender`, so a new execution environment never needs the interactive OAuth browser flow.
- **Template hot-swap** — the HTML email template is read from S3 at send time, so copy and design changes ship with an `aws s3 cp` and zero Lambda redeployment.
- **Usage-limited token auth without an auth service** — DynamoDB items carry `max_usage`, an atomically incremented `used_count`, and a TTL `expires_at`, giving scoped, self-expiring access tokens.
- **Least-privilege, one role per function** — three IAM roles, each with an inline policy scoped to the exact queue, table, or bucket ARN it needs (for example, `GetTicketStatus` is read-only on the status table).
- **Secret kept out of source** — `html_credential` is a `sensitive = true` variable with no default, supplied via `terraform.tfvars` or `TF_VAR_html_credential`.

## Infrastructure Components

Counts are Terraform resource declarations in `terraform/` (38 resource blocks, plus 4 data sources: 3 `archive_file` packages and 1 IAM policy document).

| Component | Count | Details |
|---|---|---|
| **API Gateway** | 10 | `aws_api_gateway_rest_api`, 2 resources (`/send_email`, `/send_email/private`), `POST` method, `AWS_PROXY` integration, deployment (`create_before_destroy`), `prod` stage, API key, usage plan, usage-plan key |
| **Lambda functions** | 3 | `SubmitGmailSenderSQS` (128 MB), `GmailSender` (2048 MB, 4096 MB ephemeral), `GetTicketStatus` (128 MB); all 30 s timeout |
| **Lambda wiring** | 2 | `aws_lambda_permission` (API Gateway invoke) + `aws_lambda_event_source_mapping` (SQS to `GmailSender`) |
| **CloudWatch log groups** | 3 | `/aws/lambda/<function>`, `retention_in_days = 14` |
| **SQS** | 1 | `python-gmail-sender.fifo`, FIFO, content-based deduplication, 35 s visibility timeout |
| **DynamoDB tables** | 2 | `gmail_api_access_tokens` (PK `token`, TTL `expires_at`); `yrc2027_ticket_status` (PK `email`); both `PAY_PER_REQUEST` |
| **S3 buckets** | 3 | `yrc2027-gmail-sender-tokens`, `yrc2027-email-templates`, `yrc2027-qr-codes` |
| **S3 bucket config** | 5 | 1 versioning config (tokens), 3 public-access-block configs, 1 public-read bucket policy (QR codes) |
| **IAM** | 9 | 3 roles + 3 `AWSLambdaBasicExecutionRole` attachments + 3 inline least-privilege policies |
| **Outputs** | 12 | Invoke URL, API key ID, queue URL/ARN, table names, bucket names, 3 Lambda ARNs |

## Deployment Issues Diagnosed & Resolved

The root portfolio `README.md` states that 8 deployment issues were root-caused and documented, and names six topics: OAuth cold start, Pillow memory, visibility timeout, Gmail rate limits, token race condition, and S3 public access. The project folder itself does not contain an issue log, so the table below covers only those six named topics, with root cause and fix taken from the project `README.md` and Terraform. The remaining two issues are not identified in any source file.

| Issue | Root cause | Fix |
|---|---|---|
| OAuth cold start | Lambda cannot run the interactive Gmail OAuth browser flow; a fresh execution environment has no token | Complete OAuth locally once, upload `token_gmail_v1.json` to the private, versioned `yrc2027-gmail-sender-tokens` bucket; `GmailSender` reads and rewrites it (`s3:GetObject` / `s3:PutObject`) |
| Pillow memory | Compositing the QR code onto the ticket template image needs more memory and `/tmp` than the Lambda defaults | `GmailSender` sized at `memory_size = 2048` with `ephemeral_storage { size = 4096 }` |
| Visibility timeout | A message whose visibility timeout is shorter than the consumer's runtime reappears and is retried while still being processed | `visibility_timeout_seconds = 35` on the queue, 5 s above the 30 s Lambda timeout |
| Gmail rate limits | Gmail API enforces per-user sending quotas; unbounded Lambda fan-out risks partial send failures | `scaling_config { maximum_concurrency = 2 }` and `batch_size = 1` on the SQS event source mapping |
| Token race condition | One Gmail OAuth token is shared by all concurrent `GmailSender` instances; concurrent refreshes can invalidate another instance's token mid-send | Concurrency capped at 2 (same mapping); the access-token table uses an atomic `UpdateItem` counter so `used_count` cannot be raced |
| S3 public access | The QR bucket must serve images publicly, which the bucket's Block Public Access settings would reject | QR bucket's four public-access-block flags set to `false`, and the public-read `aws_s3_bucket_policy` is ordered after it with `depends_on`; tokens and templates buckets keep all four flags `true` |

## Test Results

No test script, test output, or `Result.md` audit exists in the `Event Ticket Check In System/` folder. The root portfolio `README.md` records "8 architecture validation checks across all deployed components" and an end-to-end delivery test, but the individual checks and their results are not documented anywhere in the repository, so they are not listed here.

| Check | Source | Status |
|---|---|---|
| Architecture validation checks | Root `README.md` (count only: 8) | Not reproducible — no script or output in the project folder |
| End-to-end ticket delivery | Root `README.md` Testing & Validation table | Claimed; no recorded evidence in the project folder |
| Live resource audit (`Result.md`) | — | Not present |

## Quick Start

```bash
# 1. Enter the project
cd "Event Ticket Check In System"

# 2. One-time: complete the Gmail OAuth flow locally to produce token_gmail_v1.json
pip install google-auth google-auth-oauthlib google-api-python-client
python3 Setup/GmailSender-6f0f5b36-84fe-4c40-a7ac-36496e077aa8/google_apis.py

# 3. Initialise Terraform and supply the secret (never commit terraform.tfvars)
cd terraform
terraform init
cat > terraform.tfvars <<'EOF'
html_credential = "<your-secret-credential-string>"
EOF

# 4. Plan and deploy
terraform plan
terraform apply

# 5. Upload the OAuth token and the HTML template
aws s3 cp ../Setup/GmailSender-6f0f5b36-84fe-4c40-a7ac-36496e077aa8/token_gmail_v1.json \
    s3://$(terraform output -raw s3_gmail_tokens_bucket)/token_gmail_v1.json
aws s3 cp ../Setup/GmailSender-6f0f5b36-84fe-4c40-a7ac-36496e077aa8/template.html \
    s3://$(terraform output -raw s3_email_templates_bucket)/email_template.html

# 6. Retrieve the API key, then set SENDER_API_URL / API_KEY in Apps Script
aws apigateway get-api-key --api-key $(terraform output -raw api_key_id) \
    --include-value --query value --output text
terraform output -raw api_gateway_invoke_url
```

> Allow 1-2 minutes for the SQS event source mapping to become active. The Lambda source tree (`Setup/`) referenced by `lambda.tf` is not committed to this repository, so it must be restored before `terraform plan` can package the functions.

## Cost Estimate

From the project `README.md`: `us-east-1` rates, 500 registration emails per event plus low ongoing traffic, Lambda free tier not applied.

| Resource | Quantity / Month | Monthly Cost (USD) |
|---|---|---|
| Lambda — `SubmitGmailSenderSQS` | 600 invocations × 128 MB × 1 s | < $0.01 |
| Lambda — `GmailSender` | 500 invocations × 2048 MB × 15 s | ~$0.26 |
| Lambda — `GetTicketStatus` | 200 invocations × 128 MB × 1 s | < $0.01 |
| SQS FIFO | 600 messages | $0.00 (free tier) |
| DynamoDB — `gmail_api_access_tokens` | ~600 writes + reads | < $0.01 |
| DynamoDB — `yrc2027_ticket_status` | ~2,000 reads/writes (send + check-in) | < $0.01 |
| S3 — 3 buckets | < 50 MB storage | < $0.01 |
| API Gateway | ~600 requests | $0.00 (free tier) |
| CloudWatch Logs | ~10 MB ingestion | < $0.01 |
| **Total** | | **~$0.30 / event** |

> Nothing in the stack has a standing hourly charge; cost between events is effectively zero.

## Security Posture

| Topic | Posture |
|---|---|
| API authentication | API key in the `x-api-key` header, enforced by `api_key_required = true`; key value is not exposed as a Terraform output |
| Access tokens | DynamoDB tokens with `max_usage`, atomic `used_count`, and TTL `expires_at` |
| Gmail OAuth token | Private S3 bucket, versioning on, all four Block Public Access flags on; no explicit SSE-KMS configured |
| `html_credential` | `sensitive = true` variable, injected as a Lambda environment variable — Secrets Manager / SSM SecureString recommended |
| QR code bucket | Public read (`s3:GetObject` for `*`) by design so emailed links work; QR links never expire |
| IAM | One role per function; inline policies scoped to specific queue, table, and bucket ARNs; no wildcard resources |
| TLS | HTTPS-only `execute-api` endpoint; README records the `TLS_1_0` security policy and recommends `TLS_1_2` |
| Logging | CloudWatch log groups created explicitly per function with 14-day retention |

## Project Structure

```
Event Ticket Check In System/
├── README.md              # Full documentation (14 sections: architecture, components, FAQ)
└── terraform/
    ├── provider.tf        # Terraform >= 1.5.0, AWS ~> 5.0, default_tags
    ├── variables.tf       # 8 input variables (html_credential sensitive, no default)
    ├── sqs.tf             # SQS FIFO queue python-gmail-sender.fifo
    ├── dynamodb.tf        # Access-token table (TTL) + ticket-status table
    ├── s3.tf              # 3 buckets, versioning, public-access blocks, QR public-read policy
    ├── iam.tf             # 3 Lambda roles + least-privilege inline policies
    ├── lambda.tf          # 3 archive_file packages, 3 functions, log groups, permission, SQS mapping
    ├── api_gateway.tf     # REST API, /send_email/private POST, prod stage, API key, usage plan
    └── outputs.tf         # 12 outputs (invoke URL, API key ID, queue, tables, buckets, ARNs)
```

> The project `README.md` also documents a `Setup/` directory (Lambda source, Apps Script, bulk-send CLI, template images) that `lambda.tf` packages from `../Setup/...`. That directory is not present in the repository.

## Key Learnings & Technical Decisions

**Put a queue between the form and the mailbox.** API Gateway and `SubmitGmailSenderSQS` do nothing but validate and enqueue, so a registration burst never turns directly into Gmail API calls. The FIFO queue (with content-based deduplication) absorbs the burst, and the event source mapping becomes the single throttle knob for downstream sending.

**The concurrency cap is a correctness control, not just a quota control.** Capping `GmailSender` at `maximum_concurrency = 2` keeps the stack inside Gmail's per-user quotas, but it also limits how many instances can refresh the one shared OAuth token at once — the README calls out concurrent refreshes invalidating each other's tokens mid-send. The README's sizing: 500 emails in about 60 minutes at ~15 s per email with 2 workers.

**Visibility timeout must be derived from the consumer timeout.** At a 30 s Lambda timeout, a 35 s visibility timeout keeps each message hidden for the full processing window, avoiding duplicate sends from premature redelivery.

**Externalise anything that changes more often than code.** The OAuth token and the HTML template both live in S3 rather than in the deployment package, so token refreshes persist across cold starts and marketing changes to the email never require a Terraform apply.

**Size Lambda for the library, not the handler.** The handler is small, but Pillow image compositing drives the 2048 MB memory and 4096 MB ephemeral storage settings — the dominant line in the cost estimate.

## What I'd Do Differently

- **Commit the Lambda source (or a sanitised copy).** `lambda.tf` packages code from `../Setup/`, which is not in the repository, so the IaC cannot be planned from a clean clone.
- **Capture the deployment evidence in-repo.** Add the test script behind the "8 architecture validation checks", a `Result.md` audit, and the full 8-issue log, so the production claims are verifiable from the project folder.
- **Move `html_credential` to Secrets Manager or SSM SecureString** instead of a Lambda environment variable.
- **Serve QR codes through CloudFront with signed URLs** rather than a public-read bucket, so tickets can expire after the event.
- **Raise the API Gateway TLS policy to `TLS_1_2`** and enable SSE-KMS on the OAuth token bucket.
- **Add a dead-letter queue and CloudWatch alarms** on queue age and `GmailSender` errors so failed sends surface without reading logs.
- **Align naming.** The event is YRC2026 but Terraform defaults `project_name` to `yrc2027`; one value should drive both.

## Summary

This project delivers a low-cost, event-driven ticketing pipeline for a real conference: Google Form registration triggers an API-key-protected API Gateway endpoint, an SQS FIFO queue decouples intake from delivery, and a concurrency-capped Lambda renders a Pillow QR ticket and sends it through the Gmail API, with DynamoDB tracking tokens and per-attendee status and S3 holding the OAuth token, template, and QR images. The infrastructure is 38 Terraform resource blocks across 9 files, costing an estimated ~$0.30 per 500-attendee event. The root portfolio records it as production-deployed with 8 validation checks and 8 resolved deployment issues; the project folder contains the Terraform and README but not the test script, audit, full issue log, or Lambda source, so those claims are summarised here rather than reproduced.
