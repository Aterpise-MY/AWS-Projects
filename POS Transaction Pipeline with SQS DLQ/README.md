# POS Transaction Pipeline with SQS Dead-Letter Queues

Terraform for a retail POS transaction pipeline that guarantees **no transaction disappears silently**. Every completed sale from MekarMart's 180 Malaysian and Singaporean convenience stores is published once to an SNS topic, `pos-transactions`, which fans it out to three independent consumer lanes — loyalty, inventory and e-invoice. Each lane owns a Standard SQS queue, a Lambda consumer, and its own dead-letter queue, so a third-party loyalty outage fills `pos-loyalty-dlq` and leaves stock deduction and tax submission untouched. Messages that fail processing are retried for a sized retry window, then parked in a DLQ where a CloudWatch alarm makes them visible within a minute, a runbook classifies them, and `StartMessageMoveTask` replays them at a controlled rate once the fix is in. A DynamoDB conditional-write idempotency claim is what makes that replay safe: a redriven transaction is awarded points exactly once. A second, subscription-level DLQ (`pos-sns-delivery-dlq`) catches the failure class the per-lane DLQs structurally cannot see — SNS being unable to deliver to a queue at all.

> **Status: authored, `terraform validate`-clean, and NOT deployed.** No AWS resources exist for this project. A read-only `terraform plan` against account `022499047467` reports `Plan: 48 to add, 0 to change, 0 to destroy.` (49 when `ops_alert_email` is set). The 23 unit tests in `lambda/test_handlers.py` run entirely offline with no AWS credentials and cover scenario test cases TC-01 to TC-05; TC-06 (redrive), TC-07 (SNS delivery DLQ) and TC-08 (log traceability) need a live deploy and are pending. Every runtime figure below describes the authored design, not measured behaviour. The stack bills **$0 today**.

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
   180 stores · 2-4 POS terminals each · ~6,000 tx/hour (25,000 at peak)
   simulated by scripts/pos_simulator.py
                      │
                      │ sns:Publish (transaction JSON)
                      ▼
        ┌─────────────────────────────────┐   delivery failure
        │  SNS topic  pos-transactions    │   (queue policy / KMS / queue gone)
        │  Standard · raw message delivery│──────────────────────────┐
        └───────────────┬─────────────────┘                          │
                        │ fan-out                                    ▼
      ┌─────────────────┼─────────────────┐            ┌──────────────────────────┐
      ▼                 ▼                 ▼            │  pos-sns-delivery-dlq    │
┌───────────┐    ┌────────────┐    ┌────────────┐      │  subscription-level DLQ  │
│pos-loyalty│    │pos-inventory│   │pos-einvoice│      └────────────┬─────────────┘
│  -queue   │    │   -queue   │    │   -queue   │                   │
│ 180s vis  │    │ 120s vis   │    │ 360s vis   │                   ▼
└─────┬──┬──┘    └─────┬──┬───┘    └─────┬──┬───┘        pos-sns-delivery-dlq
      │  │ 5x          │  │ 5x           │  │ 8x         -not-empty  (alarm)
      │  ▼             │  ▼              │  ▼
      │ ┌──────────┐   │ ┌────────────┐  │ ┌───────────┐
      │ │ pos-     │   │ │ pos-       │  │ │ pos-      │
      │ │ loyalty  │   │ │ inventory  │  │ │ einvoice  │  14-day retention
      │ │ -dlq     │   │ │ -dlq       │  │ │ -dlq      │  2 alarms each
      │ └────┬─────┘   │ └─────┬──────┘  │ └─────┬─────┘
      ▼      │         ▼       │         ▼       │
┌───────────┐│  ┌────────────┐ │  ┌───────────┐  │
│pos-loyalty││  │pos-inventry│ │  │pos-einvoic│  │   Lambda python3.12
│   -fn     ││  │    -fn     │ │  │   -fn     │  │   ReportBatchItemFailures
│  30s      ││  │   20s      │ │  │   60s     │  │
└─────┬─────┘│  └─────┬──────┘ │  └─────┬─────┘  │
      │      │        │        │        │        │
      └──────┼────────┴────────┼────────┘        │
             │                 │                 │
             ▼                 │                 │
   ┌───────────────────────────▼─────────────────▼──────────┐
   │  DynamoDB  pos-processed-transactions                  │
   │  PK transaction_id · PAY_PER_REQUEST · 7-day TTL       │
   │  conditional PutItem = idempotency claim (R4)          │
   └────────────────────────────────────────────────────────┘

   ──────────────── Monitoring & Operations ────────────────
   7 CloudWatch alarms ──► SNS pos-ops-alerts ──► email (on confirm)
   CloudWatch dashboard  pos-dlq-pipeline  (4 widgets)
   Fix deployed ──► scripts/redrive.sh ──► StartMessageMoveTask (10 msg/s)
                                            └──► back to the source queue
   Poison messages ──► archive to s3://pos-dlq-archive-<account-id>/ ──► purge
```

Traffic flow: a POS terminal publishes one transaction to `pos-transactions` → SNS fans it out to three SQS Standard queues over subscriptions with `raw_message_delivery = true`, so each consumer receives the bare transaction JSON in `record["body"]` → each queue's Lambda event source mapping polls a batch of up to 10 records → the consumer claims each `transaction_id` in DynamoDB with a conditional write, performs its side effect, and returns only the failed `messageId`s in `batchItemFailures` → SQS redelivers just those records after the visibility timeout expires → once a record has been received `maxReceiveCount` times it is moved to that lane's DLQ, where `ApproximateNumberOfMessagesVisible >= 1` fires an alarm to `pos-ops-alerts` within a minute → an on-call engineer follows `docs/runbook-dlq.md` to classify the failure and either redrive it (transient) or archive and purge it (poison). If SNS cannot deliver to a queue at all, the message goes to `pos-sns-delivery-dlq` instead and never touches a source queue.

---

## Networking & Routing

There is no VPC, subnet, route table or load balancer in this project. Every component — SNS, SQS, Lambda, DynamoDB, S3 and CloudWatch — is a regional AWS service reached over AWS-managed endpoints, and the consumers make no outbound calls that would need a NAT Gateway. What takes the place of network routing here is **message routing**: which topic delivers to which queue, which queue dead-letters to which DLQ, and which policies gate each hop.

### Topic → Subscription → Queue

| Topic | Subscription protocol | Endpoint (queue) | Raw message delivery | Subscription DLQ |
|---|---|---|---|---|
| `pos-transactions` | `sqs` | `pos-loyalty-queue` | `true` | `pos-sns-delivery-dlq` |
| `pos-transactions` | `sqs` | `pos-inventory-queue` | `true` | `pos-sns-delivery-dlq` |
| `pos-transactions` | `sqs` | `pos-einvoice-queue` | `true` | `pos-sns-delivery-dlq` |
| `pos-ops-alerts` | `email` | `var.ops_alert_email` | n/a | none (alarm notifications only) |

> `raw_message_delivery = true` means the body Lambda receives is the transaction JSON itself. With it off, SNS wraps the payload in an envelope (`Type`, `MessageId`, `TopicArn`, `Message` as an escaped string) and every consumer would have to unwrap it before parsing.

### Queue → DLQ (redrive policy)

| Source queue | Dead-letter target | `maxReceiveCount` | Visibility timeout | Approx. retry window | Source retention | DLQ retention |
|---|---|---|---|---|---|---|
| `pos-loyalty-queue` | `pos-loyalty-dlq` | 5 | 180 s | ~15 min | 4 days | 14 days |
| `pos-inventory-queue` | `pos-inventory-dlq` | 5 | 120 s | ~10 min | 4 days | 14 days |
| `pos-einvoice-queue` | `pos-einvoice-dlq` | 8 | 360 s | ~48 min | 4 days | 14 days |
| `pos-sns-delivery-dlq` | n/a — terminal queue | n/a | default | n/a | n/a | 14 days |

### DLQ → Queue (redrive allow policy)

| Dead-letter queue | `redrivePermission` | `sourceQueueArns` |
|---|---|---|
| `pos-loyalty-dlq` | `byQueue` | `pos-loyalty-queue` only |
| `pos-inventory-dlq` | `byQueue` | `pos-inventory-queue` only |
| `pos-einvoice-dlq` | `byQueue` | `pos-einvoice-queue` only |

> `byQueue` is the narrowest of the three permissions SQS offers (`allowAll`, `denyAll`, `byQueue`). It makes it impossible to redrive loyalty failures into the inventory queue — a mistake that would be trivially easy to make at 3 a.m. with three similarly named ARNs on screen.

### Queue policy — the `aws:SourceArn` condition

Each source queue and the SNS delivery DLQ carries an identical resource policy shape: allow the `sns.amazonaws.com` service principal to call `sqs:SendMessage` on that one queue ARN, **only** when `aws:SourceArn` equals the `pos-transactions` topic ARN.

| Element | Value |
|---|---|
| **Sid** | `AllowSNSTopicToSendMessage` |
| **Effect** | `Allow` |
| **Principal** | Service `sns.amazonaws.com` |
| **Action** | `sqs:SendMessage` |
| **Resource** | That queue's ARN only |
| **Condition** | `ArnEquals` on `aws:SourceArn` = `arn:aws:sns:ap-southeast-1:022499047467:pos-transactions` |

> Without the condition, any SNS topic in any AWS account could push messages into these queues. With it wrong — or with the policy missing entirely — publishes succeed, SNS reports success, and the queues stay empty. That is the single most common failure on first deploy, and it is what `pos-sns-delivery-dlq` exists to catch.

### Traffic Flow

```
  POS terminal / pos_simulator.py
        │  sns:Publish
        ▼
  ┌──────────────────────┐   queue policy check
  │  pos-transactions    │   aws:SourceArn == this topic?
  └──────────┬───────────┘
             │ no  ──────────────────────────────► pos-sns-delivery-dlq
             │ yes                                   (manual re-publish only —
             ▼                                        StartMessageMoveTask does
  ┌──────────────────────┐                            not work on this queue)
  │  pos-<lane>-queue    │◄────────────────────────────────┐
  │  visibility timeout  │                                 │
  └──────────┬───────────┘                                 │
             │ event source mapping polls batch of 10      │
             ▼                                             │
  ┌──────────────────────┐                                 │
  │  pos-<lane>-fn       │  claim → side effect → log      │
  └──────────┬───────────┘                                 │
             │                                             │
    success  │  failure (batchItemFailures)                │
      ▼      ▼                                             │
  deleted   message returns after visibility timeout       │
             │  receive count += 1                         │
             ▼                                             │
      count < maxReceiveCount ? ──yes──► retry ────────────┘
             │ no                                          ▲
             ▼                                             │
  ┌──────────────────────┐                                 │
  │  pos-<lane>-dlq      │  alarm ──► pos-ops-alerts       │
  └──────────┬───────────┘                                 │
             │ triage (docs/runbook-dlq.md)                │
             ├── transient ──► StartMessageMoveTask ───────┘  redrive, 10 msg/s
             └── poison ─────► S3 archive ──► purge
```

---

## Component Details

### 1. SNS topics

| Attribute | `pos-transactions` | `pos-ops-alerts` |
|---|---|---|
| **Terraform resource** | `aws_sns_topic.pos_transactions` | `aws_sns_topic.ops_alerts` |
| **Type** | Standard | Standard |
| **Display name** | `MekarMart POS transactions` | `POS pipeline ops alerts` |
| **Subscribers** | 3 SQS queues (raw delivery) | 0 by default; 1 email when `ops_alert_email` is set |
| **Publishers** | POS terminals / `scripts/pos_simulator.py` | 7 CloudWatch alarms (`alarm_actions` and `ok_actions`) |
| **Tags** | `Role = transaction-fanout` | `Role = ops-alerting` |

> Standard, not FIFO, on purpose. AWS documents that attaching a DLQ to a FIFO queue breaks the exact-ordering guarantee: once a message is moved out of a message group, the following messages in that group continue to be delivered. POS transactions have no ordering dependency between them, so Standard queues plus DynamoDB idempotency is the stronger trade.

### 2. The `consumer_queue` module

One module call produces a complete, isolated downstream lane. Onboarding a fourth service is a ten-line `module` block, not a copy-paste of a dozen resources.

| Attribute | Value |
|---|---|
| **Path** | `terraform/modules/consumer_queue/` |
| **Calls** | 3 — `module.loyalty`, `module.inventory`, `module.einvoice` |
| **Resources per call** | 12 (DLQ, source queue, redrive allow policy, queue policy, SNS subscription, log group, IAM role, IAM role policy, Lambda function, event source mapping, 2 alarms) |
| **Naming** | `<name_prefix>-<name>-queue` / `-dlq` / `-fn`, from `local.base_name` |
| **Per-lane inputs** | `lambda_timeout`, `visibility_timeout`, `max_receive_count`, `lambda_handler`, `extra_environment` |
| **Shared inputs** | `sns_topic_arn`, `sns_delivery_dlq_arn`, `alarm_topic_arn`, `dynamodb_table_name` / `_arn`, retention and batch settings |
| **Guardrails** | `lifecycle { precondition }` on the source queue (`visibility_timeout >= 6 * lambda_timeout`); variable validation on `max_receive_count` (>= 5 and <= 1000) |

### 3. SQS source queues

| Attribute | `pos-loyalty-queue` | `pos-inventory-queue` | `pos-einvoice-queue` |
|---|---|---|---|
| **Type** | Standard | Standard | Standard |
| **Visibility timeout** | 180 s | 120 s | 360 s |
| **Consumer timeout** | 30 s | 20 s | 60 s |
| **Ratio** | 6× | 6× | 6× |
| **`maxReceiveCount`** | 5 | 5 | 8 |
| **Retry window** | ~15 min | ~10 min | ~48 min |
| **Retention** | 4 days (`345600` s) | 4 days | 4 days |
| **Encryption** | SSE-SQS (`sqs_managed_sse_enabled`) | SSE-SQS | SSE-SQS |
| **Tags** | `QueueRole = source`, `RetryWindowSeconds = 900` | `... = 600` | `... = 2880` |

> e-Invoice is the only lane that deviates from `maxReceiveCount = 5`, and the reason matters: the tax authority API is rate-limited and answers HTTP 429 under load. A 429 is purely transient and *will* succeed once the token bucket refills, so extra receives are cheap and correct there. Applying 8 to the loyalty lane would mean every firmware v2.3 poison message wasted 8 invocations instead of 5.

### 4. Dead-letter queues, redrive policy and redrive allow policy

| Attribute | Value |
|---|---|
| **Queues** | `pos-loyalty-dlq`, `pos-inventory-dlq`, `pos-einvoice-dlq`, `pos-sns-delivery-dlq` |
| **Retention** | 14 days (`1209600` s — the SQS maximum) on all four |
| **Encryption** | SSE-SQS on all four |
| **Redrive policy** | Set on the *source* queue: `{ deadLetterTargetArn, maxReceiveCount }` |
| **Redrive allow policy** | Set on the *DLQ*, as a standalone `aws_sqs_queue_redrive_allow_policy` resource: `{ redrivePermission = "byQueue", sourceQueueArns = [<its own source queue>] }` |
| **Constraints** | A DLQ must be in the same account and region, and of the same type (Standard here), as its source queue |
| **Replay** | `aws sqs start-message-move-task`, rate-limited to 10 messages/second by `scripts/redrive.sh` |

> The redrive allow policy is a separate resource rather than an inline `redrive_allow_policy` argument on `aws_sqs_queue.dlq` for a concrete reason: the source queue references the DLQ ARN and the allow policy references the source queue ARN, so inlining both would make the two `aws_sqs_queue` resources reference each other and Terraform would refuse the graph with a dependency cycle. Splitting it out linearises the graph to `dlq → source → allow_policy`.

> `pos-sns-delivery-dlq` is a terminal queue with no redrive policy and no allow policy. `StartMessageMoveTask` cannot replay it, because its messages never had an SQS source queue to move back to — they failed at the SNS layer. Recovery is a manual archive-and-re-publish, documented as Path C in the runbook.

### 5. Queue policies

| Attribute | Value |
|---|---|
| **Terraform resources** | `aws_sqs_queue_policy.source` (per lane) and `aws_sqs_queue_policy.sns_delivery_dlq` |
| **Built from** | `data.aws_iam_policy_document` — no hand-written JSON strings |
| **Grants** | `sqs:SendMessage` to `sns.amazonaws.com` on exactly one queue ARN |
| **Condition** | `ArnEquals` `aws:SourceArn` = the `pos-transactions` topic ARN |
| **DLQ policies** | None — the consumer DLQs are written only by SQS itself during a dead-letter move, which needs no resource policy |
| **Ordering** | `aws_sns_topic_subscription.this` has `depends_on = [aws_sqs_queue_policy.source]`, so SNS never starts delivering before the policy exists |

### 6. Lambda consumers

| Attribute | `pos-loyalty-fn` | `pos-inventory-fn` | `pos-einvoice-fn` |
|---|---|---|---|
| **Runtime** | `python3.12` | `python3.12` | `python3.12` |
| **Handler** | `loyalty/handler.lambda_handler` | `inventory/handler.lambda_handler` | `einvoice/handler.lambda_handler` |
| **Memory** | 256 MB | 256 MB | 256 MB |
| **Timeout** | 30 s | 20 s | 60 s |
| **Side effect** | Award points (1 per whole currency unit) | Deduct stock per SKU | Submit the e-invoice |
| **Extra validation** | none | Negative `qty` is a permanent failure — it would *inflate* stock | none |
| **Drill switch** | `LOYALTY_API_DOWN` (simulates a 503) | none | `EINVOICE_THROTTLE_RATE` (simulates 429s) |
| **Log group** | `/aws/lambda/pos-loyalty-fn`, 14-day retention | `/aws/lambda/pos-inventory-fn` | `/aws/lambda/pos-einvoice-fn` |
| **Package** | `data.archive_file` zips the whole `lambda/` tree to `.build/<function>.zip` | same | same |

All three share `lambda/common/` — `errors.py` (the `TransientError` / `PermanentError` taxonomy), `idempotency.py` (claim and release) and `processing.py` (the per-record batch loop, shared validation, and one structured JSON log line per record). The whole tree is zipped, not just the per-lane directory, so `import common` resolves the same way in Lambda as it does under `python3 -m unittest`; `test_handlers.py` and `__pycache__` are excluded so `source_code_hash` stays deterministic across machines.

> The 2026 incident was caused by a `try/except` that swallowed a loyalty API timeout and let SQS delete the message. Here the taxonomy makes that impossible to write by accident: both error classes report the record as a batch item failure. A `PermanentError` is not "handled" — it is deliberately failed, so SQS parks it in a DLQ where a human can see it. Visible failure is the goal, not success.

### 7. Event source mappings — partial batch responses

| Attribute | Value |
|---|---|
| **Terraform resource** | `aws_lambda_event_source_mapping.this` (one per lane) |
| **Event source** | That lane's source queue ARN |
| **Batch size** | 10 (`var.batch_size`) |
| **`function_response_types`** | `["ReportBatchItemFailures"]` |
| **Enabled** | `true` |
| **Contract** | The handler returns `{"batchItemFailures": [{"itemIdentifier": "<messageId>"}, ...]}` |
| **Requirement served** | R2 — one poison transaction must not drag down the other nine in its batch |

> Without `ReportBatchItemFailures`, a single bad record makes the whole invocation fail, so SQS redelivers all ten. The nine good transactions are reprocessed on every retry — inflating their receive counts toward the same DLQ threshold and, absent idempotency, awarding points repeatedly. This is also why Lambda requires the function timeout to be no greater than the queue's visibility timeout, and refuses to create the mapping otherwise.

### 8. DynamoDB idempotency table

| Attribute | Value |
|---|---|
| **Name** | `pos-processed-transactions` |
| **Partition key** | `transaction_id` (String) |
| **Billing mode** | `PAY_PER_REQUEST` — the workload swings from ~6,000 tx/hour to ~25,000 tx/hour at Chinese New Year and 11.11 |
| **TTL attribute** | `expires_at`, enabled; consumers write now + 7 days (`var.idempotency_ttl_days`) |
| **Item shape** | `transaction_id`, `service`, `processed_at` (ISO-8601 UTC), `expires_at` (epoch seconds) |
| **Claim** | `PutItem` with `ConditionExpression = attribute_not_exists(transaction_id)` |
| **Release** | `DeleteItem`, called when the side effect fails after the claim was taken |
| **Duplicate signal** | `ConditionalCheckFailedException` → log `duplicate_skipped` and report success |
| **PITR** | Disabled (lab) |

> The claim is taken **before** the side effect, never after. A claim taken afterwards leaves a window in which the function dies between the two, and the retry double-awards. The release is the other half: without it, attempt 1 claims the transaction, the loyalty API 503s, attempt 2 sees the existing claim, logs `duplicate_skipped`, reports success, and SQS deletes a message whose points were never awarded. That is silent loss wearing a success badge — which is why `dynamodb:DeleteItem` is in the execution role and not treated as optional.

### 9. CloudWatch alarms

Seven alarms, all publishing to `pos-ops-alerts` on both `alarm_actions` and `ok_actions`, all with `treat_missing_data = "notBreaching"`.

| Alarm | Metric | Statistic | Period | Eval periods | Threshold | Purpose |
|---|---|---|---|---|---|---|
| `pos-loyalty-dlq-not-empty` | `ApproximateNumberOfMessagesVisible` | `Maximum` | 60 s | 1 | `>= 1` | R3 — notify on the first parked message |
| `pos-inventory-dlq-not-empty` | `ApproximateNumberOfMessagesVisible` | `Maximum` | 60 s | 1 | `>= 1` | R3 |
| `pos-einvoice-dlq-not-empty` | `ApproximateNumberOfMessagesVisible` | `Maximum` | 60 s | 1 | `>= 1` | R3 |
| `pos-loyalty-dlq-message-aging` | `ApproximateAgeOfOldestMessage` | `Maximum` | 300 s | 1 | `> 604800` (7 d) | Second chance before the 14-day cliff |
| `pos-inventory-dlq-message-aging` | `ApproximateAgeOfOldestMessage` | `Maximum` | 300 s | 1 | `> 604800` | Second chance |
| `pos-einvoice-dlq-message-aging` | `ApproximateAgeOfOldestMessage` | `Maximum` | 300 s | 1 | `> 604800` | Second chance |
| `pos-sns-delivery-dlq-not-empty` | `ApproximateNumberOfMessagesVisible` | `Maximum` | 60 s | 1 | `>= 1` | R1 / TC-07 — SNS could not deliver at all |

> Alarming on `ApproximateNumberOfMessagesVisible` (a gauge) rather than `NumberOfMessagesSent` (a count) is deliberate. The gauge keeps the alarm in ALARM for as long as the DLQ is non-empty and only returns to OK once the backlog is actually drained or redriven. A count-based alarm self-clears after one quiet period while the messages are still sitting there unhandled.

> `treat_missing_data = "notBreaching"` matters more than it looks: SQS only publishes queue metrics while a queue is active, so a healthy, permanently empty DLQ emits nothing and the default treatment would leave every alarm stuck in `INSUFFICIENT_DATA` rather than a clean `OK`.

> `pos-sns-delivery-dlq-not-empty` is arguably the highest-severity alarm here. A consumer DLQ means one message failed. This one means an entire fan-out leg may be dropping 100% of its traffic while the lane still looks healthy — its queue is simply empty, and an empty queue raises nothing.

### 10. CloudWatch dashboard

| Attribute | Value |
|---|---|
| **Name** | `pos-dlq-pipeline` |
| **Widget 1** | Source queue backlog — `ApproximateNumberOfMessagesVisible` for all three source queues, 60 s, `Maximum` |
| **Widget 2** | DLQ depth — same metric for all three DLQs, annotated at the alarm threshold of 1 (`fill: above`) |
| **Widget 3** | Consumer health — Lambda `Errors` (red) plotted against `Invocations` (blue) for all three functions, 60 s, `Sum` |
| **Widget 4** | `ApproximateAgeOfOldestMessage` per DLQ, 300 s, annotated at 7 days (alarm) and 14 days (SQS deletes the message) |
| **Lane order** | Fixed as loyalty, inventory, e-invoice via `local.lane_order`, so the dashboard JSON and the plan diff are stable across runs |

> Widget 3 plots errors against invocations so a spike reads as a *rate*: 50 errors out of 50 invocations is an outage, 50 out of 25,000 is a handful of poison messages. Widget 1 answers the other on-call question — all three lanes rising means the publisher is outrunning the consumers, one lane rising means that downstream is degraded.

### 11. IAM roles

One execution role per consumer, `pos-<lane>-fn-role`, each with a single inline policy and no AWS managed policies attached.

| Sid | Actions | Resource |
|---|---|---|
| `ConsumeSourceQueue` | `sqs:ReceiveMessage`, `sqs:DeleteMessage`, `sqs:GetQueueAttributes`, `sqs:ChangeMessageVisibility` | That lane's source queue ARN only |
| `IdempotencyClaimAndRelease` | `dynamodb:PutItem`, `dynamodb:DeleteItem` | `pos-processed-transactions` ARN only |
| `WriteOwnLogs` | `logs:CreateLogStream`, `logs:PutLogEvents` | `<that function's log group ARN>:*` |

> `AWSLambdaBasicExecutionRole` and `AWSLambdaSQSQueueExecutionRole` are deliberately not used — both grant `Resource: "*"`. The only wildcard here is the `:*` log-stream suffix, which CloudWatch Logs requires because stream names are generated per execution environment. `logs:CreateLogGroup` is omitted because Terraform creates the group; `dynamodb:GetItem` is omitted because the conditional `PutItem` *is* the read-and-test; `dynamodb:UpdateItem` is omitted because claims are only created and deleted, never mutated.

### 12. S3 poison-message archive

| Attribute | Value |
|---|---|
| **Bucket** | `pos-dlq-archive-<account-id>` (the account ID keeps the globally unique name collision-free) |
| **Versioning** | Enabled — an operator running Path B twice for the same service on the same day cannot overwrite the first archive |
| **Encryption** | SSE-S3 (`AES256`) — archived bodies contain member IDs and basket contents |
| **Public access** | All four block settings `true` |
| **Lifecycle** | Objects expire at 90 days; noncurrent versions expire at 90 days; incomplete multipart uploads aborted after 7 days |
| **Written by** | A human operator with their own credentials, following runbook Path B |
| **Lambda access** | None — no consumer role grants anything on this bucket |

> Deleting a DLQ message is irreversible, and the body is the only evidence of which store, terminal and firmware version produced the bad transaction — exactly what Store Ops needs to scope a firmware upgrade. Archiving first is what makes "purge" a safe operation rather than a second silent loss. Consumers are given no access on purpose: a compromised or buggy function must not be able to tamper with the evidence trail it is supposed to preserve.

---

## Directory Structure

```
POS Transaction Pipeline with SQS DLQ/
├── README.md                             # This file
├── Enterprise_DLQ_Scenario_POS_EN.md     # Approved enterprise scenario (MekarMart, 180 stores)
├── .gitignore                            # Excludes state, .tfvars, .build/, __pycache__, .env
├── terraform/
│   ├── providers.tf                      # AWS ~> 5.0 + archive ~> 2.4, ap-southeast-1, default_tags
│   ├── variables.tf                      # 11 root inputs with validation
│   ├── sns.tf                            # pos-transactions, pos-ops-alerts, pos-sns-delivery-dlq + its alarm
│   ├── dynamodb.tf                       # pos-processed-transactions (PK transaction_id, 7-day TTL)
│   ├── s3.tf                             # pos-dlq-archive-<account-id> (versioned, SSE-S3, 90-day lifecycle)
│   ├── consumers.tf                      # Three consumer_queue module calls: loyalty, inventory, einvoice
│   ├── cloudwatch.tf                     # pos-dlq-pipeline dashboard (4 widgets)
│   ├── outputs.tf                        # 17 outputs incl. ready-to-paste redrive commands
│   ├── terraform.tfvars.example          # Every variable, commented, with the reasoning
│   ├── .terraform.lock.hcl               # Pins aws v5.100.0 + archive v2.8.0
│   ├── .gitignore                        # Terraform-specific ignores (state, .build/, *.tfplan)
│   └── modules/
│       └── consumer_queue/               # The reusable lane: queue + DLQ + policies + Lambda + ESM + alarms
│           ├── main.tf                   # 12 resources, in the order they are numbered in comments
│           ├── variables.tf              # 16 inputs; max_receive_count >= 5 validation
│           └── outputs.tf                # Queue/DLQ URLs and ARNs, function name, log group, alarm names
├── lambda/
│   ├── common/
│   │   ├── __init__.py
│   │   ├── errors.py                     # ProcessingError / PermanentError / TransientError taxonomy
│   │   ├── idempotency.py                # claim() conditional PutItem, release() DeleteItem
│   │   └── processing.py                 # Per-record batch loop, shared validation, structured logging
│   ├── loyalty/handler.py                # award_points(); LOYALTY_API_DOWN drill switch
│   ├── inventory/handler.py              # deduct_stock(); negative-qty permanent rule
│   ├── einvoice/handler.py               # submit_einvoice(); deterministic 429 simulation
│   └── test_handlers.py                  # 23 offline unit tests (TC-01 to TC-05)
├── scripts/
│   ├── pos_simulator.py                  # Publishes normal / poison / duplicate / mixed / burst traffic
│   └── redrive.sh                        # StartMessageMoveTask wrapper, rate-limited, with --dry-run
├── docs/
│   └── runbook-dlq.md                    # On-call runbook: triage, Paths A/B/C, verification, known traps
└── .github/
    └── workflows/
        └── terraform.yml                 # validate → unit tests → plan (PR) → apply (main, OIDC)
```

The on-call procedure lives in [`docs/runbook-dlq.md`](docs/runbook-dlq.md): alert reference, the first-five-minutes triage flow, the Logs Insights queries that trace a `transaction_id` across every attempt, Path A (transient → redrive), Path B (poison → archive → purge), Path C (`pos-sns-delivery-dlq`), post-action verification, escalation, and the known traps.

---

## Prerequisites

| Tool | Minimum Version | Install |
|---|---|---|
| **Terraform** | 1.5.0 (authored and validated on 1.15.1) | [developer.hashicorp.com/terraform/install](https://developer.hashicorp.com/terraform/install) |
| **AWS CLI** | 2.0 | [docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html) |
| **Python** | 3.12 (the Lambda runtime; the unit tests run on any 3.x) | [python.org/downloads](https://www.python.org/downloads/) |
| **boto3** | 1.28+ | `pip install boto3` — needed only by `scripts/pos_simulator.py` outside `--dry-run` |
| **jq** | 1.6 | `brew install jq` / `apt install jq` — used by the runbook's triage commands |
| **Bash** | 4+ / macOS `bash` | `scripts/redrive.sh` uses `set -euo pipefail` and process substitution |

**Account requirements:**

- Target account `022499047467`, region `ap-southeast-1`. A DLQ must live in the same account and region as its source queue, so this is a single-region stack by design.
- IAM permissions to create and tag: SNS topics and subscriptions, SQS queues and queue policies, Lambda functions and event source mappings, IAM roles and inline role policies, DynamoDB tables, S3 buckets, CloudWatch log groups, metric alarms and dashboards.
- No VPC, NAT Gateway, EC2, certificate or DNS record is required, and no service quota increase is needed at lab volumes.
- Terraform state is **local** (`terraform/terraform.tfstate`, git-ignored). There is no S3 backend block.

> **`pos-ops-alerts` has no subscriber by default.** `ops_alert_email` defaults to `""`, which skips the subscription entirely — alarms will fire, transition to ALARM, and notify nobody. Set `ops_alert_email` in `terraform.tfvars` **and click the confirmation link AWS emails you** before attempting to demonstrate requirement R3 ("the on-call engineer is notified within 5 minutes"). Until confirmed, the subscription sits in `PendingConfirmation` and delivers nothing. The `ops_alert_email_subscription_pending` output tells you whether a subscription was even created.

> **The GitHub Actions workflow will not run from where it lives.** `.github/workflows/terraform.yml` is kept inside this project folder to match the convention used by the other projects in this portfolio, but GitHub only executes workflows found in the **repository root** `.github/workflows/`. To use it: copy it to the repository root, create the GitHub OIDC identity provider and the IAM role it assumes in account `022499047467`, set the repository variable `AWS_ROLE_ARN` to that role ARN, and create a `production` GitHub environment for the apply gate. Until all four exist, only the `validate` and `test` jobs can succeed — which is intentional, because no long-lived AWS keys are stored in this repository.

---

## Quick Start

```bash
# 1. Run the offline unit tests first — no AWS credentials, no network, ~0.02 s
cd "POS Transaction Pipeline with SQS DLQ"
python3 -m unittest discover lambda           # expect: Ran 23 tests ... OK

# 2. Preview the payloads the simulator will publish, without touching AWS
./scripts/pos_simulator.py --mode mixed --count 10 --dry-run

# 3. Initialise Terraform (local state; downloads aws v5.100.0 + archive v2.8.0)
cd terraform
terraform init

# 4. Set the on-call email so DLQ alarms reach a human (see the caveat above)
cp terraform.tfvars.example terraform.tfvars
#   then uncomment and set:  ops_alert_email = "you@example.com"

# 5. Review the plan. Nothing is deployed today, so expect a full create.
terraform fmt -recursive -check
terraform validate                            # Success! The configuration is valid.
terraform plan                                # Plan: 49 to add, 0 to change, 0 to destroy.
                                              # (48 if ops_alert_email is left empty)

# 6. Deploy — only with explicit approval
terraform apply

# 7. Confirm the SNS subscription from your inbox, then publish 10 normal sales (TC-01)
cd ..
./scripts/pos_simulator.py --mode normal --count 10

# 8. Send one firmware v2.3 poison message and watch it park in the DLQ (TC-02)
./scripts/pos_simulator.py --mode poison --count 1

# 9. Read the DLQ depth and the console links
cd terraform
terraform output -json dlq_depth_commands
terraform output -raw dashboard_url

# 10. After a fix, replay a DLQ at 10 messages/second (TC-06)
cd ..
./scripts/redrive.sh --source-arn "$(cd terraform && terraform output -json consumers \
  | jq -r '.loyalty.dlq_arn')" --dry-run
```

Allow ~2 minutes after `apply` for the three event source mappings to reach `Enabled` and start polling, and a further ~1-2 minutes before SQS and Lambda metrics appear in CloudWatch — SQS publishes queue metrics on roughly a one-minute cadence and only while a queue is active, so a brand-new dashboard looks empty until the first messages flow. A poison message takes `maxReceiveCount × visibility_timeout` to reach its DLQ: about 15 minutes on the loyalty lane, 10 on inventory, 48 on e-invoice.

---

## Input Variables

| Variable | Type | Default | Description |
|---|---|---|---|
| `aws_region` | string | `ap-southeast-1` | Region for every resource. Single-region by design — a DLQ must share its source queue's account and region. |
| `name_prefix` | string | `pos` | Prefix for every resource name. Validated as 2-17 lowercase alphanumeric/hyphen characters starting with a letter. Change it to run a second isolated copy of the stack. |
| `ops_alert_email` | string | `""` | Email subscribed to `pos-ops-alerts`. Empty skips the subscription. Validated as empty or a well-formed address. |
| `loyalty_api_down` | bool | `false` | Phase 4 drill switch. `true` makes the loyalty consumer raise `TransientError("loyalty API returned 503")` on every record. |
| `einvoice_throttle_rate` | number | `0` | Fraction (0.0-1.0) of e-invoice submissions that simulate an HTTP 429. Validated to the inclusive range. |
| `log_retention_days` | number | `14` | Retention for all three consumer log groups. Validated against the exact set CloudWatch Logs accepts. |
| `source_retention_seconds` | number | `345600` (4 days) | Retention on all three source queues. Validated to 60-1209600. |
| `dlq_retention_seconds` | number | `1209600` (14 days) | Retention on all four DLQs. Validated to 60-1209600. |
| `batch_size` | number | `10` | SQS records per Lambda invocation. Kept at 10 so the 9-good-plus-1-poison test fits one batch. Validated to 1-10000. |
| `idempotency_ttl_days` | number | `7` | TTL horizon written into `expires_at`. Exposed as an output for the consumer code. |
| `additional_tags` | map(string) | `{}` | Merged into `default_tags` for every resource — cost-allocation or change-ticket tags without editing `providers.tf`. |

**Cross-variable rules.** Three invariants are enforced rather than documented and hoped for:

| Rule | Where it is enforced | Failure mode it prevents |
|---|---|---|
| `visibility_timeout >= 6 * lambda_timeout` | `lifecycle { precondition }` on `aws_sqs_queue.source` in the module | A retried or throttled invocation outlives the visibility timeout, the message becomes visible again mid-flight, and a second invocation burns a receive on work already in progress |
| `max_receive_count >= 5` (and `<= 1000`) | `validation` block on the module variable | A retry window too short for any real transient failure, sending healthy transactions to the DLQ |
| `dlq_retention_seconds > source_retention_seconds` | Defaults (14 d vs 4 d), plus the reasoning in `variables.tf` and `main.tf` | Standard queues keep the original enqueue timestamp on a dead-letter move, so equal retentions silently shorten the DLQ window by the time already spent in the source queue |

> The per-lane values (`lambda_timeout`, `visibility_timeout`, `max_receive_count`) are not root variables — they are literals in `consumers.tf`, one block per lane, so the three sets of numbers from scenario §5 stay readable side by side instead of being smeared across nine root variables.

---

## Outputs

| Output | Description |
|---|---|
| `pos_transactions_topic_arn` | ARN of the fan-out topic. `scripts/pos_simulator.py` resolves this automatically. |
| `ops_alerts_topic_arn` | ARN of the alerting topic every alarm publishes to |
| `ops_alert_email_subscription_pending` | `true` when an email subscription exists and still needs confirming from the inbox |
| `sns_delivery_dlq_url` | URL of `pos-sns-delivery-dlq` |
| `sns_delivery_dlq_arn` | ARN of `pos-sns-delivery-dlq` |
| `dlq_archive_bucket` | Name of the S3 bucket poison messages are archived into before deletion |
| `idempotency_table_name` | Name of the DynamoDB idempotency table |
| `idempotency_table_arn` | ARN of the idempotency table |
| `idempotency_ttl_days` | TTL horizon consumers write into `expires_at` |
| `dashboard_name` | Name of the CloudWatch dashboard (`pos-dlq-pipeline`) |
| `dashboard_url` | Console deep link to the dashboard |
| `consumers` | Per-service map: source queue URL/ARN/name, DLQ URL/ARN/name, function name, log group, alarm names |
| `redrive_commands` | Per-service ready-to-paste `aws sqs start-message-move-task`, rate-limited to 10 msg/s |
| `redrive_status_commands` | Per-service `aws sqs list-message-move-tasks` for tracking redrive progress |
| `dlq_depth_commands` | Per-service `aws sqs get-queue-attributes` for reading DLQ depth during a drill |
| `account_id` | Account the stack targets — a DLQ must share its source queue's account |
| `region` | Region the stack targets |

```bash
# Usage
terraform output -raw pos_transactions_topic_arn
terraform output -json consumers | jq -r '.loyalty.dlq_url'
terraform output -json redrive_commands | jq -r '.loyalty'
terraform output -json                       # everything
```

---

## Scaling Behaviour

There are no instances, no Auto Scaling groups and no capacity settings here. Lambda scales concurrency on its own, DynamoDB is on-demand, and SQS absorbs any burst. The number that actually has to be "sized" is the **retry window** — how long a downstream service can be unavailable before its transactions are parked in a DLQ. The chart below is the Phase 4 drill: 50 transactions published at T+0 while the loyalty API is down for 20 minutes, which is deliberately longer than the loyalty lane's ~15-minute window.

```
DLQ depth
(pos-loyalty-dlq)
                                    ┌──────────── 50 parked ─────────┐
   50 ┤                             │                                │
      │                             │                                │
   40 ┤                             │                                │
      │                            ╱│                                │
   30 ┤                           ╱ │                                │
      │                          ╱  │                                │
   20 ┤                         ╱   │                                │
      │                        ╱    │                                │
   10 ┤                       ╱     │                                │
      │                      ╱      │                                ▼ redrive
    0 ┼─────────────────────●───────┘                            ────●─────────
      └──┬────┬────┬────┬────┬────┬────┬────┬────┬────┬────┬────┬────┬────┬──▶
       T+0   3    6    9   12   15   18   20   22   24   26   28   30   32  min
         │                        │         │                        │
         │  receives 1..5 fail    │         │  API restored          │  depth 0,
         │  (every 180 s)         │         │  (LOYALTY_API_DOWN     │  points
         │◄── retry window ~15m ──┤         │   back to false)       │  awarded
         │                        │                                     once
         │                        └─ 5th receive: SQS moves all 50
         │                           into pos-loyalty-dlq; alarm fires
         │                           within ~60 s
         │
         └─ pos-inventory-queue and pos-einvoice-queue are completely
            unaffected throughout: separate queues, separate consumers,
            separate DLQs. That isolation is the blast-radius property
            the whole design exists to buy.
```

**The three sizing rules, and why each number is what it is:**

| Rule | Applied here | What breaks without it |
|---|---|---|
| **Visibility timeout ≥ 6 × Lambda timeout** | 180/30, 120/20, 360/60 | AWS's recommendation for SQS event source mappings: a throttled or retried invocation needs room to finish before the message becomes visible again. Below 1×, Lambda outright refuses to create the event source mapping — so this is a deploy-time failure, not a runtime surprise. Between 1× and 6× it *works* but quietly burns receives on concurrent duplicate processing under throttling. |
| **`maxReceiveCount` ≥ 5** | 5 on loyalty and inventory, **8** on e-invoice | AWS's recommended minimum for Lambda consumers. Fewer receives and a two-minute dependency blip parks healthy transactions in a DLQ, training the on-call to ignore the alarm. e-Invoice gets 8 because its dominant failure is HTTP 429 from a rate-limited tax API — a failure that *will* succeed once the token bucket refills — giving it a ~48-minute window. Extra receives are only defensible when the dominant failure mode is transient. |
| **DLQ retention (14 d) > source retention (4 d)** | 1209600 s vs 345600 s | For **Standard** queues, the expiry clock is the *original* enqueue timestamp on the source queue, and a dead-letter move does not reset it. With both set to 4 days, a message that already waited 3 days in the source queue survives only 1 more day in the DLQ — and then SQS deletes it silently, which is the exact failure this project exists to eliminate. (FIFO queues do reset the timestamp; Standard queues do not.) The `dlq-message-aging` alarm at 7 days is the backstop. |

**Where the ceilings actually are:** Lambda's default regional concurrency (1,000) and SQS's automatic scaling are far above 25,000 transactions/hour (~7/second). The binding constraint on this pipeline at peak is the third-party loyalty API and the rate-limited tax authority API — which is precisely why the design invests in retry windows, DLQs and replay rather than in throughput.

---

## Tagging Strategy

| Tag Key | Value | Applied To |
|---|---|---|
| `Project` | `pos-dlq-pipeline` | Every taggable resource (provider `default_tags`) |
| `Owner` | `brendon` | Every taggable resource |
| `Environment` | `lab` | Every taggable resource |
| `ManagedBy` | `Terraform` | Every taggable resource |
| `Name` | Resource-specific (`pos-loyalty-queue`, `pos-loyalty-fn-role`, `/aws/lambda/pos-loyalty-fn`, ...) | Queues, DLQs, topics, functions, roles, log groups, alarms, table, bucket |
| `Service` | `loyalty` / `inventory` / `einvoice` | Every resource created inside a `consumer_queue` module call |
| `QueueRole` | `source` / `dead-letter` / `sns-delivery-dead-letter` | SQS queues, and the SNS delivery DLQ alarm |
| `RetryWindowSeconds` | `900` / `600` / `2880` | Source queues only — `max_receive_count × visibility_timeout`, so an on-call engineer can read the retry window straight off the console |
| `Role` | `transaction-fanout` / `ops-alerting` / `idempotency` / `poison-message-archive` | The two SNS topics, the DynamoDB table, the S3 bucket |
| *(caller-supplied)* | `var.additional_tags` | Merged into `default_tags`, so it reaches every resource |

> Not everything in this stack is taggable. `aws_sqs_queue_policy`, `aws_sqs_queue_redrive_allow_policy`, `aws_sns_topic_subscription`, `aws_iam_role_policy`, `aws_lambda_event_source_mapping`, `aws_cloudwatch_dashboard` and the S3 sub-resources (versioning, encryption, public access block, lifecycle) carry no tags in this configuration — they are configurations of a parent resource, and the parent is tagged. `data.archive_file` creates no AWS resource at all.

---

## Security Considerations

| Topic | Current posture | Recommended hardening |
|---|---|---|
| **Encryption at rest (SQS)** | SSE-SQS (`sqs_managed_sse_enabled = true`) on all 7 queues | A customer-managed KMS key for key rotation control and CloudTrail-visible key usage — at ~USD 1/month per key, plus a key policy that SNS can use (get that wrong and delivery fails into `pos-sns-delivery-dlq`) |
| **Encryption at rest (other)** | DynamoDB AWS-owned keys (default); S3 SSE-S3 (`AES256`) | Customer-managed CMKs on both if the member data is in scope for a key-custody requirement |
| **Queue access control** | Resource policy allows only `sns.amazonaws.com`, only `sqs:SendMessage`, only on that queue, only when `aws:SourceArn` is the `pos-transactions` topic | Already tight. Consider adding an explicit `Deny` for non-TLS transport (`aws:SecureTransport: false`) |
| **IAM least privilege** | Per-function inline policies pinned to one queue ARN, one table ARN and one log group; no AWS managed policies; no `GetItem`, `UpdateItem` or `CreateLogGroup` | Review periodically with IAM Access Analyzer; add a permissions boundary if other teams gain deploy rights |
| **Redrive blast radius** | `redrivePermission = "byQueue"` pins each DLQ to its own source queue | Also restrict who may call `sqs:StartMessageMoveTask` — it is an identity-based action, so today it is bounded only by the operator's own IAM |
| **PII in messages** | Transaction bodies contain `member_id`, basket contents and amounts; they sit in queues for up to 14 days and in the S3 archive for 90 days | Confirm the 90-day archive retention against the retail data-retention policy; consider redacting `member_id` in the archive manifest |
| **PII in logs** | The structured log line records `transaction_id`, `store_id`, `message_id`, outcome and reason — deliberately **not** `member_id` or basket contents | Keep it that way. Any new field added to `_log()` should be reviewed against this rule |
| **Idempotency store** | DynamoDB table holds only `transaction_id`, `service`, timestamps | No change needed |
| **Archive tamper-resistance** | S3 versioning enabled, full public-access block, no Lambda role has any access | Object Lock in governance mode if the archive is ever treated as audit evidence |
| **Backups / recovery** | DynamoDB PITR disabled (lab) | Enable PITR before production — a lost idempotency table means a redrive can double-award |
| **Secrets** | None. No API keys, no passwords, no Secrets Manager entries — the external APIs are simulated | When the real loyalty and tax APIs are wired in, their credentials belong in Secrets Manager, read at runtime, never in `extra_environment` |
| **Terraform state** | Local file, git-ignored. Contains queue ARNs and the alert email, no credentials | Move to an S3 backend with versioning, SSE-KMS and state locking before more than one person can apply |
| **CI/CD credentials** | GitHub Actions authenticates by OIDC role assumption; no long-lived keys in the repository; `apply` gated behind a `production` environment | Scope the OIDC trust policy to this repository *and* the specific branch/environment, not just the repo |

---

## Cost Estimate

Region `ap-southeast-1`, at the lab volumes this project is sized for (hundreds to low thousands of messages per drill, not the 25,000/hour production peak). The stack is **not deployed and bills $0 today**.

| Resource | Quantity | Monthly cost (USD) |
|---|---|---|
| CloudWatch alarms | 7 standard-resolution alarms × ~$0.10 | **~$0.70** |
| SNS topics | 2 topics; first 1M publishes free, SQS deliveries free | ~$0.00 |
| SQS queues | 7 queues (3 source, 3 DLQ, 1 SNS delivery DLQ); first 1M requests/month free | ~$0.00 |
| Lambda | 3 functions, 256 MB; free tier covers 1M requests + 400,000 GB-seconds | ~$0.00 |
| DynamoDB | `PAY_PER_REQUEST`, a few thousand writes and deletes; storage well under the 25 GB free allowance | ~$0.00 |
| CloudWatch dashboard | 1 (first 3 dashboards per account are free) | ~$0.00 |
| CloudWatch Logs | 3 log groups, 14-day retention, well under the 5 GB free ingestion | ~$0.00 |
| S3 poison archive | Empty until a Path B incident; NDJSON archives are kilobytes | ~$0.00 |
| **Total** | | **~$0.70 / month** |

Essentially the entire bill is the alarms. Two deliberate choices keep it there:

- **SSE-SQS instead of a customer-managed KMS key.** A CMK is ~USD 1/month per key plus per-request charges — more than the rest of this stack combined — and buys key-custody control this lab does not need.
- **On-demand everything.** DynamoDB `PAY_PER_REQUEST` and Lambda's per-invocation model mean an idle pipeline costs nothing at all; there is no provisioned capacity to leave running.

At production volume (~6,000 tx/hour baseline, ~25,000 at peak) the shape changes: SNS publishes, SQS requests (3 deliveries per transaction) and Lambda GB-seconds become the dominant lines, and DynamoDB write units scale linearly with transaction count. The alarms stay at $0.70.

[AWS Pricing Calculator](https://calculator.aws/)

---

## Destroying the Stack

```bash
cd "POS Transaction Pipeline with SQS DLQ/terraform"
terraform destroy
```

> **Nothing is deployed today, so `terraform destroy` is a no-op** — with no state file it reports `No changes. No objects need to be destroyed.` The command below matters only after a first `apply`.

Manual pre-steps before a real destroy:

1. **Empty the archive bucket.** `aws_s3_bucket.dlq_archive` does **not** set `force_destroy`, and the bucket is versioned. If any Path B archive has ever been written, destroy fails with `BucketNotEmpty` until every object *and every noncurrent version* is removed: `aws s3api delete-objects` over `list-object-versions`, or `aws s3 rb s3://<bucket> --force` for the non-versioned case. Copy anything you still need first — archives are the only surviving record of a purged poison message.
2. **Drain or accept the loss of queued messages.** Deleting a queue deletes its messages. Check every DLQ depth first (`terraform output -json dlq_depth_commands`); anything still parked is gone for good.
3. **Stop the drill switches.** If `loyalty_api_down = true` is still set, transactions published during teardown will fail and confuse the final metrics.

Everything else is Terraform-managed and disappears cleanly: the two SNS topics and all four subscriptions, all 7 queues and their policies, the 3 Lambda functions and event source mappings, the 3 IAM roles and inline policies, the 3 log groups *and their log data*, the DynamoDB table *and every idempotency claim in it*, all 7 alarms, and the dashboard.

Resources **not** managed by Terraform that survive a destroy:

- `terraform/.build/*.zip` — the Lambda deployment packages. They are produced by `data "archive_file"`, so they are regenerated automatically on the next `plan` or `apply`; delete them by hand if you want a clean tree. They are git-ignored.
- `terraform/terraform.tfstate` and its backups — local state files. Git-ignored; remove them manually once you are certain nothing remains.
- An **unconfirmed** SNS email subscription leaves nothing behind, but a confirmed one is deleted with the topic. No manual unsubscribe is needed.
- Anything a human operator created by hand while following the runbook — S3 archive objects (see step 1), and any incident record written outside this repository.

---

## Frequently Asked Questions

**Q: I published messages and the queues stayed empty — what's wrong?**
A: Check the queue policy's `aws:SourceArn` condition first; it is the failure this stack is most likely to hit on a fresh deploy. SNS reports a successful publish whether or not it can hand the message to a subscriber, so nothing looks wrong from the publisher's side. If the policy is missing, malformed, or naming a different topic ARN, SNS cannot deliver, the messages land in `pos-sns-delivery-dlq`, and `pos-sns-delivery-dlq-not-empty` fires. That alarm is the tell: a *consumer* DLQ means one message failed processing, but the SNS delivery DLQ means an entire fan-out leg may be dropping everything while its source queue sits innocently empty. Runbook Path C walks the checks in order — subscription attributes, destination queue policy, KMS key policy, then the SNS `NumberOfNotificationsFailed` metric.

**Q: How is a DLQ different from Lambda Destinations?**
A: They sit at different layers and catch different things. An **SQS DLQ** is a property of the *queue*: SQS itself moves a message after `maxReceiveCount` receives, regardless of why each attempt failed, and the original message body is preserved so it can be moved back with `StartMessageMoveTask`. **Lambda Destinations** are a property of the *function* and only apply to **asynchronous** invocations (and stream/queue event sources for `OnFailure` in some configurations); they send a *record about* the invocation — request context, response, error — to SQS, SNS, EventBridge or another Lambda, which is richer for debugging but is not the original message and cannot be redriven back to a queue. This pipeline uses SQS event source mappings, which are a *synchronous* invocation path, so the queue-level DLQ plus partial batch responses is the correct mechanism. Destinations would be the right tool if the consumers were invoked asynchronously.

**Q: Why Standard queues instead of FIFO?**
A: Because a DLQ breaks what FIFO is for. AWS documents that using a dead-letter queue with a FIFO queue voids exact ordering: when a message is moved out of a message group, the messages behind it continue to be delivered rather than waiting. So you would pay FIFO's throughput and complexity costs for an ordering guarantee that evaporates the moment the mechanism you built the system around actually fires. POS transactions have no inter-transaction ordering dependency — a sale at terminal 3 does not depend on a sale at terminal 1 — so Standard queues plus DynamoDB conditional-write idempotency give the property that actually matters (each transaction applied exactly once) without the false guarantee. The one thing FIFO would have bought is that FIFO queues *do* reset the enqueue timestamp on a dead-letter move; Standard queues do not, which is why DLQ retention here is 14 days against the source's 4.

**Q: The DLQ has 100,000 messages in it. Now what?**
A: Do not start a move task. Work the runbook in order. **(1) Classify before acting** — receive a handful of messages with a long enough `--visibility-timeout` that they are not re-served mid-triage, pull their `transaction_id`s, and run the Logs Insights query that aggregates `outcome` by `reason` over the outage window. 100,000 messages with one `reason` is one downstream outage; a spread across several reasons is more than one incident and they need separating. **(2) Check the age** — `ApproximateAgeOfOldestMessage` is measured from the *original* enqueue on the source queue, so the real headroom against the 14-day retention is smaller than the DLQ's own lifetime suggests. If the `dlq-message-aging` alarm is also in ALARM, the oldest messages are the priority. **(3) Confirm the downstream is genuinely healthy** — replaying 100,000 messages into a service that is still degraded is how a recovered outage becomes a second, longer one. **(4) Redrive at a rate the downstream can absorb** — `scripts/redrive.sh` defaults to 10 messages/second (600/minute), in line with MekarMart's normal 6,000/hour load, so the loyalty platform sees nothing it does not already handle daily. At that rate 100,000 messages take about 2.8 hours; that is the correct duration, not a problem to optimise away. **(5) Only one move task can run per source queue at a time**, so check `list-message-move-tasks` before starting and track progress rather than starting a second. Anything classified as poison never enters this path at all — see the last question.

**Q: How do you prove nothing was lost?**
A: With four independent counts, which is exactly the verification section of the runbook. **(1) DLQ depth returns to 0** and `ApproximateNumberOfMessagesNotVisible` is also 0 — a non-zero in-flight count means the move task is still working. **(2) The source queue drained** back to 0 after the redrive, meaning the consumers actually processed what was replayed rather than failing it straight back. **(3) Logs Insights count matches** — filter the consumer log group on `outcome = "processed"` or `"duplicate_skipped"` for the redrive window and compare against `ApproximateNumberOfMessagesMoved` from the move task. The two outcomes together are the success set; `duplicate_skipped` is not a failure, it is the idempotency guard confirming the transaction had already been applied. **(4) DynamoDB holds exactly one item per `transaction_id`** — the conditional write makes duplicates structurally impossible, so a count of distinct claims is the ledger. Requirement R5 is what makes this auditable at all: every record emits one structured JSON line carrying `service`, `transaction_id`, `store_id`, `message_id`, `outcome`, `error_type`, `reason` and `attempt`, so any individual transaction can be traced across all of its attempts by ID. Those field names are a contract with the runbook's queries — renaming one silently breaks the audit.

**Q: The outage lasted 40 minutes and the retry window is 15. Shouldn't I just raise `maxReceiveCount`?**
A: No — that is treating the symptom and making the real problem worse. Raising loyalty's `maxReceiveCount` from 5 to 15 buys a ~45-minute window, and it also means every firmware v2.3 poison message now burns **15** Lambda invocations before anyone hears about it instead of 5, and takes three times as long to surface. You have made the system slower to tell you about the failures that need a human and no faster at the ones that do not. The actual fix is **error classification**, which is what `common/errors.py` exists for: a `TransientError` is a dependency problem, and the answer to a long dependency outage is a DLQ plus a rate-limited replay — which is fully automatic once the fix lands, and scales to an outage of any length up to the 14-day retention. A `PermanentError` can never succeed, so ideally it should not consume its retry budget at all (quarantining poison on the first receive is the natural next step). The only lane where a higher count is defensible is e-invoice at 8, and only because its dominant failure — HTTP 429 from a rate-limited API — is transient by construction and *will* clear on its own.

**Q: Can I just redrive poison messages back to the source queue?**
A: You can, and it will accomplish nothing except cost. A poison message failed on its *content* — `items: null` from firmware v2.3 — so a replay puts it through another full lap of the retry window, burns another `maxReceiveCount` invocations, and deposits it back in the same DLQ with a higher receive count and less retention headroom, because the Standard-queue expiry clock never reset. Worse, if you redrive a mixed DLQ containing both classes, the poison messages mask the signal: the DLQ never empties, the `dlq-not-empty` alarm never clears, and the on-call cannot tell whether the transient replay worked. Poison messages take runbook **Path B** instead: archive the bodies to `s3://pos-dlq-archive-<account-id>/` with a manifest, notify Store Ops with the affected store and terminal list so the firmware upgrade can be scoped, and only then delete by receipt handle. Archive first, always — the message body is the only evidence that the bad transactions existed, and once it is deleted from the DLQ it is unrecoverable.

**Q: Should I use remote state, and how do I update the consumer code?**
A: State here is **local** on purpose — a single-operator lab, no S3 backend block, and `terraform.tfstate` git-ignored. Before more than one person can run `apply`, move to an S3 backend with versioning, SSE-KMS and state locking; the state holds queue and topic ARNs and the alert email address, no credentials. For **code changes**, edit the handler under `lambda/`, run `python3 -m unittest discover lambda` to check the 23 offline tests still pass, then `terraform apply`: `data "archive_file"` re-zips the whole `lambda/` tree and the changed `source_code_hash` redeploys all three functions. Note that all three share one package, so a change to `common/processing.py` redeploys every lane — which is the intended coupling, since that module is what keeps the three consumers from drifting apart in how they classify failures. Flipping a drill switch (`loyalty_api_down`, `einvoice_throttle_rate`) is a variable change only and updates the function's environment without touching the package.
