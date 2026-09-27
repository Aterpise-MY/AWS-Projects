# URL Shortener — Resume Summary

## Project Overview

A fully serverless internal smart-link platform (designed for `go.techcorp.internal`) built on API Gateway, Lambda, and DynamoDB and provisioned with Terraform. A Regional REST API (`url-shortener-api`, stage `v1`) exposes three endpoints — `POST /shorten` to create a link with an optional custom code, label, and expiry; `GET /redirect` to atomically increment a click counter and return a `301`; and `GET /stats` to return per-link analytics — all routed through `AWS_PROXY` integrations to a single Python 3.11 Lambda (`url-shortener-function`). Links live in the on-demand DynamoDB table `url-shortener-links`, keyed by `short_code`, with native TTL on `expires_at`; the handler also checks expiry itself and returns `410 Gone` before TTL physically removes an item. Custom-code collisions return `409 Conflict`. API Gateway writes structured JSON access logs to CloudWatch and three metric alarms watch Lambda errors and API 4XX/5XX rates. The stack was deployed and audited on 2026-06-26 to account `022499047467` in `us-east-1` (`dev` environment) with API ID `qywjck4di7`, and `Result.md` confirms the Lambda `Active`, the table `ACTIVE` with TTL and PITR enabled, and all three alarms `OK`.

## Architecture

```
          Employee browser / Slack bot / IT ops script
                              │  HTTPS (AWS-managed TLS)
                              ▼
┌───────────────────────────────────────────────────────────────────┐
│  API Gateway REST  url-shortener-api  (qywjck4di7)  REGIONAL      │
│  Stage v1  ·  deployment 3rvnft                                   │
│                                                                   │
│   POST /shorten      GET /redirect       GET /stats               │
│   (gi3c5q)           (x3jnfj)            (ocjwlf)                 │
│        └──────────────────┼──────────────────┘                    │
│                           │ AWS_PROXY (all three)                 │
│  access logs ─► /aws/apigateway/url-shortener (JSON per request)  │
└───────────────────────────┼───────────────────────────────────────┘
                            ▼
          ┌──────────────────────────────────────────┐
          │  Lambda  url-shortener-function          │
          │  python3.11 · 256 MB · 10 s · x86_64     │
          │  role url-shortener-lambda-exec          │
          │  ├── _handle_shorten   201/400/409/500   │
          │  ├── _handle_redirect  301/400/404/410   │
          │  └── _handle_stats     200/400/404       │
          └────────────────────┬─────────────────────┘
                               │ GetItem / PutItem / UpdateItem
                               ▼
     ┌─────────────────────────────────────────────────────────┐
     │  DynamoDB  url-shortener-links                          │
     │  PK short_code (S)  ·  PAY_PER_REQUEST                  │
     │  TTL on expires_at  ·  PITR enabled (35-day)            │
     └─────────────────────────────────────────────────────────┘
                               │
     ┌─────────────────────────────────────────────────────────┐
     │  CloudWatch                                             │
     │  /aws/lambda/url-shortener-function (30-day)            │
     │  /aws/apigateway/url-shortener      (30-day)            │
     │  ├── url-shortener-lambda-errors  >= 5  / 60 s          │
     │  ├── url-shortener-api-5xx        >= 10 / 60 s          │
     │  └── url-shortener-api-4xx        >= 50 / 60 s          │
     └─────────────────────────────────────────────────────────┘
```

## Technology Stack

| Layer | Technology | Purpose |
|---|---|---|
| **API** | Amazon API Gateway (REST, Regional, stage `v1`) | Three resources, `AWS_PROXY` integrations, JSON access logging |
| **Compute** | AWS Lambda (Python 3.11, 256 MB, 10 s) | Single-file handler dispatching on `httpMethod` + `resource` |
| **Database** | Amazon DynamoDB (on-demand) | `url-shortener-links`, PK `short_code`, TTL on `expires_at`, PITR |
| **Identity** | AWS IAM (1 role, 2 inline policies) | DynamoDB actions on the table ARN; logs actions on the Lambda log-group ARN |
| **Observability** | CloudWatch Logs (2 groups) + 3 metric alarms | Lambda logs, API access logs, Lambda-error / 5XX / 4XX alarms |
| **Packaging** | Terraform `archive_file` data source | Zips `lambda/handler.py` into `lambda/function.zip` at plan/apply |
| **IaC** | Terraform `>= 1.9` (AWS `~> 5.0`, archive `~> 2.0`) | 23 resource blocks across 8 `.tf` files; `common_tags` local |
| **Testing** | Bash + AWS CLI + `jq` + `curl` | `scripts/test_architecture.sh` — infrastructure checks plus 6 live API scenarios |

## Key Achievements

- **Two-layer link expiry** — DynamoDB TTL on `expires_at` removes expired items asynchronously, while the handler compares `expires_at` to the current time and returns `410 Gone` immediately, so users never follow an expired link during the TTL deletion window.
- **Human-readable custom codes with collision detection** — `custom_code` is lower-cased and spaces become `-`; an existing code returns `409 Conflict`. Auto-generated codes are 6 lowercase alphanumeric characters, retried up to 3 times on collision before a `500`.
- **Click analytics on every redirect** — `click_count` incremented with a DynamoDB update expression and `last_accessed` stamped, exposed through `GET /stats`.
- **Accurate click counting** — redirects send `Cache-Control: no-cache, no-store`, so browsers do not cache the `301` and skip the counter.
- **Bounded, validated input** — `long_url` required, `expires_in_days` must be an integer between 1 and 36500 (default 3650), malformed JSON returns `400`.
- **Least-privilege IAM** — the execution role's DynamoDB policy is scoped to the table ARN and its logs policy to the Lambda log-group ARN only.
- **Change-safe API deployments** — the deployment's `triggers` hash every resource, method, and integration ID, with `create_before_destroy`, so route changes always redeploy the stage.
- **Deployed and audited** — live on 2026-06-26 with IDs, ARNs, and runtime details recorded in `Result.md`.

## Infrastructure Components

| Component | Count | Details |
|---|---|---|
| **REST API** | 1 | `url-shortener-api` (`qywjck4di7`), `REGIONAL`, root resource `546vnqvxu1` |
| **API resources** | 3 | `/shorten` (`gi3c5q`), `/redirect` (`x3jnfj`), `/stats` (`ocjwlf`) |
| **Methods** | 3 | `POST /shorten`; `GET /redirect` and `GET /stats` require the `short_code` query string |
| **Integrations** | 3 | `AWS_PROXY` to `url-shortener-function` |
| **Deployment + stage** | 2 | Deployment `3rvnft`; stage `v1` with JSON access logs |
| **Lambda function** | 1 | `url-shortener-function`, `handler.lambda_handler`, 256 MB, 10 s, code size 1,505 B |
| **Lambda permission** | 1 | `AllowAPIGatewayInvoke` from the API's `execution_arn/*/*` |
| **DynamoDB table** | 1 | `url-shortener-links` (`b97f3279-05f3-4ab9-a02e-5301851118ae`), TTL + PITR, deletion protection off |
| **IAM role + policies** | 3 | `url-shortener-lambda-exec` (`AROAQKPIMHAVVHLXGW6JB`) + `url-shortener-lambda-dynamodb` + `url-shortener-lambda-logs` |
| **CloudWatch log groups** | 2 | `/aws/lambda/url-shortener-function`, `/aws/apigateway/url-shortener`, 30-day retention |
| **CloudWatch alarms** | 3 | `url-shortener-lambda-errors`, `url-shortener-api-5xx`, `url-shortener-api-4xx` |
| **Total** | **23** | Resource blocks in `terraform/` (`Result.md` header reports 24 Terraform resources) |

## Deployment Issues Diagnosed & Resolved

No deployment issues are recorded in the project sources — `Result.md` documents a clean deployment and there is no troubleshooting log in the folder. The rows below are observations recorded in `Result.md` and the README rather than incidents that were fixed.

| Issue | Root cause | Fix |
|---|---|---|
| No deployment issues recorded | — | — |
| *(audit observation)* `url-shortener-api-4xx` alarm is account-wide | The alarm resource sets no `dimensions`, so it evaluates `4XXError` across all APIs (noted in `Result.md`) | Not yet fixed — add `ApiName` / `Stage` dimensions as on the 5XX alarm |
| *(documentation drift)* Quick Start says TTL must be enabled in the console | `dynamodb.tf` already declares `ttl { enabled = true }` | None needed in code — `Result.md` confirms TTL `ENABLED` on `expires_at` after apply |

## Test Results

`Result.md` is a live-resource audit (2026-06-26) and is the recorded evidence below. `scripts/test_architecture.sh` runs 7 sections — Terraform state, DynamoDB, Lambda, IAM, API Gateway, CloudWatch, and 6 live API scenarios — and uses the hard-coded IDs from the 2026-06-26 deployment when no local state is present. The project and root READMEs describe it as a "16-check" suite. No run output is saved in the repository, so the live scenarios show what the script tests, not a recorded pass count.

| Check | Scope | Recorded result |
|---|---|---|
| DynamoDB table | `url-shortener-links` | `ACTIVE`, `PAY_PER_REQUEST` (`Result.md`) |
| DynamoDB TTL | `expires_at` | `ENABLED` (`Result.md`) |
| Point-in-time recovery | Links table | `ENABLED`, 35-day window (`Result.md`) |
| Lambda | `url-shortener-function` | `Active`, `python3.11`, 256 MB, last update `Successful` (`Result.md`) |
| IAM | `url-shortener-lambda-exec` | Present with 2 inline policies (`Result.md`) |
| API Gateway | `qywjck4di7`, 3 resources, stage `v1` | Present, access logging to `/aws/apigateway/url-shortener` (`Result.md`) |
| CloudWatch log groups | Lambda + API | Both present, 30-day retention (`Result.md`) |
| CloudWatch alarms | Lambda errors, API 5XX, API 4XX | All 3 `OK` (`Result.md`) |
| Live: `POST /shorten` | Custom code, expect `201` | Defined in script; run output not recorded |
| Live: `GET /stats` | Expect `200` with metadata | Defined in script; run output not recorded |
| Live: `GET /redirect` | Expect `301` | Defined in script; run output not recorded |
| Live: duplicate `POST /shorten` | Expect `409 Conflict` | Defined in script; run output not recorded |
| Live: unknown code on `/stats` | Expect `404` | Defined in script; run output not recorded |
| Live: click counting | `click_count >= 1` after redirect | Defined in script; run output not recorded |

## Quick Start

```bash
# 1. Deploy
cd "URL Shortener/terraform"
terraform init
terraform plan
terraform apply

# 2. Capture the base URL
BASE_URL=$(terraform output -raw api_base_url)

# 3. Create a custom short link (90-day expiry)
curl -X POST "$BASE_URL/shorten" -H "Content-Type: application/json" \
  -d '{"long_url":"https://confluence.techcorp.internal/pages/938471","custom_code":"q3-okr","expires_in_days":90,"created_by":"strategy-team","label":"Q3 OKR Homepage"}'

# 4. Follow it (expect 301), then read its stats
curl -I "$BASE_URL/redirect?short_code=q3-okr"
curl "$BASE_URL/stats?short_code=q3-okr"

# 5. Run the architecture validation suite
cd ..
bash scripts/test_architecture.sh
```

> Allow 2-3 minutes for API Gateway deployment propagation on first apply.

## Cost Estimate

Figures from the project `README.md` at 100K requests/month in `us-east-1`; no resource has a standing hourly charge.

| Resource | Quantity (100K req/month) | Monthly Cost (USD) |
|---|---|---|
| API Gateway | 100,000 REST API calls | ~$0.35 |
| Lambda | 100,000 invocations × ~50 ms × 256 MB | ~$0.03 |
| DynamoDB | 100,000 writes + 200,000 reads (on-demand) | ~$0.18 |
| CloudWatch Logs | ~0.5 GB ingestion | ~$0.25 |
| CloudWatch alarms | 3 | ~$0.30 |
| **Total** | | **~$1.11 / month** |

> The README scales this to ~$9/month at 1M requests, and ~$0.30/month at zero traffic (alarms only).

## Security Posture

| Topic | Posture |
|---|---|
| Authentication | None — all three methods use `authorization = "NONE"`; API key usage plan or Cognito authoriser recommended |
| Network exposure | Public Regional endpoint; private API type or VPC endpoint recommended for an internal-only service |
| Transport | HTTPS only, AWS-managed TLS; `Result.md` records the `TLS_1_0` security policy |
| IAM | One execution role; DynamoDB actions scoped to the table ARN, logs actions to the Lambda log-group ARN |
| Redirect target validation | `long_url` scheme is not validated — `https://`-only check recommended to block `javascript:` / `data:` URIs |
| Rate limiting | Account-level API Gateway throttle only; per-client usage-plan throttling recommended |
| Data protection | PITR enabled; deletion protection disabled (dev default) |
| Encryption at rest | DynamoDB default encryption; CMK recommended for key control |
| Logging | Structured JSON access log per request (request ID, source IP, method, path, status, latency) |
| CORS | Responses set `Access-Control-Allow-Origin: *` |

## Project Structure

```
URL Shortener/
├── .gitignore                   # Excludes function.zip, .terraform/, state, lock file
├── README.md                    # Full documentation (14 sections, 7 FAQs)
├── Result.md                    # Live deployment audit (2026-06-26)
├── lambda/
│   └── handler.py               # Single-file Lambda — /shorten, /redirect, /stats
├── scripts/
│   └── test_architecture.sh     # 7-section infra checks + 6 live API scenarios
└── terraform/
    ├── provider.tf              # Terraform >= 1.9; AWS ~> 5.0, archive ~> 2.0; common_tags
    ├── variables.tf             # 9 input variables (4 with validation)
    ├── dynamodb.tf              # On-demand table, TTL on expires_at, PITR
    ├── iam.tf                   # Lambda execution role + 2 inline policies
    ├── lambda.tf                # archive_file, aws_lambda_function, API Gateway permission
    ├── api_gateway.tf           # REST API, 3 resources/methods/integrations, deployment, v1 stage
    ├── cloudwatch.tf            # 2 log groups + 3 metric alarms
    └── outputs.tf               # 10 outputs (URLs, table, function, API ID, log group)
```

## Key Learnings & Technical Decisions

**TTL is eventual; application logic must be exact.** DynamoDB TTL deletes expired items asynchronously (the README notes up to 48 hours), so relying on TTL alone would keep serving expired links. The handler checks `expires_at` on every redirect and returns `410 Gone`, and TTL is left to do what it does best — cleaning up storage for free.

**One Lambda, three routes.** With `AWS_PROXY` integration the full request arrives as the event, and the handler dispatches on `httpMethod` + `resource`. A single 1,505-byte function keeps packaging trivial (`archive_file` zips one file) and lets Lambda own every status code — `201`, `301`, `400`, `404`, `409`, `410`, `500`.

**301 semantics versus click accuracy.** A permanent redirect is the right signal for a short link, but a cached `301` means later clicks never reach the API. Adding `Cache-Control: no-cache, no-store` keeps the `301` while ensuring each click is counted.

**Force redeployments from the resources that matter.** API Gateway stages do not pick up route changes without a new deployment. Hashing every resource, method, and integration ID into the deployment's `triggers` (with `create_before_destroy`) makes route changes redeploy automatically without stage downtime.

**Alarm on 4XX as a security signal.** A spike in client errors on a link shortener often means scanning or guessing of codes, so the 4XX alarm (50 per minute) sits alongside the usual Lambda-error and 5XX alarms.

## What I'd Do Differently

- **Add authentication and per-client throttling** — an API key usage plan or Cognito authoriser, since link creation is currently open.
- **Validate `long_url`** to `https://` only, closing the open-redirect vector the README already flags.
- **Scope the 4XX alarm** with `ApiName` / `Stage` dimensions so it does not monitor every API in the account.
- **Make code creation atomic** — use a `PutItem` with `attribute_not_exists(short_code)` instead of `GetItem`-then-`PutItem`, which leaves a small race window between two creators of the same custom code.
- **Use `ADD click_count :inc`** (as the README describes) rather than `SET click_count = click_count + :inc`, which relies on the attribute already existing.
- **Raise the TLS policy to `TLS_1_2`** and put the service behind a custom domain (`go.techcorp.internal`) with ACM.
- **Save test-script output with `Result.md`** and reconcile the documented "16 checks" with the script's actual assertions; also remove the stale manual-TTL step from the README.

## Summary

This project delivers a production-shaped internal link shortener on a fully serverless stack: a Regional REST API with three proxy-integrated routes, a single Python 3.11 Lambda handling creation, redirection, click analytics, and conflict detection, and an on-demand DynamoDB table with native TTL backed by in-code expiry checks for exact `410 Gone` behaviour. Least-privilege IAM, structured access logs, and three CloudWatch alarms round out the operational posture across 23 Terraform resource blocks. It was deployed on 2026-06-26 to `us-east-1`, and the `Result.md` audit confirms the Lambda active, the table active with TTL and PITR enabled, and all alarms `OK`, at an estimated ~$1.11/month for 100K requests.
