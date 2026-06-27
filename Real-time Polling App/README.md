# Real-time Polling App — E-Commerce Edition

A fully serverless real-time polling and interaction platform built on an **API Gateway WebSocket API**, **AWS Lambda**, and **Amazon DynamoDB**. A single WebSocket backbone powers four interaction types: general poll voting plus three e-commerce scenarios — live-stream product voting, flash-sale inventory tracking, and new-product design surveys. Clients open one persistent WebSocket connection (scoped by `sessionId`); votes and purchases are written atomically to DynamoDB and fanned out to every connected client in the session in real time. No servers, VPCs, or load balancers to manage.

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
                    Client (React / Vue / wscat)
                            │  wss:// + ?sessionId=...
                            ▼
        ┌───────────────────────────────────────────────────┐
        │      API Gateway WebSocket API (Regional)         │
        │   Route selection: $request.body.action           │
        │                                                   │
        │  $connect / $disconnect ──► manage_connections    │
        │  sendVote               ──► handle_vote           │
        │  broadcastResults       ──► broadcast_results     │
        │  liveVote               ──► livestream_vote       │
        │  flashPurchase          ──► flashsale_update      │
        │  designVote             ──► design_vote           │
        └─────────────────────────┬─────────────────────────┘
                                  │  AWS_PROXY integration
                                  ▼
        ┌───────────────────────────────────────────────────┐
        │            6 Lambda Functions (Python 3.11)       │
        │   atomic UpdateExpression ADD / conditional writes│
        │   fan-out via execute-api:ManageConnections       │
        └─────────────────────────┬─────────────────────────┘
                                  │
            ┌─────────────────────┼─────────────────────────┐
            ▼                     ▼                         ▼
   ┌────────────────┐   ┌──────────────────┐    ┌────────────────────┐
   │  Connections   │   │      Polls       │    │ LiveStreamSessions │
   │  (PK conn-id)  │   │   (PK pollId)    │    │   (PK sessionId)   │
   │  GSI: session  │   └──────────────────┘    └────────────────────┘
   │  TTL: ttl      │   ┌──────────────────┐    ┌────────────────────┐
   └────────────────┘   │  FlashSaleItems  │    │   DesignSurveys    │
                        │   (PK itemId)    │    │   (PK surveyId)    │
                        └──────────────────┘    └────────────────────┘
                                  │
                        ┌──────────────────────┐
                        │   Amazon CloudWatch  │
                        │  6 Lambda log groups │
                        │  + access logs       │
                        │  7 metric alarms     │
                        └──────────────────────┘
```

Traffic flow: Client opens a WebSocket with a `sessionId` query parameter → API Gateway invokes `manage_connections` on `$connect`, persisting `{connectionId, sessionId, ttl}` → client sends a JSON message whose `action` field selects a route → the matched Lambda atomically updates the scenario's DynamoDB table → the Lambda queries the Connections `sessionId-index` GSI to find every active connection in the session and pushes the new tally to each via `PostToConnection` → stale (410 Gone) connections are pruned. CloudWatch records per-function logs, access logs, and alarm metrics.

---

## Networking & Routing

### API Endpoint Configuration

| Property | Value |
|---|---|
| **Endpoint type** | Regional WebSocket (AWS-managed TLS) |
| **Connect URL** | `wss://<api-id>.execute-api.<region>.amazonaws.com/<stage>` |
| **Management endpoint** | `https://<api-id>.execute-api.<region>.amazonaws.com/<stage>` |
| **Route selection** | `$request.body.action` |
| **Authentication** | None at `$connect` (add a Lambda authorizer for production) |
| **VPC required** | No — API Gateway, Lambda, and DynamoDB are fully managed |
| **Session scoping** | `sessionId` query-string parameter, stored on `$connect` |

### Route → Lambda Mapping

| Route key | Lambda | DynamoDB write |
|---|---|---|
| `$connect` | `manage_connections` | `PutItem` Connections (+ TTL) |
| `$disconnect` | `manage_connections` | `DeleteItem` Connections |
| `sendVote` | `handle_vote` | `ADD votes[option]` Polls |
| `broadcastResults` | `broadcast_results` | `GetItem` Polls (read) → fan-out |
| `liveVote` | `livestream_vote` | `ADD voteCounts[productId]` LiveStreamSessions |
| `flashPurchase` | `flashsale_update` | conditional decrement FlashSaleItems |
| `designVote` | `design_vote` | `ADD votes[designId]` DesignSurveys |

### Fan-out Flow

```
       Client A ───┐
       Client B ───┼─ same sessionId ─► one WebSocket message (action=liveVote)
       Client C ───┘                          │
                                              ▼
                              livestream_vote Lambda
                                              │  ADD voteCounts[productId]
                                              ▼
                              Query Connections GSI (sessionId-index)
                                              │  [conn-A, conn-B, conn-C]
                                              ▼
                              PostToConnection × 3  ◄── 410 Gone? DeleteItem
                                              │
                              Clients A, B, C all receive new voteCounts
```

---

## Component Details

### 1. WebSocket API

| Attribute | Value |
|---|---|
| **Name** | `realtime-polling-ws-api` |
| **Protocol** | `WEBSOCKET` |
| **Route selection expression** | `$request.body.action` |
| **Stage** | `production` (auto-deploy enabled) |
| **Integration type** | `AWS_PROXY` (Lambda) for all routes |
| **Throttling** | 10,000 steady / 5,000 burst (default route settings) |
| **Access logs** | JSON to `/aws/apigateway/realtime-polling-ws` |

> Auto-deploy means every route or integration change is published to the stage immediately — no separate deployment resource is required for WebSocket APIs.

### 2. Lambda Functions

All six functions share a single deployment package (`lambda/` zipped whole, so the `_broadcast.py` fan-out helper is importable everywhere), each with a distinct handler entrypoint.

| Function | Handler | Responsibility |
|---|---|---|
| `realtime-polling-manage_connections` | `manage_connections.lambda_handler` | `$connect` / `$disconnect` lifecycle |
| `realtime-polling-handle_vote` | `handle_vote.lambda_handler` | General poll vote (`ADD`) |
| `realtime-polling-broadcast_results` | `broadcast_results.lambda_handler` | Read Polls → fan-out tallies |
| `realtime-polling-livestream_vote` | `handle_livestream_vote.lambda_handler` | Scenario 1 live product vote |
| `realtime-polling-flashsale_update` | `handle_flashsale_update.lambda_handler` | Scenario 2 conditional stock decrement |
| `realtime-polling-design_vote` | `handle_design_vote.lambda_handler` | Scenario 3 design preference vote |

| Shared config | Value |
|---|---|
| **Runtime** | Python 3.11 |
| **Memory** | 256 MB (configurable) |
| **Timeout** | 10 s (configurable) |
| **Environment** | `POLLS_TABLE`, `CONNECTIONS_TABLE`, `LIVESTREAM_TABLE`, `FLASHSALE_TABLE`, `DESIGN_TABLE`, `CONNECTION_TTL_SECONDS` |

### 3. DynamoDB Tables

| Table | PK | Key attributes | Special |
|---|---|---|---|
| `realtime-polling-polls` | `pollId` (S) | `votes` (Map) | PITR |
| `realtime-polling-connections` | `connectionId` (S) | `sessionId`, `connectedAt`, `ttl` | GSI `sessionId-index`, TTL on `ttl` |
| `realtime-polling-livestream-sessions` | `sessionId` (S) | `productOptions`, `voteCounts`, `status`, `expiresAt` | TTL on `expiresAt`, PITR |
| `realtime-polling-flashsale-items` | `itemId` (S) | `totalStock`, `remainingStock`, `purchaseCount`, `status` | PITR |
| `realtime-polling-design-surveys` | `surveyId` (S) | `designOptions`, `votes` (Map), `status` | PITR |

> All tables are on-demand (`PAY_PER_REQUEST`). The Connections `sessionId-index` GSI is the hot path — every fan-out queries it, and `projection_type = ALL` avoids a second round-trip to the base table.

### 4. Atomic Write Strategy

| Scenario | Expression | Guarantee |
|---|---|---|
| Poll / live / design vote | `UpdateExpression: ADD votes.#k :one` | Lost-update-free increment under concurrency |
| Flash purchase | `ConditionExpression: remainingStock > :zero` | Never oversells; depletion → `sold_out` to buyer only |
| Live vote / design vote | `ConditionExpression: #status = :active/:open` | Votes rejected once a session/survey closes |

### 5. IAM Role

| Role | Inline policies |
|---|---|
| `realtime-polling-lambda-exec` | `lambda-dynamodb` (5 tables + GSI), `lambda-manage-connections` (`execute-api:ManageConnections` on the stage), `lambda-logs` (scoped to `/aws/lambda/realtime-polling-*`) |

### 6. CloudWatch

| Resource | Detail |
|---|---|
| **6 Lambda log groups** | `/aws/lambda/realtime-polling-<fn>`, 30-day retention |
| **Access log group** | `/aws/apigateway/realtime-polling-ws` |
| **6 Lambda error alarms** | `Errors >= 5` per function in 60 s |
| **1 integration error alarm** | `IntegrationError >= 10` on the stage in 60 s |

---

## Directory Structure

```
Real-time Polling App/
├── README.md                          # This file
├── lambda/
│   ├── _broadcast.py                   # Shared fan-out helper (GSI query + PostToConnection)
│   ├── manage_connections.py           # $connect / $disconnect
│   ├── handle_vote.py                  # sendVote
│   ├── broadcast_results.py            # broadcastResults
│   ├── handle_livestream_vote.py       # liveVote (Scenario 1)
│   ├── handle_flashsale_update.py      # flashPurchase (Scenario 2)
│   └── handle_design_vote.py           # designVote (Scenario 3)
├── terraform/
│   ├── provider.tf                     # AWS + archive providers; caller identity; common_tags
│   ├── variables.tf                    # 9 input variables with validation
│   ├── dynamodb.tf                     # 5 tables (Connections GSI + TTLs)
│   ├── iam.tf                          # Execution role + 3 inline policies
│   ├── lambda.tf                       # Single zip, 6 functions + permissions (for_each)
│   ├── apigateway.tf                   # WebSocket API, 6 integrations, 7 routes, stage
│   ├── cloudwatch.tf                   # 7 log groups + 7 alarms
│   └── outputs.tf                      # WebSocket URL, management endpoint, table map
└── scripts/
    └── test_architecture.sh            # Architecture validation across all resources
```

---

## Prerequisites

| Tool | Minimum Version | Install |
|---|---|---|
| **Terraform** | 1.9 | [developer.hashicorp.com/terraform/install](https://developer.hashicorp.com/terraform/install) |
| **AWS CLI** | 2.0 | [docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html) |
| **Python** | 3.11 | [python.org/downloads](https://www.python.org/downloads/) |
| **wscat** | 5.0 | `npm install -g wscat` (for live WebSocket testing) |
| **jq** | 1.6 | `brew install jq` / `apt install jq` |

**Account requirements:**
- IAM permissions to create: DynamoDB tables + GSIs, Lambda functions, IAM roles/inline policies, API Gateway v2 (WebSocket) APIs, and CloudWatch log groups/alarms.
- No VPC, NAT Gateway, or EC2 required.

---

## Quick Start

```bash
# 1. Enter the Terraform directory
cd "Real-time Polling App/terraform"

# 2. Initialise providers (AWS + archive)
terraform init

# 3. Preview the plan
terraform plan

# 4. Deploy everything
terraform apply

# 5. Capture the WebSocket URL
WS_URL=$(terraform output -raw websocket_url)

# 6. Seed a live-stream session (so liveVote has an active session to update)
aws dynamodb put-item --table-name realtime-polling-livestream-sessions --item '{
  "sessionId":{"S":"session_001"},
  "productOptions":{"L":[{"S":"Product A"},{"S":"Product B"}]},
  "voteCounts":{"M":{}},
  "status":{"S":"active"},
  "expiresAt":{"N":"'$(($(date +%s)+7200))'"}
}'

# 7. Connect and vote (separate terminal)
wscat -c "${WS_URL}?sessionId=session_001"
> {"action":"liveVote","sessionId":"session_001","productId":"Product A"}

# 8. Validate the deployed architecture
cd ..
bash scripts/test_architecture.sh
```

Allow 1-2 minutes after apply for the WebSocket stage to become reachable.

---

## Input Variables

| Variable | Type | Default | Description |
|---|---|---|---|
| `aws_region` | string | `us-east-1` | AWS region for all resources |
| `project_name` | string | `realtime-polling` | Prefix for all resource names |
| `environment` | string | `dev` | Environment (`dev`, `staging`, `prod`) |
| `stage_name` | string | `production` | WebSocket stage name (URL path segment) |
| `lambda_memory_mb` | number | `256` | Memory per Lambda (128–10240) |
| `lambda_timeout_seconds` | number | `10` | Timeout per Lambda (1–900) |
| `connection_ttl_seconds` | number | `7200` | Idle connection TTL (2 hours) |
| `cloudwatch_retention_days` | number | `30` | Log retention for all log groups |
| `alarm_lambda_error_threshold` | number | `5` | Per-function error count before alarm |
| `alarm_integration_error_threshold` | number | `10` | Integration errors before alarm |

Cross-variable note: `cloudwatch_retention_days` must be a CloudWatch-accepted value (validated); `stage_name` feeds both the stage resource and the `execute-api:ManageConnections` IAM resource ARN, so the Lambda fan-out permission stays correctly scoped if you rename the stage.

---

## Outputs

| Output | Description |
|---|---|
| `websocket_url` | `wss://` URL — append `?sessionId=<id>` to connect |
| `websocket_management_endpoint` | HTTPS endpoint for `PostToConnection` |
| `api_id` | WebSocket API ID |
| `stage_name` | Deployed stage name |
| `lambda_function_names` | Map of logical name → deployed function name |
| `dynamodb_tables` | Map of all five table names |
| `connections_gsi` | GSI name used for fan-out (`sessionId-index`) |

```bash
terraform output -raw websocket_url
terraform output -json dynamodb_tables
```

---

## Scaling Behaviour

This stack is fully serverless — concurrency and capacity scale automatically.

```
Concurrent WebSocket connections
   100k ┤                                         ████
    50k ┤                               █████████
    10k ┤                     █████████
     1k ┤          ██████████
    100 ┤ ████████
        └──────────────────────────────────────────── time
          flash sale starts ──► spike ──► sustained ──► drain

API Gateway WebSocket: scales to hundreds of thousands of connections.
Lambda: scales per message; default 1,000 concurrent executions per region.
DynamoDB on-demand: absorbs vote/purchase bursts without provisioning.
```

**Scaling notes:**
- WebSocket connection cost is per-minute-connected + per-message; idle connections are cheap and auto-expire via the Connections TTL.
- The fan-out is O(connections-per-session). For very large sessions (10k+ viewers), batch `PostToConnection` calls or shard sessions to stay within Lambda timeout.
- DynamoDB atomic `ADD` and conditional writes mean correctness holds regardless of how many Lambdas run concurrently.
- At zero traffic the cost is effectively $0 (alarms only).

---

## Tagging Strategy

| Tag Key | Value | Applied To |
|---|---|---|
| `Project` | `Real-time Polling App` | All resources |
| `Environment` | `dev` / `staging` / `prod` | All resources |
| `ManagedBy` | `Terraform` | All resources |
| `Name` | Resource-specific (e.g. `realtime-polling-connections`) | DynamoDB, Lambda |

> API Gateway v2 APIs and stages carry `local.common_tags`. The shared `archive_file` produces no AWS resource and is untagged.

---

## Security Considerations

| Topic | Current posture | Recommended hardening |
|---|---|---|
| **Connection auth** | `$connect` is open | Add a Lambda authorizer or `$connect` request authorizer validating a JWT/API key before storing the connection |
| **Session ownership** | `sessionId` is client-supplied | Derive `sessionId` from an authenticated identity to stop clients joining arbitrary sessions |
| **IAM scope** | Role scoped to the five tables, the GSI, and the stage's `@connections/*` | Already least-privilege; no `*` resources |
| **Throttling** | 10k steady / 5k burst at stage | Lower per-stage limits or add usage-plan-style throttling for public deployments |
| **Vote integrity** | Conditional writes prevent closed-session votes and overselling | Add per-connection rate limiting to prevent vote spamming from one client |
| **DynamoDB encryption** | AWS-managed keys (default) | Switch to a customer-managed KMS key for compliance |
| **Data trace** | `data_trace_enabled = false` | Keep false in prod (avoids logging full message bodies) |

---

## Cost Estimate

Assumes a moderate event: 10,000 concurrent viewers, 30-minute session, ~500k messages.

| Resource | Quantity | Monthly cost (USD) |
|---|---|---|
| **API Gateway WebSocket — messages** | 500k messages | ~$0.50 |
| **API Gateway WebSocket — connection minutes** | 10k × 30 min = 300k min | ~$0.08 |
| **Lambda** | ~500k invocations × 60 ms × 256 MB | ~$0.20 |
| **DynamoDB on-demand** | ~1M writes + 500k reads | ~$1.50 |
| **CloudWatch Logs + 7 alarms** | ~1 GB ingest + alarms | ~$2.60 |
| **Total (per event of this size)** | | **~$4.88** |

At rest (no traffic) the stack costs ~$0.70/month (7 alarms). [AWS Pricing Calculator](https://calculator.aws/)

---

## Destroying the Stack

```bash
cd "Real-time Polling App/terraform"
terraform destroy
```

All resources (WebSocket API, stage, 6 Lambdas, 5 DynamoDB tables, IAM role, 7 log groups, 7 alarms) are Terraform-managed and removed on destroy.

> **Data loss warning:** `terraform destroy` permanently deletes all five DynamoDB tables and their data (active sessions, vote tallies, flash-sale inventory). Export anything you need first with `aws dynamodb scan`.

Resources **not** managed by Terraform that survive destroy:
- The local `lambda/build/functions.zip` produced by `archive_file` — delete manually if desired.
- Log events already ingested are removed when their log groups are deleted.

---

## Frequently Asked Questions

**Q: Why does a vote sometimes not appear for other viewers?**
A: Fan-out targets only connections whose `sessionId` matches. If two clients connected with different `sessionId` query parameters, they are in different sessions and won't see each other's votes. Confirm both used the same `?sessionId=` value at connect time, and that their connection records still exist (they auto-expire after `connection_ttl_seconds`).

**Q: How does the flash sale avoid overselling under a stampede?**
A: `handle_flashsale_update` decrements `remainingStock` with `ConditionExpression: remainingStock > :zero`. DynamoDB evaluates the condition atomically, so concurrent purchases are serialised at the item level — the moment stock hits zero, every further request raises `ConditionalCheckFailedException` and the buyer alone receives `{status: "sold_out"}`. No request can drive stock negative.

**Q: Why is there one shared Lambda zip instead of six packages?**
A: All handlers import the `_broadcast.py` fan-out helper. Zipping the whole `lambda/` directory once and pointing each `aws_lambda_function` at a different `handler` keeps the helper importable everywhere, avoids duplicate code, and means a single `source_code_hash` redeploys all functions together when any handler changes.

**Q: What happens to connections when a client closes the browser?**
A: API Gateway fires `$disconnect`, and `manage_connections` deletes the connection record. If the disconnect is missed (e.g. network drop), the record lingers until the `ttl` attribute expires (2 hours by default), and any fan-out that hits the stale `connectionId` gets `410 Gone` and prunes it immediately — so dead connections are cleaned up two ways.

**Q: How do I add HTTPS / a custom domain like `polls.techcorp.com`?**
A: WebSocket APIs support custom domain names via `aws_apigatewayv2_domain_name` + an ACM certificate, mapped to the stage with `aws_apigatewayv2_api_mapping`. Clients then connect to `wss://polls.techcorp.com`. The connection is already TLS-encrypted on the default `execute-api` endpoint; a custom domain only changes the hostname.

**Q: Why use a GSI on the Connections table instead of scanning?**
A: Fan-out must find every connection in a session on every message. A `Scan` would read the whole table each time (slow and costly as connections grow); the `sessionId-index` GSI turns it into a single `Query` returning only that session's connections, with `projection_type = ALL` so no follow-up `GetItem` is needed.
