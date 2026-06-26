# Deployment Result — URL Shortener (Internal Smart Link Platform)

**Date:** 2026-06-26
**Region:** us-east-1
**Account:** 022499047467
**Environment:** dev
**Terraform resources:** 24

---

## All AWS Resources Created

| Resource | Name / ID | ARN |
|---|---|---|
| **API Gateway REST API** | `url-shortener-api` / `qywjck4di7` | `arn:aws:apigateway:us-east-1::/restapis/qywjck4di7` |
| **API Gateway Stage** | `v1` / deployment `3rvnft` | `arn:aws:execute-api:us-east-1:022499047467:qywjck4di7/v1` |
| **API Gateway Resource** | `/shorten` / `gi3c5q` | — |
| **API Gateway Resource** | `/redirect` / `x3jnfj` | — |
| **API Gateway Resource** | `/stats` / `ocjwlf` | — |
| **API Gateway Method** | `POST /shorten` | — |
| **API Gateway Method** | `GET /redirect` | — |
| **API Gateway Method** | `GET /stats` | — |
| **API Gateway Integration** | `AWS_PROXY` for all 3 methods | — |
| **API Gateway Deployment** | `3rvnft` | — |
| **Lambda Function** | `url-shortener-function` | `arn:aws:lambda:us-east-1:022499047467:function:url-shortener-function` |
| **Lambda Permission** | `AllowAPIGatewayInvoke` | — |
| **DynamoDB Table** | `url-shortener-links` / `b97f3279-05f3-4ab9-a02e-5301851118ae` | `arn:aws:dynamodb:us-east-1:022499047467:table/url-shortener-links` |
| **IAM Role** | `url-shortener-lambda-exec` / `AROAQKPIMHAVVHLXGW6JB` | `arn:aws:iam::022499047467:role/url-shortener-lambda-exec` |
| **IAM Inline Policy** | `url-shortener-lambda-dynamodb` | — |
| **IAM Inline Policy** | `url-shortener-lambda-logs` | — |
| **CloudWatch Log Group** | `/aws/lambda/url-shortener-function` | `arn:aws:logs:us-east-1:022499047467:log-group:/aws/lambda/url-shortener-function` |
| **CloudWatch Log Group** | `/aws/apigateway/url-shortener` | `arn:aws:logs:us-east-1:022499047467:log-group:/aws/apigateway/url-shortener` |
| **CloudWatch Alarm** | `url-shortener-lambda-errors` | `arn:aws:cloudwatch:us-east-1:022499047467:alarm:url-shortener-lambda-errors` |
| **CloudWatch Alarm** | `url-shortener-api-5xx` | `arn:aws:cloudwatch:us-east-1:022499047467:alarm:url-shortener-api-5xx` |
| **CloudWatch Alarm** | `url-shortener-api-4xx` | `arn:aws:cloudwatch:us-east-1:022499047467:alarm:url-shortener-api-4xx` |

---

## Key Outputs

| Output | Value |
|---|---|
| `api_base_url` | `https://qywjck4di7.execute-api.us-east-1.amazonaws.com/v1` |
| `shorten_endpoint` | `https://qywjck4di7.execute-api.us-east-1.amazonaws.com/v1/shorten` |
| `redirect_endpoint` | `https://qywjck4di7.execute-api.us-east-1.amazonaws.com/v1/redirect` |
| `stats_endpoint` | `https://qywjck4di7.execute-api.us-east-1.amazonaws.com/v1/stats` |
| `dynamodb_table_name` | `url-shortener-links` |
| `dynamodb_table_arn` | `arn:aws:dynamodb:us-east-1:022499047467:table/url-shortener-links` |
| `lambda_function_name` | `url-shortener-function` |
| `lambda_function_arn` | `arn:aws:lambda:us-east-1:022499047467:function:url-shortener-function` |
| `rest_api_id` | `qywjck4di7` |
| `lambda_log_group` | `/aws/lambda/url-shortener-function` |

---

## Architecture Overview

```
Employee Browser / Slack Bot / IT Ops Script
                │
                │  HTTPS → TLS 1.0+ (AWS-managed)
                ▼
┌──────────────────────────────────────────────────────────────────┐
│  API Gateway REST API — url-shortener-api (qywjck4di7)          │
│  Type: REGIONAL  │  Stage: v1 (deployment: 3rvnft)              │
│                                                                  │
│  POST /shorten (gi3c5q)                                          │
│  GET  /redirect (x3jnfj)   ← all AWS_PROXY to Lambda            │
│  GET  /stats   (ocjwlf)                                          │
│                                                                  │
│  Access logs → /aws/apigateway/url-shortener (JSON per request)  │
└────────────────────────────┬─────────────────────────────────────┘
                             │  Lambda:InvokeFunction
                             ▼
          ┌───────────────────────────────────────────┐
          │  Lambda — url-shortener-function          │
          │  Runtime: python3.11  │  Arch: x86_64     │
          │  Memory: 256 MB       │  Timeout: 10 s    │
          │  Code size: 1,505 B   │  State: Active    │
          │  Role: url-shortener-lambda-exec          │
          │  TABLE_NAME → url-shortener-links         │
          └─────────────────────┬─────────────────────┘
                                │  GetItem / PutItem / UpdateItem
                                ▼
     ┌──────────────────────────────────────────────────────┐
     │  DynamoDB — url-shortener-links                      │
     │  TableId: b97f3279-05f3-4ab9-a02e-5301851118ae      │
     │  Billing: PAY_PER_REQUEST  │  Status: ACTIVE         │
     │  TTL: ENABLED on expires_at                          │
     │  PITR: ENABLED (35-day restore window)               │
     └──────────────────────────────────────────────────────┘
                                │
     ┌──────────────────────────────────────────────────────┐
     │  CloudWatch                                          │
     │  /aws/lambda/url-shortener-function  (30-day)        │
     │  /aws/apigateway/url-shortener       (30-day)        │
     │  3 metric alarms — all OK                            │
     └──────────────────────────────────────────────────────┘
```

---

## Lambda Function — Live Details

| Attribute | Value |
|---|---|
| **Function name** | `url-shortener-function` |
| **ARN** | `arn:aws:lambda:us-east-1:022499047467:function:url-shortener-function` |
| **Runtime** | `python3.11` |
| **Architecture** | `x86_64` |
| **Memory** | 256 MB |
| **Timeout** | 10 s |
| **Ephemeral storage** | 512 MB |
| **Code size** | 1,505 bytes |
| **Code SHA256** | `mMWp5y1NwNmdDYbODGe99n31ZQNJn0blWLJuyYKx584=` |
| **State** | Active |
| **Last update status** | Successful |
| **Last modified** | 2026-06-26T06:46:33 UTC |
| **Handler** | `handler.lambda_handler` |
| **Log group** | `/aws/lambda/url-shortener-function` |
| **Tracing** | PassThrough |
| **SnapStart** | Off |

---

## DynamoDB Table — Live Details

| Attribute | Value |
|---|---|
| **Table name** | `url-shortener-links` |
| **Table ID** | `b97f3279-05f3-4ab9-a02e-5301851118ae` |
| **ARN** | `arn:aws:dynamodb:us-east-1:022499047467:table/url-shortener-links` |
| **Status** | ACTIVE |
| **Billing mode** | PAY_PER_REQUEST |
| **Hash key** | `short_code` (String) |
| **TTL status** | ENABLED |
| **TTL attribute** | `expires_at` |
| **PITR status** | ENABLED |
| **PITR restore window** | 35 days |
| **Earliest restorable** | 2026-06-26T14:46:30 +08:00 |
| **Item count** | 0 |
| **Table size** | 0 bytes |
| **Deletion protection** | Disabled |
| **Warm throughput (read)** | 12,000 RCU/s |
| **Warm throughput (write)** | 4,000 WCU/s |

---

## API Gateway — Live Details

| Attribute | Value |
|---|---|
| **API name** | `url-shortener-api` |
| **API ID** | `qywjck4di7` |
| **Type** | REGIONAL |
| **Security policy** | TLS_1_0 |
| **Created** | 2026-06-26T14:46:20 +08:00 |
| **Root resource ID** | `546vnqvxu1` |
| **Stage** | `v1` |
| **Deployment ID** | `3rvnft` |
| **Access log destination** | `arn:aws:logs:us-east-1:022499047467:log-group:/aws/apigateway/url-shortener` |

| Resource | ID | Method |
|---|---|---|
| `/` | `546vnqvxu1` | — |
| `/shorten` | `gi3c5q` | POST |
| `/redirect` | `x3jnfj` | GET |
| `/stats` | `ocjwlf` | GET |

---

## IAM Role — Live Details

| Attribute | Value |
|---|---|
| **Role name** | `url-shortener-lambda-exec` |
| **Role ID** | `AROAQKPIMHAVVHLXGW6JB` |
| **ARN** | `arn:aws:iam::022499047467:role/url-shortener-lambda-exec` |
| **Trust** | `lambda.amazonaws.com` — `sts:AssumeRole` |
| **Created** | 2026-06-26T06:46:20 UTC |
| **Inline policies** | `url-shortener-lambda-dynamodb`, `url-shortener-lambda-logs` |

---

## CloudWatch Alarms — Live Status

| Alarm | State | Metric | Threshold | Dimensions |
|---|---|---|---|---|
| `url-shortener-lambda-errors` | **OK** | Lambda `Errors` (Sum/60s) | >= 5 | `FunctionName=url-shortener-function` |
| `url-shortener-api-5xx` | **OK** | API Gateway `5XXError` (Sum/60s) | >= 10 | `ApiName=url-shortener-api, Stage=v1` |
| `url-shortener-api-4xx` | **OK** | API Gateway `4XXError` (Sum/60s) | >= 50 | _(no dimensions set — monitors all APIs)_ |

> All 3 alarms are in OK state. `treat_missing_data = notBreaching` means the alarms remain OK when there is no traffic.

---

## CloudWatch Log Groups — Live Status

| Log Group | Retention | Stored Bytes | Created |
|---|---|---|---|
| `/aws/lambda/url-shortener-function` | 30 days | 0 B | 2026-06-26 |
| `/aws/apigateway/url-shortener` | 30 days | 0 B | 2026-06-26 |
