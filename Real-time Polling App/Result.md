# Deployment Result — Real-time Polling App (E-Commerce Edition)

**Date:** 2026-06-27
**Region:** us-east-1
**Account:** 022499047467
**Environment:** dev
**Terraform resources:** 50

---

## All AWS Resources Created

| Resource | Name / ID | Details |
|---|---|---|
| **WebSocket API** | `realtime-polling-ws-api` / `ccdl4kxqxa` | Protocol `WEBSOCKET`, route selection `$request.body.action` |
| **Stage** | `production` / deployment `2ilb0h` | Auto-deploy; access logs enabled; 10k/5k throttle |
| **Routes (7)** | `$connect`, `$disconnect`, `sendVote`, `broadcastResults`, `liveVote`, `flashPurchase`, `designVote` | All AWS_PROXY → Lambda |
| **Integrations (6)** | One per Lambda function | `AWS_PROXY`, CONVERT_TO_TEXT |
| **Lambda (6)** | `realtime-polling-{manage_connections, handle_vote, broadcast_results, livestream_vote, flashsale_update, design_vote}` | Python 3.11, 256 MB, 10 s, shared zip |
| **DynamoDB — Polls** | `realtime-polling-polls` | PK `pollId`, PITR |
| **DynamoDB — Connections** | `realtime-polling-connections` / `13ec1aa0-d193-4de0-a631-d963bcfe7725` | PK `connectionId`, GSI `sessionId-index`, TTL on `ttl` |
| **DynamoDB — LiveStreamSessions** | `realtime-polling-livestream-sessions` | PK `sessionId`, TTL on `expiresAt`, PITR |
| **DynamoDB — FlashSaleItems** | `realtime-polling-flashsale-items` | PK `itemId`, PITR |
| **DynamoDB — DesignSurveys** | `realtime-polling-design-surveys` | PK `surveyId`, PITR |
| **IAM Role** | `realtime-polling-lambda-exec` | 3 inline policies |
| **IAM Policies (3)** | `lambda-dynamodb`, `lambda-manage-connections`, `lambda-logs` | Least-privilege |
| **CloudWatch Log Groups (7)** | 6 × `/aws/lambda/realtime-polling-*` + `/aws/apigateway/realtime-polling-ws` | 30-day retention |
| **CloudWatch Alarms (7)** | 6 × Lambda errors + `realtime-polling-ws-integration-errors` | Thresholds 5 / 10 |

---

## Key Outputs

| Output | Value |
|---|---|
| `websocket_url` | `wss://ccdl4kxqxa.execute-api.us-east-1.amazonaws.com/production` |
| `websocket_management_endpoint` | `https://ccdl4kxqxa.execute-api.us-east-1.amazonaws.com/production` |
| `api_id` | `ccdl4kxqxa` |
| `stage_name` | `production` |
| `connections_gsi` | `sessionId-index` |
| `dynamodb_tables` | polls, connections, livestream-sessions, flashsale-items, design-surveys |

---

## Architecture Overview

```
                Client A ──┐
                Client B ──┼── same sessionId ──► wss://ccdl4kxqxa…/production
                Client C ──┘
                                    │
                                    ▼
        ┌──────────────────────────────────────────────────┐
        │   WebSocket API ccdl4kxqxa (REGIONAL)            │
        │   Route selection: $request.body.action          │
        │   Stage: production (deployment 2ilb0h)           │
        │                                                  │
        │   $connect/$disconnect ──► manage_connections    │
        │   sendVote             ──► handle_vote           │
        │   broadcastResults     ──► broadcast_results     │
        │   liveVote             ──► livestream_vote       │
        │   flashPurchase        ──► flashsale_update      │
        │   designVote           ──► design_vote           │
        └──────────────────────────┬───────────────────────┘
                                   │  AWS_PROXY
                                   ▼
              6 Lambda (Python 3.11) ── atomic ADD / conditional writes
                                   │
              Query Connections GSI (sessionId-index) ─► PostToConnection ×N
                                   │
        ┌──────────────┬───────────┼────────────┬───────────────┐
        ▼              ▼           ▼            ▼               ▼
   Connections     Polls   LiveStreamSessions FlashSaleItems DesignSurveys
   (GSI + TTL)             (TTL)
                                   │
                          CloudWatch: 7 log groups + 7 alarms
```

---

## Implementation Result — Live End-to-End Test

Two WebSocket clients (A and B) connected on the same `sessionId=session_e2e`.
Client A drove all four scenarios; **both clients received every broadcast**,
proving real-time fan-out through the Connections `sessionId-index` GSI.

| Check | Result |
|---|---|
| Scenario 1: `liveVote` fanned out to BOTH clients | PASS |
| Scenario 1: `voteCounts["Product A"]` == 1 | PASS |
| Scenario 2: `flashPurchase` fanned out to BOTH clients | PASS |
| Scenario 2: `remainingStock` == 4 after one purchase | PASS |
| Scenario 3: `designVote` fanned out to BOTH clients | PASS |
| Scenario 3: `votes["design_02"]` == 1 | PASS |
| Original: `broadcastResults` reached BOTH clients | PASS |
| Original: poll `votes["yes"]` == 1 | PASS |

**Result: 8 / 8 live fan-out checks PASS.** Client A received 4 broadcasts, Client B received 4 broadcasts.

---

## Concurrency Test — No Oversell Under Load

8 buyers (each in an isolated session) fired `flashPurchase` concurrently against
an item with **4 units** of stock.

| Check | Result |
|---|---|
| Exactly 4 purchases succeeded against stock=4 (no oversell) | PASS |
| Remaining 4 buyers each received `sold_out` | PASS |
| Final DynamoDB state: `remainingStock=0, purchaseCount=4, status=sold_out` | PASS |

> The `ConditionExpression: remainingStock > :zero` serialises decrements at the
> item level. Under 8-way concurrency stock never went negative — DynamoDB
> rejected the 4 losing requests, and each received `sold_out` via `post_to_one`.

---

## Architecture Validation Script

`bash scripts/test_architecture.sh` → **24 PASS | 0 WARN | 0 FAIL**

| Section | Checks | Result |
|---|---|---|
| Terraform state (52 resources incl. data sources) | 1 | PASS |
| DynamoDB (5 tables + GSI + 2 TTLs) | 8 | PASS |
| Lambda functions (6 Active) | 6 | PASS |
| IAM role + 3 inline policies | 2 | PASS |
| WebSocket API (protocol, route selection, 7 routes, stage) | 4 | PASS |
| CloudWatch (alarms count, no ALARM state, 6 log groups) | 3 | PASS |

---

## CloudWatch Alarms Status

| Alarm | State | Threshold | Metric |
|---|---|---|---|
| `realtime-polling-manage_connections-errors` | OK / INSUFFICIENT_DATA* | >= 5 | Lambda Errors |
| `realtime-polling-handle_vote-errors` | OK / INSUFFICIENT_DATA* | >= 5 | Lambda Errors |
| `realtime-polling-broadcast_results-errors` | OK / INSUFFICIENT_DATA* | >= 5 | Lambda Errors |
| `realtime-polling-livestream_vote-errors` | OK / INSUFFICIENT_DATA* | >= 5 | Lambda Errors |
| `realtime-polling-flashsale_update-errors` | OK / INSUFFICIENT_DATA* | >= 5 | Lambda Errors |
| `realtime-polling-design_vote-errors` | OK / INSUFFICIENT_DATA* | >= 5 | Lambda Errors |
| `realtime-polling-ws-integration-errors` | OK | >= 10 | API IntegrationError |

> *Immediately after deploy, per-function error alarms report `INSUFFICIENT_DATA`
> until the function emits its first metric datapoint. **No alarm is in ALARM
> state.** After the live tests, functions had executed successfully with zero errors.

---

## Notes

- Region `us-east-1` (portfolio standard; the source scenario doc used `ap-southeast-1` — change the `aws_region` variable to switch).
- Test data seeded during the audit (`session_e2e`, `item_e2e`, `survey_e2e`, `poll_e2e`) lives in the scenario tables and is removed on `terraform destroy`.
- Live WebSocket testing used the `websockets` Python library (no `wscat` present); `wscat` instructions remain in the README Quick Start.
