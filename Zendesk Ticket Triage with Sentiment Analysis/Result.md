# Deployment Result — Serverless Zendesk Ticket Triage with Sentiment Analysis

**Date:** 2026-06-29
**Region:** us-east-1
**Account:** 022499047467
**Environment:** dev

---

## All AWS Resources Created

23 AWS resources are managed by Terraform (24 state entries including the `archive_file` data source).

| Resource | Name / ID | Details |
|---|---|---|
| API Gateway REST API | `zendesk-triage-api` (`cvuy08ve65`) | Regional; stage `v1`; `POST /webhook` |
| API Gateway Stage | `v1` (deployment `kddjn2`) | Access logging to `/aws/apigateway/zendesk-triage` |
| Lambda Function | `zendesk-triage-function` | python3.11, 256 MB, 15 s timeout, State `Active`, code 2,860 B |
| Lambda Permission | `AllowAPIGatewayInvoke` | Allows API Gateway to invoke the function |
| DynamoDB Table | `SentimentAnalysis` | PAY_PER_REQUEST, `TicketID` (HASH) + `CreatedAt` (RANGE), PITR `ENABLED` |
| SNS Topic | `zendesk-triage-negative-alerts` | 0 confirmed / 0 pending subscriptions (no `alert_email` set) |
| Secrets Manager Secret | `zendesk-triage/zendesk` (`...-K1PXOd`) | Holds `email`, `api_token`, `webhook_signing_secret` |
| IAM Role | `zendesk-triage-lambda-exec` | 5 inline policies (below) |
| IAM Policy | `zendesk-triage-lambda-dynamodb` | PutItem/GetItem/Query on the table ARN |
| IAM Policy | `zendesk-triage-lambda-comprehend` | `comprehend:DetectSentiment` |
| IAM Policy | `zendesk-triage-lambda-sns` | `sns:Publish` to topic ARN |
| IAM Policy | `zendesk-triage-lambda-secrets` | `secretsmanager:GetSecretValue` on secret ARN |
| IAM Policy | `zendesk-triage-lambda-logs` | CreateLogGroup/Stream + PutLogEvents |
| CloudWatch Log Group | `/aws/lambda/zendesk-triage-function` | Retention 30 days |
| CloudWatch Log Group | `/aws/apigateway/zendesk-triage` | Retention 30 days |
| CloudWatch Alarm | `zendesk-triage-lambda-errors` | `Errors` >= 5 / 60 s → SNS; State `OK` |
| CloudWatch Alarm | `zendesk-triage-api-5xx` | `5XXError` >= 5 / 60 s; State `OK` |
| CloudWatch Alarm | `zendesk-triage-api-4xx` | `4XXError` >= 25 / 60 s; State `OK` |

---

## Key Outputs

| Output | Value |
|---|---|
| `webhook_url` | `https://cvuy08ve65.execute-api.us-east-1.amazonaws.com/v1/webhook` |
| `api_base_url` | `https://cvuy08ve65.execute-api.us-east-1.amazonaws.com/v1` |
| `dynamodb_table_name` | `SentimentAnalysis` |
| `dynamodb_table_arn` | `arn:aws:dynamodb:us-east-1:022499047467:table/SentimentAnalysis` |
| `lambda_function_name` | `zendesk-triage-function` |
| `lambda_function_arn` | `arn:aws:lambda:us-east-1:022499047467:function:zendesk-triage-function` |
| `sns_topic_arn` | `arn:aws:sns:us-east-1:022499047467:zendesk-triage-negative-alerts` |
| `secret_arn` | `arn:aws:secretsmanager:us-east-1:022499047467:secret:zendesk-triage/zendesk-K1PXOd` |
| `rest_api_id` | `cvuy08ve65` |
| `lambda_log_group` | `/aws/lambda/zendesk-triage-function` |

---

## Architecture Overview

```
                        Zendesk
   trigger "ticket is created" fires an HMAC-signed webhook
                           │  HTTPS POST /webhook
                           ▼
        API Gateway (cvuy08ve65, Regional, stage v1)
                           │  AWS_PROXY
                           ▼
              Lambda  zendesk-triage-function
              (python3.11, 256 MB, 15 s)
                  │      │      │       │
        ┌─────────┘      │      │       └──────────────┐
        ▼                ▼      ▼                       ▼
   AWS Comprehend   DynamoDB  SNS topic        Zendesk Tickets API
  DetectSentiment  Sentiment- negative-        PUT priority/tag/group
                   Analysis   alerts
        ▲                                              ▲
        └──── Secrets Manager zendesk-triage/zendesk ──┘
                           │
              CloudWatch (2 log groups + 3 alarms, all OK)
```

Traffic flow (verified live): signed webhook → API Gateway → Lambda verifies HMAC → Comprehend returns sentiment + confidence → triage rules → DynamoDB write → (Zendesk API call, skipped while credentials are placeholders) → SNS publish on urgent.

---

## Implementation Result — End-to-End Triage Verified

A signed synthetic webhook was sent through the live Lambda (HMAC-SHA256 over `timestamp + body`, signing secret `test-signing-secret-2026`):

```json
{"id":"999001","subject":"Order late again",
 "description":"This is the third time my order is late and no one will help. I am done."}
```

**Result written to DynamoDB `SentimentAnalysis`:**

| TicketID | Sentiment | Confidence | Priority | Tag |
|---|---|---|---|---|
| `999001` | `NEGATIVE` | `0.9981` | `urgent` | `neg_sentiment` |

Comprehend scored the complaint NEGATIVE at 99.81% confidence; the triage rule (`NEGATIVE ≥ 0.80`) set `priority: urgent` + tag `neg_sentiment` and the record was persisted. The Zendesk Tickets API call returned `skipped (zendesk credentials not configured)` as expected with placeholder credentials.

---

## Validation Suite Results

`bash scripts/test_architecture.sh` — **13 PASS / 0 WARN / 0 FAIL**

| # | Check | Result |
|---|---|---|
| 1 | DynamoDB table ACTIVE | PASS |
| 2 | Key schema TicketID (HASH) + CreatedAt (RANGE) | PASS |
| 3 | Lambda Active | PASS |
| 4 | Lambda runtime python3.11 | PASS |
| 5 | IAM role exists | PASS |
| 6 | IAM role has 5 inline policies | PASS |
| 7 | SNS topic exists | PASS |
| 8 | Secrets Manager secret exists | PASS |
| 9 | API Gateway exists | PASS |
| 10 | API resource `/webhook` exists | PASS |
| 11 | Lambda log group exists | PASS |
| 12 | CloudWatch alarms: 3 configured | PASS |
| 13 | Live signed webhook scored NEGATIVE → urgent | PASS |

---

## CloudWatch Alarms Status

| Alarm | State | Metric | Threshold | Action |
|---|---|---|---|---|
| `zendesk-triage-lambda-errors` | OK | `Errors` (AWS/Lambda) | >= 5 / 60 s | Notify SNS topic |
| `zendesk-triage-api-5xx` | OK | `5XXError` (AWS/ApiGateway) | >= 5 / 60 s | — |
| `zendesk-triage-api-4xx` | OK | `4XXError` (AWS/ApiGateway) | >= 25 / 60 s | — |

No alarms in ALARM state.

---

## Post-Deployment Manual Steps (Zendesk side)

1. Inject real credentials: `aws secretsmanager put-secret-value --secret-id zendesk-triage/zendesk --secret-string '{"email":"agent@corp.com/token","api_token":"...","webhook_signing_secret":"..."}'`
2. Zendesk Admin Center → APIs → create an API token.
3. Zendesk Admin Center → Webhooks → create webhook → target `https://cvuy08ve65.execute-api.us-east-1.amazonaws.com/v1/webhook`, enable signing secret.
4. Zendesk Admin Center → Triggers → "Ticket is Created" → Notify active webhook with the JSON body in the README Quick Start.
5. (Optional) re-apply with `-var 'alert_email=...'` and confirm the SNS subscription email.
