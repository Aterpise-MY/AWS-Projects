# URL Shortener — Internal Smart Link Platform

Deploy a fully serverless URL shortener on AWS using API Gateway, Lambda, and DynamoDB. This Terraform configuration provisions a REST API with three endpoints (`POST /shorten`, `GET /redirect`, `GET /stats`), a DynamoDB table with automatic TTL-based link expiry, a Python 3.11 Lambda function that handles creation, redirection, click tracking, and conflict detection, least-privilege IAM roles, CloudWatch structured access logs, and three metric alarms — all without managing servers, VPCs, or load balancers. Designed as an internal enterprise smart link platform (`go.techcorp.internal`).

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
Employee Browser / Slack Bot / IT Ops Script
                │
                │  HTTPS
                ▼
┌───────────────────────────────────────────────┐
│         API Gateway REST API (Regional)       │
│                                               │
│   POST /shorten   GET /redirect   GET /stats  │
└───────────────────────┬───────────────────────┘
                        │  Lambda Proxy (AWS_PROXY)
                        ▼
          ┌─────────────────────────────┐
          │   Lambda Function           │
          │   (Python 3.11, 256 MB)     │
          │                             │
          │  ┌─────────┐ ┌──────────┐   │
          │  │ /shorten│ │/redirect │   │
          │  │ create  │ │ lookup + │   │
          │  │ + store │ │ 301 redir│   │
          │  └────┬────┘ └────┬─────┘   │
          │       │    /stats │         │
          │       │  ┌────────┴──────┐  │
          │       │  │click tracking │  │
          │       │  └───────────────┘  │
          └───────┼─────────────────────┘
                  │  GetItem / PutItem / UpdateItem
                  ▼
     ┌────────────────────────────────────────┐
     │       DynamoDB — url-shortener-links   │
     │                                        │
     │  short_code  (PK, String)              │
     │  long_url    (String)                  │
     │  label       (String)                  │
     │  created_by  (String)                  │
     │  created_at  (Number, Unix epoch)      │
     │  expires_at  (Number, TTL attribute)   │
     │  click_count (Number)                  │
     │  last_accessed (Number, Unix epoch)    │
     └────────────────────────────────────────┘
                  │
     ┌────────────────────────────────────────┐
     │       Amazon CloudWatch                │
     │  Lambda log group + API access logs    │
     │  3 metric alarms                       │
     └────────────────────────────────────────┘
```

Traffic flow: Client → API Gateway HTTPS endpoint (TLS managed by AWS) → Lambda proxy integration passes full event → Lambda reads/writes DynamoDB → Lambda returns response (201 Created, 301 Redirect, 200 OK, 409 Conflict, 410 Gone, 404 Not Found) → API Gateway forwards response to client → CloudWatch captures structured access log per request.

---

## Networking & Routing

### API Endpoint Configuration

| Property | Value |
|---|---|
| **Endpoint type** | Regional HTTPS (AWS-managed TLS) |
| **URL format** | `https://<api-id>.execute-api.<region>.amazonaws.com/v1` |
| **Protocol** | HTTP/1.1 (REST over HTTPS) |
| **Authentication** | None (internal network; add API key or Cognito for production hardening) |
| **VPC required** | No — API Gateway and Lambda are fully managed regional services |
| **DNS** | AWS-managed; map a custom domain (e.g. `go.techcorp.internal`) via Route 53 + ACM |

### Traffic Flow

```
┌──────────────────────────────────────────────────────────┐
│  Client Request (HTTPS)                                  │
│  POST https://<id>.execute-api.us-east-1.amazonaws.com/v1/shorten │
└────────────────────────┬─────────────────────────────────┘
                         │
              (TLS Termination — AWS-managed)
                         │
                         ▼
          ┌──────────────────────────────┐
          │       API Gateway            │
          │  Route match: /shorten POST  │
          │  Integration: AWS_PROXY      │
          └──────────────┬───────────────┘
                         │  Invoke with full HTTP event
                         ▼
          ┌──────────────────────────────┐
          │       Lambda Function        │
          │  httpMethod + resource       │
          │  dispatch → handler          │
          └──────────────┬───────────────┘
                         │  PutItem / GetItem / UpdateItem
                         ▼
          ┌──────────────────────────────┐
          │       DynamoDB               │
          │  short_code (PK)             │
          │  TTL on expires_at           │
          └──────────────────────────────┘
```

---

## Component Details

### 1. API Gateway REST API

| Attribute | Value |
|---|---|
| **Name** | `url-shortener-api` |
| **Type** | REST API — Regional |
| **Stage** | `v1` |
| **Endpoints** | `POST /shorten`, `GET /redirect`, `GET /stats` |
| **Integration** | Lambda proxy (`AWS_PROXY`) for all three resources |
| **Access logs** | Structured JSON to CloudWatch log group `/aws/apigateway/url-shortener` |

> All three resources use Lambda proxy integration — the full HTTP request (method, path, query string, headers, body) is forwarded to Lambda as a JSON event. Lambda controls the exact HTTP status code returned.

### 2. Lambda Function

| Attribute | Value |
|---|---|
| **Name** | `url-shortener-function` |
| **Runtime** | Python 3.11 |
| **Memory** | 256 MB (configurable via `lambda_memory_mb`) |
| **Timeout** | 10 seconds (configurable via `lambda_timeout_seconds`) |
| **Handler** | `handler.lambda_handler` |
| **Environment** | `TABLE_NAME` — DynamoDB table name injected at deploy time |
| **Packaging** | `archive_file` data source zips `lambda/handler.py` during `terraform apply` |

**Request routing inside the handler:**

| `httpMethod` + `resource` | Handler | Response codes |
|---|---|---|
| `POST /shorten` | `_handle_shorten` | 201 Created, 400 Bad Request, 409 Conflict, 500 |
| `GET /redirect` | `_handle_redirect` | 301 Moved Permanently, 400, 404, 410 Gone |
| `GET /stats` | `_handle_stats` | 200 OK, 400, 404 |

### 3. DynamoDB Table

| Attribute | Value |
|---|---|
| **Name** | `url-shortener-links` |
| **Billing mode** | PAY_PER_REQUEST (on-demand) |
| **Primary key** | `short_code` (String, PK) |
| **TTL attribute** | `expires_at` (Unix epoch seconds) |
| **PITR** | Enabled — 35-day continuous backup window |
| **Deletion protection** | Disabled (dev default; enable for production) |

**Schema per item:**

| Attribute | Type | Set by |
|---|---|---|
| `short_code` | String | POST /shorten — custom or auto-generated (6 lowercase alphanumeric) |
| `long_url` | String | POST /shorten body |
| `label` | String | POST /shorten body (optional) |
| `created_by` | String | POST /shorten body (default: `unknown`) |
| `created_at` | Number | Lambda — Unix epoch seconds at creation time |
| `expires_at` | Number | Lambda — `created_at + expires_in_days * 86400`; DynamoDB TTL deletes item after this timestamp |
| `click_count` | Number | Lambda — atomic `ADD 1` on every redirect |
| `last_accessed` | Number | Lambda — Unix epoch seconds of most recent redirect |

### 4. IAM Roles

| Role | Trust | Inline Policies |
|---|---|---|
| `url-shortener-lambda-exec` | `lambda.amazonaws.com` | `lambda-dynamodb` (GetItem, PutItem, UpdateItem, DeleteItem, Query, Scan on table ARN) + `lambda-logs` (CreateLogGroup, CreateLogStream, PutLogEvents on log group ARN) |

### 5. CloudWatch

| Resource | Name | Purpose |
|---|---|---|
| **Log group** | `/aws/lambda/url-shortener-function` | Lambda stdout/stderr; retention 30 days |
| **Log group** | `/aws/apigateway/url-shortener` | API access logs (JSON per request) |
| **Alarm** | `url-shortener-lambda-errors` | Lambda `Errors` >= 5 in 60 s |
| **Alarm** | `url-shortener-api-5xx` | API Gateway `5XXError` >= 10 in 60 s |
| **Alarm** | `url-shortener-api-4xx` | API Gateway `4XXError` >= 50 in 60 s — may indicate abuse or automated scanning |

---

## Directory Structure

```
URL Shortener/
├── README.md                       # This file
├── lambda/
│   ├── handler.py                  # Single-file Lambda — /shorten, /redirect, /stats
│   └── function.zip                # Auto-generated by Terraform archive_file (git-ignored)
├── terraform/
│   ├── provider.tf                 # AWS + archive providers; common_tags local
│   ├── variables.tf                # 8 input variables with validation
│   ├── dynamodb.tf                 # On-demand table, TTL on expires_at, PITR
│   ├── iam.tf                      # Lambda execution role + 2 inline policies
│   ├── lambda.tf                   # archive_file, aws_lambda_function, Lambda permission
│   ├── api_gateway.tf              # REST API, 3 resources, deployment, v1 stage
│   ├── cloudwatch.tf               # 2 log groups + 3 metric alarms
│   └── outputs.tf                  # 10 outputs (URLs, table name, ARNs)
└── scripts/
    └── test_architecture.sh        # 16-check architecture validation + live API tests
```

---

## Prerequisites

| Tool | Minimum Version | Install |
|---|---|---|
| **Terraform** | 1.9 | [developer.hashicorp.com/terraform/install](https://developer.hashicorp.com/terraform/install) |
| **AWS CLI** | 2.0 | [docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html) |
| **Python** | 3.11 | [python.org/downloads](https://www.python.org/downloads/) |
| **curl** | Any | Pre-installed on macOS/Linux |
| **jq** | 1.6 | `brew install jq` / `apt install jq` |

**Account requirements:**
- IAM permissions to create: DynamoDB tables, Lambda functions, IAM roles and inline policies, API Gateway REST APIs, and CloudWatch log groups and alarms.
- No VPC, NAT Gateway, EC2, or special service quotas required.

---

## Quick Start

```bash
# 1. Navigate to the Terraform directory
cd "URL Shortener/terraform"

# 2. Initialise providers (downloads AWS + archive plugins)
terraform init

# 3. Preview the deployment
terraform plan

# 4. Deploy all resources
terraform apply

# 5. Capture the API base URL
BASE_URL=$(terraform output -raw api_base_url)

# 6. Create a short link
curl -X POST "$BASE_URL/shorten" \
  -H "Content-Type: application/json" \
  -d '{"long_url":"https://confluence.techcorp.internal/pages/938471","custom_code":"q3-okr","expires_in_days":90,"created_by":"strategy-team","label":"Q3 OKR Homepage"}'

# 7. Follow the short link (should redirect 301)
curl -I "$BASE_URL/redirect?short_code=q3-okr"

# 8. Retrieve click statistics
curl "$BASE_URL/stats?short_code=q3-okr"

# 9. Enable DynamoDB TTL (one-time console step)
#    DynamoDB Console → url-shortener-links → Additional settings → TTL → expires_at

# 10. Run the full architecture validation suite
cd ..
bash scripts/test_architecture.sh
```

Allow 2-3 minutes for API Gateway deployment propagation on first apply.

---

## Input Variables

| Variable | Type | Default | Description |
|---|---|---|---|
| `aws_region` | string | `us-east-1` | AWS region to deploy all resources |
| `project_name` | string | `url-shortener` | Prefix for all resource names |
| `environment` | string | `dev` | Deployment environment (`dev`, `staging`, `prod`) |
| `lambda_memory_mb` | number | `256` | Lambda memory in MB (128–10240) |
| `lambda_timeout_seconds` | number | `10` | Lambda max execution time in seconds (1–900) |
| `cloudwatch_retention_days` | number | `30` | Log retention for both log groups |
| `alarm_lambda_error_threshold` | number | `5` | Lambda errors per 60 s before alarm fires |
| `alarm_api_5xx_threshold` | number | `10` | API 5XX errors per 60 s before alarm fires |
| `alarm_api_4xx_threshold` | number | `50` | API 4XX errors per 60 s before alarm fires |

Cross-variable note: `cloudwatch_retention_days` must be one of the values accepted by CloudWatch (1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1827, 3653). Terraform validation enforces this.

---

## Outputs

| Output | Description |
|---|---|
| `api_base_url` | Base invoke URL of the API Gateway v1 stage |
| `shorten_endpoint` | Full URL for `POST /shorten` |
| `redirect_endpoint` | Full URL for `GET /redirect?short_code=<code>` |
| `stats_endpoint` | Full URL for `GET /stats?short_code=<code>` |
| `dynamodb_table_name` | Name of the DynamoDB links table |
| `dynamodb_table_arn` | ARN of the DynamoDB links table |
| `lambda_function_name` | Name of the Lambda function |
| `lambda_function_arn` | ARN of the Lambda function |
| `rest_api_id` | ID of the API Gateway REST API |
| `lambda_log_group` | CloudWatch log group name for Lambda logs |

```bash
# Usage
terraform output api_base_url
terraform output -json   # all outputs as JSON
```

---

## Scaling Behaviour

This project is fully serverless — there are no instances, clusters, or capacity settings to manage.

```
Requests/min
     │
 10K ┤                                   ████
  5K ┤                          ████████
  1K ┤              ████████████
 100 ┤  ████████████
     └───────────────────────────────────────── time
        T+0        T+1min      T+5min    T+60min

Lambda: Cold start on first request (~200 ms); warm pool grows automatically.
DynamoDB: On-demand — no capacity planning; handles burst to any throughput.
API Gateway: Managed service; default limit 10,000 RPS per region (increasable).
```

**Scaling notes:**
- Lambda concurrency scales automatically per request; default regional limit is 1,000 concurrent executions.
- DynamoDB on-demand absorbs traffic spikes without pre-provisioning.
- The only hard limit at rest is API Gateway's 10,000 RPS regional throttle; raise via AWS Support if needed.
- At zero traffic the cost is exactly $0 — no compute or capacity charges accrue.

---

## Tagging Strategy

| Tag Key | Value | Applied To |
|---|---|---|
| `Project` | `URL Shortener` | All resources |
| `Environment` | `dev` / `staging` / `prod` | All resources |
| `ManagedBy` | `Terraform` | All resources |
| `Name` | Resource-specific (e.g. `url-shortener-links`) | DynamoDB, Lambda |

> API Gateway stages support tags via the `aws_api_gateway_stage` resource. IAM roles inherit `local.common_tags`. The `archive_file` data source produces no AWS resource and carries no tags.

---

## Security Considerations

| Topic | Current Posture | Recommended Hardening |
|---|---|---|
| **Authentication** | None — API is open | Add an API Gateway API key (`x-api-key`) or integrate with your IdP via Cognito authoriser |
| **Network access** | Public HTTPS endpoint | Deploy with a VPC endpoint or private API type if the service must remain on-premises only |
| **IAM scope** | Lambda role scoped to exact table ARN and log group ARN | No further scoping needed; follows least-privilege principle |
| **DynamoDB encryption** | AWS-managed keys (SSE-S3) by default | Switch to `server_side_encryption { enabled = true; kms_key_arn = "<your-key>" }` for CMK control |
| **Link validation** | No URL scheme validation | Add `long_url` prefix check (`https://` only) inside `_handle_shorten` to prevent `javascript:` or `data:` URI injection |
| **Custom code injection** | Alphanumeric and `-` only (lowercased) | Enforce stricter regex on `custom_code` at the Lambda level |
| **Rate limiting** | API Gateway regional throttle (10K RPS) | Add a usage plan + throttling per client key to prevent link-creation abuse |
| **Secrets** | No secrets; table name injected as plain env var | Acceptable for non-sensitive config; use Secrets Manager if you add credentials (e.g. SMTP, Slack webhook) |
| **Logging** | Structured JSON access logs + Lambda stdout | Enable CloudTrail for API Gateway management-plane events in production |

---

## Cost Estimate

| Resource | Quantity (100K req/month) | Monthly Cost (USD) |
|---|---|---|
| **API Gateway** | 100,000 REST API calls | ~$0.35 |
| **Lambda** | 100,000 invocations × avg 50 ms × 256 MB | ~$0.03 |
| **DynamoDB** | 100,000 writes + 200,000 reads (on-demand) | ~$0.18 |
| **CloudWatch Logs** | ~0.5 GB ingestion | ~$0.25 |
| **CloudWatch Alarms** | 3 alarms | ~$0.30 |
| **Total** | | **~$1.11/month** |

At 1M requests/month the estimate scales to ~$9/month. At zero traffic the cost is $0.30/month (alarms only).

[AWS Pricing Calculator](https://calculator.aws/)

---

## Destroying the Stack

```bash
cd "URL Shortener/terraform"
terraform destroy
```

All resources (Lambda, API Gateway, DynamoDB table and all its items, IAM role, CloudWatch log groups and alarms) are managed by Terraform and will be deleted on destroy.

> **Data loss warning:** `terraform destroy` permanently deletes the DynamoDB table and all stored short links. Export links with `aws dynamodb scan --table-name url-shortener-links` before destroying if you need to preserve the data.

Resources **not** managed by Terraform that survive destroy:
- The `lambda/function.zip` file created locally by the `archive_file` data source — delete manually if needed.
- Any CloudWatch log group data that was already written — log groups are deleted by Terraform but ingested log events are removed with them.

---

## Frequently Asked Questions

**Q: Why does a redirect return 301 instead of 302?**  
A: `301 Moved Permanently` lets browsers and Slack unfurlers cache the destination, reducing repeat requests to the API and lowering cost. Use `302 Found` (temporary) if your links change destination frequently or if you need accurate click tracking on every visit (some clients skip the redirect request after a 301 is cached).

**Q: The link I just created is still accessible after `expires_at` has passed — why?**  
A: DynamoDB TTL deletes items asynchronously within 48 hours of the expiry timestamp. During that window, the Lambda function checks `expires_at` in application code and returns `410 Gone` immediately, so the client experience is correct even before DynamoDB physically removes the item.

**Q: How do I map `go.techcorp.internal` to this API?**  
A: In API Gateway, create a Custom Domain Name pointing to this API's v1 stage, generate an ACM certificate for `go.techcorp.internal`, then add a CNAME or ALIAS record in Route 53 (or your internal DNS) pointing to the CloudFront distribution URL that API Gateway provisions. For a fully internal domain (not routable from the internet), use a private hosted zone and a VPC endpoint for API Gateway.

**Q: POST /shorten returned 409 — what should I do?**  
A: The requested `custom_code` is already registered to another link. Choose a different code (e.g. append a year: `q3-okr-2026`) or omit `custom_code` entirely and let the API generate a random 6-character code.

**Q: How do I bulk-create short links from a CSV?**  
A: Pipe each row through a shell loop:
```bash
while IFS=',' read -r long_url code label; do
  curl -sX POST "$BASE_URL/shorten" \
    -H "Content-Type: application/json" \
    -d "{\"long_url\":\"$long_url\",\"custom_code\":\"$code\",\"label\":\"$label\"}"
  echo
done < links.csv
```

**Q: Can I see which links are expiring soon?**  
A: Query DynamoDB with a filter on `expires_at`:
```bash
NOW=$(date +%s)
SEVEN_DAYS=$((NOW + 604800))
aws dynamodb scan \
  --table-name url-shortener-links \
  --filter-expression "expires_at BETWEEN :now AND :seven" \
  --expression-attribute-values "{\":now\":{\"N\":\"$NOW\"},\":seven\":{\"N\":\"$SEVEN_DAYS\"}}"
```

**Q: What happens if the Lambda function cold starts during a redirect?**  
A: A Python 3.11 Lambda cold start with 256 MB typically takes 200-400 ms. The redirect still succeeds; the user experiences a slightly longer response on that one request. Provisioned concurrency can eliminate cold starts for latency-sensitive use cases at an additional cost of ~$15/month per always-warm instance.
