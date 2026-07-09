# Real-time Polling App — E-Commerce Edition — Resume Summary

## Project Overview

A fully serverless real-time polling and interaction platform built on an API Gateway WebSocket API, AWS Lambda, and Amazon DynamoDB, deployed on AWS with Infrastructure as Code via Terraform. A single WebSocket backbone powers four interaction types over one persistent connection scoped by `sessionId`: general poll voting plus three e-commerce scenarios — live-stream product voting, flash-sale inventory tracking, and new-product design surveys. Clients open one `wss://` connection, send a JSON message whose `action` field selects a route, and the matched Lambda writes atomically to DynamoDB (lost-update-free `ADD` increments and conditional stock decrements) then fans the new tally out to every connected client in the session via `execute-api:ManageConnections`. Stale `410 Gone` connections are pruned on the fly and idle connections auto-expire through a DynamoDB TTL. No servers, VPCs, load balancers, or provisioned capacity to manage — the stack scales from zero to hundreds of thousands of concurrent connections and costs effectively nothing at rest.

## Architecture

```
                Client A ──┐
                Client B ──┼── same sessionId ──► wss://ccdl4kxqxa…/production
                Client C ──┘  wss:// + ?sessionId=...
                                    │
                                    ▼
        ┌──────────────────────────────────────────────────┐
        │   WebSocket API ccdl4kxqxa (REGIONAL)             │
        │   Route selection: $request.body.action           │
        │   Stage: production (deployment 2ilb0h)            │
        │                                                   │
        │   $connect/$disconnect ──► manage_connections     │
        │   sendVote             ──► handle_vote            │
        │   broadcastResults     ──► broadcast_results      │
        │   liveVote             ──► livestream_vote        │
        │   flashPurchase        ──► flashsale_update       │
        │   designVote           ──► design_vote            │
        └──────────────────────────┬───────────────────────┘
                                   │  AWS_PROXY integration
                                   ▼
        ┌──────────────────────────────────────────────────┐
        │        6 Lambda Functions (Python 3.11)           │
        │  atomic UpdateExpression ADD / conditional writes │
        │  fan-out via execute-api:ManageConnections        │
        └──────────────────────────┬───────────────────────┘
                                   │
        ┌──────────────┬───────────┼────────────┬───────────────┐
        ▼              ▼           ▼            ▼               ▼
   ┌──────────┐  ┌──────────┐ ┌─────────────┐ ┌────────────┐ ┌───────────┐
   │Connections│  │  Polls   │ │ LiveStream  │ │ FlashSale  │ │  Design   │
   │(GSI + TTL)│  │(PK poll) │ │  Sessions   │ │   Items    │ │  Surveys  │
   └──────────┘  └──────────┘ │  (TTL)      │ └────────────┘ └───────────┘
                              └─────────────┘
                                   │
                    ┌──────────────────────────────┐
                    │  Amazon CloudWatch            │
                    │  7 log groups + 7 alarms      │
                    └──────────────────────────────┘
```

Traffic flow: Client opens a WebSocket with a `sessionId` query parameter → API Gateway invokes `manage_connections` on `$connect`, persisting `{connectionId, sessionId, ttl}` → the client's `action` field selects a route → the matched Lambda atomically updates the scenario table → the Lambda queries the Connections `sessionId-index` GSI for every active connection in the session and pushes the new tally to each via `PostToConnection` → stale `410 Gone` connections are deleted.

## Technology Stack

| Layer | Technology | Purpose |
|---|---|---|
| **Real-time API** | Amazon API Gateway WebSocket API (Regional) | Single `wss://` backbone; `$request.body.action` route selection; 7 routes; JSON access logs; auto-deploy stage |
| **Compute** | AWS Lambda (Python 3.11, 256 MB, 10 s) | 6 functions sharing one deployment zip; atomic writes + fan-out; stdlib + boto3 only |
| **Database** | Amazon DynamoDB (On-Demand) | 5 tables; atomic `ADD` increments; conditional stock decrements; Connections GSI + 2 TTLs; PITR |
| **Fan-out** | `execute-api:ManageConnections` | `PostToConnection` to every session connection; `410 Gone` pruning |
| **IaC** | Terraform >= 1.9 (AWS + archive providers) | 50 resources; `archive_file` bundles the whole `lambda/` directory at apply time |
| **IAM** | 1 execution role + 3 inline policies | Scoped to the 5 tables + GSI, the stage's `@connections/*`, and `/aws/lambda/realtime-polling-*` logs |
| **Observability** | CloudWatch Logs (7 log groups) + 7 metric alarms | 6 Lambda error alarms + 1 API integration-error alarm |

## Key Achievements

- **Live end-to-end fan-out verified** — two WebSocket clients on the same `sessionId=session_e2e`: Client A drove all four scenarios and both clients received every broadcast, proving real-time fan-out through the Connections `sessionId-index` GSI — **8 / 8 live fan-out checks PASS** (Client A received 4 broadcasts, Client B received 4 broadcasts)
- **No oversell under concurrency, proven live** — 8 buyers in isolated sessions fired `flashPurchase` concurrently against an item with 4 units of stock; exactly 4 purchases succeeded, the 4 losing buyers each received `sold_out`, and final state was `remainingStock=0, purchaseCount=4, status=sold_out` — DynamoDB's `ConditionExpression: remainingStock > :zero` serialised decrements at the item level so stock never went negative
- **Lost-update-free vote tallies** — poll, live, and design votes use `UpdateExpression: ADD votes.#k :one`, correct regardless of how many Lambdas run concurrently; verified `voteCounts["Product A"] == 1`, `votes["design_02"] == 1`, and poll `votes["yes"] == 1`
- **Single shared Lambda zip** — the whole `lambda/` directory is zipped once so the `_broadcast.py` fan-out helper is importable across all six handlers, avoiding duplicate code and giving one `source_code_hash` that redeploys every function together
- **Two-way stale-connection cleanup** — `$disconnect` deletes the connection record; missed disconnects are pruned either by the `410 Gone` response during fan-out or by the 2-hour Connections TTL
- **Least-privilege IAM with no `*` resources** — 3 inline policies scoped to the 5 tables + GSI, the stage's `@connections/*`, and the `realtime-polling-*` log groups
- **24-check architecture validation suite** — verifies every resource class across state, DynamoDB, Lambda, IAM, API Gateway, and CloudWatch — **24 PASS / 0 WARN / 0 FAIL**

## Infrastructure Components

| Component | Count | Details |
|---|---|---|
| **WebSocket API** | 1 | `realtime-polling-ws-api` (`ccdl4kxqxa`), Regional, route selection `$request.body.action` |
| **Stage** | 1 | `production` (deployment `2ilb0h`), auto-deploy, access logs, 10k/5k throttle |
| **Routes** | 7 | `$connect`, `$disconnect`, `sendVote`, `broadcastResults`, `liveVote`, `flashPurchase`, `designVote` |
| **Integrations** | 6 | One `AWS_PROXY` (CONVERT_TO_TEXT) integration per Lambda |
| **Lambda Functions** | 6 | `realtime-polling-{manage_connections, handle_vote, broadcast_results, livestream_vote, flashsale_update, design_vote}`, Python 3.11, 256 MB, 10 s, shared zip |
| **DynamoDB Tables** | 5 | `polls`, `connections` (GSI `sessionId-index` + TTL on `ttl`), `livestream-sessions` (TTL on `expiresAt`), `flashsale-items`, `design-surveys`; PITR on 4 |
| **IAM Role** | 1 | `realtime-polling-lambda-exec` with 3 inline policies |
| **IAM Inline Policies** | 3 | `lambda-dynamodb` (5 tables + GSI), `lambda-manage-connections` (`execute-api:ManageConnections`), `lambda-logs` |
| **CloudWatch Log Groups** | 7 | 6 × `/aws/lambda/realtime-polling-*` + `/aws/apigateway/realtime-polling-ws`, 30-day retention |
| **CloudWatch Alarms** | 7 | 6 × Lambda `Errors >= 5` + `realtime-polling-ws-integration-errors` (`IntegrationError >= 10`) |

## Deployment Issues Diagnosed & Resolved

| Issue | Root Cause | Fix Applied |
|---|---|---|
| Fan-out must find every connection in a session on every message | A `Scan` reads the whole Connections table each time — slow and costly as connections grow | Add a `sessionId-index` GSI with `projection_type = ALL`, turning fan-out into one `Query` with no follow-up `GetItem` |
| `_broadcast.py` helper not importable from every handler | Six separate deployment packages would each need a copy of the shared fan-out code | Zip the whole `lambda/` directory once and point each `aws_lambda_function` at a distinct `handler` entrypoint |
| Flash sale could oversell under a purchase stampede | Concurrent unconditional decrements can drive `remainingStock` negative | Decrement under `ConditionExpression: remainingStock > :zero`; losers get `ConditionalCheckFailedException` → `sold_out` to that buyer only |
| Votes could still land after a session/survey closed | No guard on write once status flips | Gate live/design votes with `ConditionExpression: #status = :active/:open` so writes are rejected on a closed session |
| Dead connections linger after a missed `$disconnect` | Network drops mean `$disconnect` is not always delivered | Prune two ways — `410 Gone` during fan-out triggers `DeleteItem`, and a 2-hour `ttl` attribute expires idle records |
| Source scenario region differed from the portfolio standard | Scenario doc used `ap-southeast-1` | Deploy to `us-east-1` via the `aws_region` variable, retunable without code changes |

## Test Results

| Test Category | Checks | Status |
|---|---|---|
| Terraform state (52 resources incl. data sources) | 1 | PASS |
| DynamoDB (5 tables + GSI + 2 TTLs) | 8 | PASS |
| Lambda functions (6 Active) | 6 | PASS |
| IAM role + 3 inline policies | 2 | PASS |
| WebSocket API (protocol, route selection, 7 routes, stage) | 4 | PASS |
| CloudWatch (alarms count, no ALARM state, 6 log groups) | 3 | PASS |
| **Total** | **24** | **24 PASS / 0 WARN / 0 FAIL** |

> In addition to the 24 architecture checks, a live end-to-end run recorded **8 / 8 fan-out checks PASS** across all four scenarios, and a concurrency run recorded **3 / 3 no-oversell checks PASS** under 8-way contention against 4 units of stock.

## Quick Start

```bash
cd "Real-time Polling App/terraform"
terraform init
terraform apply

# Capture the WebSocket URL
WS_URL=$(terraform output -raw websocket_url)

# Seed a live-stream session so liveVote has an active session to update
aws dynamodb put-item --table-name realtime-polling-livestream-sessions --item '{
  "sessionId":{"S":"session_001"},
  "productOptions":{"L":[{"S":"Product A"},{"S":"Product B"}]},
  "voteCounts":{"M":{}},
  "status":{"S":"active"},
  "expiresAt":{"N":"'$(($(date +%s)+7200))'"}
}'

# Connect and vote (separate terminal)
wscat -c "${WS_URL}?sessionId=session_001"
> {"action":"liveVote","sessionId":"session_001","productId":"Product A"}

# Validate the deployed architecture
cd .. && bash scripts/test_architecture.sh
```

## Cost Estimate

Assumes a moderate event: 10,000 concurrent viewers, 30-minute session, ~500k messages.

| Resource | Quantity | Monthly Cost (USD) |
|---|---|---|
| API Gateway WebSocket — messages | 500k messages | ~$0.50 |
| API Gateway WebSocket — connection minutes | 10k × 30 min = 300k min | ~$0.08 |
| Lambda | ~500k invocations × 60 ms × 256 MB | ~$0.20 |
| DynamoDB on-demand | ~1M writes + 500k reads | ~$1.50 |
| CloudWatch Logs + 7 alarms | ~1 GB ingest + alarms | ~$2.60 |
| **Total (per event of this size)** | | **~$4.88** |

At rest (no traffic) the stack costs ~$0.70/month (7 alarms only). [AWS Pricing Calculator](https://calculator.aws/)

## Security Posture

| Topic | Posture |
|---|---|
| Connection auth | `$connect` is open — production should add a Lambda authorizer validating a JWT/API key before storing the connection |
| Session ownership | `sessionId` is client-supplied — derive it from an authenticated identity to stop clients joining arbitrary sessions |
| IAM | Least-privilege — 3 inline policies scoped to the 5 tables + GSI, the stage's `@connections/*`, and `realtime-polling-*` log groups; no `*` resources |
| Vote integrity | Conditional writes prevent closed-session votes and overselling; per-connection rate limiting recommended to stop vote spamming |
| Throttling | 10k steady / 5k burst at the stage; lower per-stage limits for public deployments |
| Encryption | DynamoDB AWS-managed keys (default) + AWS-managed TLS on all hops; switch to a customer-managed KMS key for compliance |
| Data trace | `data_trace_enabled = false` — kept off in prod to avoid logging full message bodies |

## Project Structure

```
Real-time Polling App/
├── README.md
├── Result.md                          # Live audit output
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
    └── test_architecture.sh            # 24-check architecture validation
```

## Key Learnings & Technical Decisions

**One WebSocket backbone for four scenarios:** Rather than four separate APIs, a single WebSocket API selects routes on `$request.body.action`, so one persistent connection carries general polls plus all three e-commerce scenarios. Session scoping through a `sessionId` query parameter — stored on `$connect` — lets any number of clients share a live tally, and the fan-out logic is identical regardless of which scenario a message targets.

**GSI-driven fan-out instead of a scan:** Every message must locate all connections in a session. A `Scan` would read the entire Connections table each time; the `sessionId-index` GSI with `projection_type = ALL` turns that into a single `Query` returning only the session's connections, with no follow-up `GetItem`. This GSI is the hot path — every broadcast queries it — so the projection choice directly bounds per-message latency and cost.

**Correctness under concurrency lives in DynamoDB, not the Lambda:** Vote tallies use atomic `ADD` so concurrent increments never lose an update, and flash-sale purchases use `ConditionExpression: remainingStock > :zero` so the item-level condition serialises decrements and stock can never go negative. The live 8-way concurrency test proved this: exactly 4 of 8 purchases succeeded against 4 units, and the 4 losers each received `sold_out`. The Lambdas stay stateless and the database enforces the invariants.

**Single shared zip, six handlers:** All handlers import `_broadcast.py`, so zipping the whole `lambda/` directory once and pointing each `aws_lambda_function` at a different `handler` keeps the helper importable everywhere, avoids duplicated fan-out code, and gives a single `source_code_hash` that redeploys all functions together when any handler changes.

## What I'd Do Differently

- Add a `$connect` Lambda authorizer validating a JWT or API key, and derive `sessionId` from the authenticated identity so clients cannot join arbitrary sessions.
- Batch `PostToConnection` calls or shard sessions for very large audiences (10k+ viewers) to keep fan-out inside the Lambda timeout.
- Add per-connection rate limiting to stop a single client from spamming votes.
- Switch DynamoDB to a customer-managed KMS key and add a custom domain (`aws_apigatewayv2_domain_name` + ACM) for a branded `wss://` hostname.
- Emit fan-out fan-count and per-scenario custom metrics to CloudWatch for richer dashboards beyond the error alarms.

## Summary

This project demonstrates a fully serverless, real-time interaction platform — one WebSocket backbone powering general polls plus three e-commerce scenarios (live-stream voting, flash-sale inventory, design surveys) — with production-relevant concerns handled throughout: GSI-driven fan-out, atomic and conditional DynamoDB writes for lost-update-free tallies and no-oversell guarantees, two-way stale-connection cleanup, least-privilege IAM with no wildcard resources, and CloudWatch observability across every function. Total Terraform resource count: 50. Test coverage: 24 architecture checks (24 PASS / 0 WARN / 0 FAIL), plus 8 / 8 live fan-out checks and 3 / 3 no-oversell concurrency checks. Verified live: two clients received every broadcast across all four scenarios, and 8-way concurrent purchases against 4 units of stock produced exactly 4 sales with zero oversell.
