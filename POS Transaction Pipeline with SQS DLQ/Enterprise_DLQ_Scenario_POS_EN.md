# Enterprise Scenario: Dead-Letter Queues for a Retail POS Transaction Pipeline

**MekarMart Retail Group — Cloud Platform Team**
*Project Brief + Hands-on Lab · Terraform · Region: `ap-southeast-1` (Singapore)*
*Prepared September 2026*

> MekarMart is a fictional company created for learning and portfolio use.

---

## Contents

1. [Business Context](#1-business-context)
2. [The Incident](#2-the-incident)
3. [Requirements](#3-requirements)
4. [Solution Architecture](#4-solution-architecture)
5. [DLQ Design Parameters](#5-dlq-design-parameters)
6. [Message Schema & Failure Types](#6-message-schema--failure-types)
7. [Repository Layout](#7-repository-layout)
8. [Hands-on Lab (Phase 0–5)](#8-hands-on-lab-phase-05)
9. [Test Cases](#9-test-cases)
10. [Roles & Responsibilities (RACI)](#10-roles--responsibilities-raci)
11. [Cost & Cleanup](#11-cost--cleanup)
12. [Interview Talking Points](#12-interview-talking-points)

---

## 1. Business Context

MekarMart is a convenience-store chain with **180 stores across Malaysia (Johor Bahru, Kuala Lumpur, Penang) and Singapore**. Each store runs 2–4 POS terminals.

When a sale completes, the POS terminal sends the transaction to the cloud, which must **fan it out to three downstream services**:

| Downstream Service | What it does | Impact of failure |
|---|---|---|
| **Loyalty** | Awards member points via a third-party loyalty platform API | Customer complaints: "my points never arrived" |
| **Inventory** | Deducts store stock and triggers replenishment | Inaccurate stock — stock-outs or over-ordering |
| **e-Invoice** | Submits e-invoices to the tax authority API (rate-limited) | Compliance risk and potential penalties |

Normal load is about **6,000 transactions/hour**; during Chinese New Year, 11.11 and year-end sales, it peaks at **25,000 transactions/hour**.

---

## 2. The Incident

**During the 2026 Chinese New Year promotion**, two failures happened in the same week:

1. The third-party loyalty API **went down for 40 minutes**. The old Loyalty consumer wrapped the API call in a `try/except` that **swallowed the timeout and deleted the message anyway**. Result: **3,140 transactions permanently lost their loyalty points**, and customer service received 600+ complaints.
2. **POS firmware v2.3 in 12 older stores** sent malformed transactions (`items` was `null`). These **poison messages** failed every time and **retried in the queue for 4 days**, burning hundreds of thousands of Lambda invocations — until the **retention period expired and SQS silently deleted them**. Nobody noticed.

> **Root cause:** The old system had **no DLQ** and **no distinction between retryable and non-retryable errors**. Failed messages were either quietly deleted or quietly expired — both are **silent data loss**.

The CTO's mandate was simple:

> *"No transaction may silently disappear. Failures are OK — but they must be isolated, visible, and replayable."*

---

## 3. Requirements

| # | Requirement | How we prove it |
|---|---|---|
| **R1** | **Zero silent loss** — any message that fails processing lands in a DLQ once its retry window is exhausted, and is retained for 14 days | Inject a failing message → it appears in the DLQ |
| **R2** | **Isolate poison messages** — one bad transaction must not drag down the rest of its batch | Batch of 10 with 1 bad → only 1 is retried |
| **R3** | **Alert within 5 minutes** — the on-call engineer is notified when the first message reaches a DLQ | CloudWatch Alarm → Email/Slack |
| **R4** | **Safe replay** — after a fix, DLQ messages can be sent back to the source queue **without awarding points twice** | After redrive, points are awarded exactly once (idempotent) |
| **R5** | **Traceability** — every DLQ message can be traced by `transaction_id` to its failure reason in the logs | CloudWatch Logs Insights query |

---

## 4. Solution Architecture

The design uses the **SNS fan-out pattern with SQS queues and Lambda consumers**. Each downstream service has **its own queue and its own DLQ**, so failures stay isolated.

```
   180 stores' POS terminals  (simulated in the lab by pos_simulator.py)
              │  sns:Publish  (transaction JSON)
              ▼
   ┌───────────────────────────┐
   │  SNS Topic                │   Delivery failure (e.g. broken queue policy)
   │  pos-transactions         │ ─────────────────────────────► sns-delivery-dlq
   └─────────────┬─────────────┘     (subscription-level DLQ)
        fan-out  │  raw message delivery
     ┌───────────┼────────────────────────┐
     ▼           ▼                        ▼
 loyalty-queue  inventory-queue       einvoice-queue
     │  │          │  │                    │  │
     │  └─ 5x ──► loyalty-dlq             │  └─ 8x ──► einvoice-dlq
     │             │  └─ 5x ──► inventory-dlq
     ▼             ▼                        ▼
 Lambda         Lambda                   Lambda
 loyalty-fn     inventory-fn             einvoice-fn
     │
     ▼
 DynamoDB  processed-transactions  (idempotency table, 7-day TTL)

 ──────────────────────── Monitoring & Operations ────────────────────────
 Any DLQ  ApproximateNumberOfMessagesVisible > 0
     └─► CloudWatch Alarm ─► SNS ops-alerts ─► Email / Slack

 Fix deployed ─► StartMessageMoveTask (redrive, rate-limited) ─► back to source queue
```

**Why this design:**

- **One queue + one DLQ per downstream service** — if the loyalty platform goes down, only `loyalty-dlq` fills up; inventory and e-invoice keep flowing. This limits the **blast radius**.
- **A DLQ on the SNS subscription too** — SQS DLQs only catch *consumer* failures. If SNS **cannot deliver to the queue at all** (for example, a wrong queue policy or KMS key policy), that failure happens at the SNS layer, so a **subscription-level DLQ** is needed as a safety net.
- **No FIFO** — AWS warns that **using a DLQ with a FIFO queue breaks exact message ordering** (once a message is moved out, later messages in the same group continue). POS transactions have no strict ordering dependency, so Standard queues plus idempotency are the better fit.

---

## 5. DLQ Design Parameters

| Queue | Lambda Timeout | Visibility Timeout | maxReceiveCount | Approx. Retry Window | Source Retention | DLQ Retention |
|---|---|---|---|---|---|---|
| `loyalty-queue` | 30 s | **180 s** | **5** | ≈ 15 min | 4 days | **14 days** |
| `inventory-queue` | 20 s | **120 s** | **5** | ≈ 10 min | 4 days | **14 days** |
| `einvoice-queue` | 60 s | **360 s** | **8** | ≈ 48 min | 4 days | **14 days** |

**Where the numbers come from:**

1. **Visibility Timeout ≥ 6 × Lambda Timeout** — AWS's recommendation, giving Lambda room to retry when it is throttled. The function timeout must be ≤ the queue's visibility timeout; otherwise creating the event source mapping fails (Lambda validates this).
2. **maxReceiveCount ≥ 5** — AWS's recommended minimum for Lambda consumers, giving transient failures a few chances. e-Invoice uses 8 because the tax API is rate-limited and returns frequent 429s, so it needs a longer retry window.
3. **Retry window ≈ maxReceiveCount × Visibility Timeout** — this determines how long a downstream outage can last before messages land in the DLQ.
4. **DLQ retention > source queue retention** — a common trap: **for Standard queues, message expiry is based on the original enqueue timestamp**, and moving to a DLQ does not reset it. If the DLQ retention equals the source retention, the time a message already spent in the source queue is "eaten". So the DLQ is set to the 14-day maximum. (FIFO queues do reset the timestamp.)

> **Trade-off (you'll experience this in Phase 4):** A 40-minute loyalty outage is longer than the 15-minute retry window, so messages will reach the DLQ. Should you raise maxReceiveCount to 15? That survives longer outages, but every poison message then wastes 15 attempts. **The right answer isn't tuning the number — it's classifying the error type** (see Section 6).

---

## 6. Message Schema & Failure Types

### Transaction message

```json
{
  "transaction_id": "TXN-JB012-20260911-000123",
  "store_id": "JB012",
  "terminal_id": "POS-03",
  "member_id": "M-88231077",
  "timestamp": "2026-09-11T14:32:05+08:00",
  "items": [
    { "sku": "SKU-100234", "qty": 2, "unit_price": 4.50 }
  ],
  "total_amount": 9.00,
  "currency": "MYR",
  "firmware_version": "3.1.0"
}
```

### Poison message sample (firmware v2.3)

```json
{ "transaction_id": "TXN-PG004-20260911-000871", "store_id": "PG004",
  "items": null, "total_amount": 12.80, "firmware_version": "2.3.0" }
```

### Three failure types

| Type | Example | Does retrying help? | How to handle it |
|---|---|---|---|
| **Transient** | Loyalty API timeout, HTTP 503, 429 throttling | ✅ Yes | Raise an exception → SQS retries → DLQ after max receives → redrive after recovery |
| **Permanent / Poison** | `items: null`, JSON parse error, negative quantity | ❌ No | Lands in DLQ for manual handling (advanced: quarantine immediately instead of wasting retries) |
| **Duplicate** | SQS at-least-once delivery, redrive replay | — | **Idempotency**: DynamoDB conditional write so each `transaction_id` is processed only once |

---

## 7. Repository Layout

```
pos-dlq-pipeline/
├── terraform/
│   ├── providers.tf          # AWS provider, ap-southeast-1, default_tags
│   ├── variables.tf
│   ├── sns.tf                # pos-transactions topic + ops-alerts topic
│   ├── dynamodb.tf           # processed-transactions (idempotency)
│   ├── consumers.tf          # calls module "consumer_queue" three times
│   ├── outputs.tf
│   └── modules/
│       └── consumer_queue/   # ⭐ core module: queue + DLQ + redrive + alarm + Lambda + ESM
│           ├── main.tf
│           ├── variables.tf
│           └── outputs.tf
├── lambda/
│   ├── loyalty/handler.py
│   ├── inventory/handler.py
│   └── einvoice/handler.py
├── scripts/
│   ├── pos_simulator.py      # sends normal / poison / duplicate messages
│   └── redrive.sh            # wrapper around StartMessageMoveTask
├── docs/
│   └── runbook-dlq.md        # on-call runbook (Phase 5 deliverable)
└── .github/workflows/terraform.yml   # stretch: plan on PR, apply on merge
```

> **Portfolio highlight:** "Queue + DLQ + alarm + consumer" is packaged as **one reusable Terraform module**; the three downstream services are just three calls with different parameters. That's platform thinking.

---

## 8. Hands-on Lab (Phase 0–5)

Total time: about **10 hours**. **You build every phase yourself**; I coach you in learn-coach style — tasks, hints, acceptance checks, and checkpoint questions. **Checkpoint answers are intentionally not included** — finish each phase, come back, and I'll quiz you one question at a time.

---

### Phase 0 — Setup (~1 hour)

**Goal:** Repository, Terraform backend and provider ready.

**Tasks**
- [ ] Create GitHub repo `pos-dlq-pipeline` using the layout in Section 7
- [ ] Configure Terraform remote state (S3 backend + state locking)
- [ ] `providers.tf`: region `ap-southeast-1`, `default_tags` (`Project = pos-dlq-pipeline`, `Owner = brendon`, `Environment = lab`)
- [ ] `terraform init` succeeds

**Acceptance:** `terraform plan` runs cleanly with zero resource changes.

**Checkpoint:**
1. Why store state in S3 instead of locally? What problem does state locking prevent?

---

### Phase 1 — Happy Path (~2 hours)

**Goal:** POS simulator → SNS → 3 SQS queues → Loyalty Lambda processes successfully. **No DLQs yet.**

**Tasks**
- [ ] `sns.tf`: create the `pos-transactions` topic
- [ ] Create 3 SQS Standard queues, subscribe them to SNS with `raw_message_delivery = true`
- [ ] Write a **queue policy** for each queue allowing `sns.amazonaws.com` to call `sqs:SendMessage`, restricted to this topic with an `aws:SourceArn` condition
- [ ] Write `loyalty-fn`: parse the message → log `transaction_id` → return success (no real API yet)
- [ ] Create the Lambda event source mapping (batch size 10)
- [ ] Write `pos_simulator.py`: publish 10 normal transactions with boto3

**Hint:** If messages are published but the queues stay empty, check the `aws:SourceArn` in the queue policy first.

**Acceptance:** Publish 10 → see 10 `transaction_id`s in CloudWatch Logs → all 3 queues drain.

**Checkpoint:**
1. With `raw_message_delivery` turned off, what does the message Lambda receives look like?
2. Compared with the POS calling 3 APIs directly, what does SNS → SQS fan-out give you?

---

### Phase 2 — Add the DLQs (~2 hours) ⭐ Core

**Goal:** A poison message moves to the DLQ after 5 receives instead of retrying forever.

**Tasks**
- [ ] Refactor the queues into `modules/consumer_queue`
- [ ] Create a DLQ for each source queue (`xxx-dlq`) with 14-day retention
- [ ] Configure a **redrive policy** on each source queue (`deadLetterTargetArn` + `maxReceiveCount`, per Section 5)
- [ ] Configure a **redrive allow policy** on each DLQ (`byQueue`, only its own source queue)
- [ ] Set Visibility Timeout = 6 × Lambda Timeout
- [ ] Add validation to the Loyalty Lambda: **raise an exception** when `items` is `null`
- [ ] Send 1 poison message with the simulator

**Reference (shape of the redrive policy — write the rest yourself):**

```hcl
redrive_policy = jsonencode({
  deadLetterTargetArn = aws_sqs_queue.dlq.arn
  maxReceiveCount     = var.max_receive_count
})
```

**Acceptance:**
- The same `transaction_id` errors **5 times** in CloudWatch Logs
- `aws sqs get-queue-attributes --attribute-names ApproximateNumberOfMessages` shows **1** message in `loyalty-dlq`
- Read the DLQ message with `aws sqs receive-message` and inspect its `ApproximateReceiveCount` attribute

**Checkpoint:**
1. What conditions must a DLQ and its source queue satisfy? (account, Region, queue type)
2. What happens if the Lambda timeout is 60 s and the visibility timeout is 30 s?
3. Source retention is 4 days and DLQ retention is also 4 days. A message spent 1 day in the source queue before moving to the DLQ. How long does it live in the DLQ, and why?

---

### Phase 3 — Partial Batch Failure + Idempotency (~2 hours)

**Goal:** In a batch of 10 with 1 bad message, only that 1 is retried; duplicate messages never award points twice.

**Tasks**
- [ ] **Experiment first:** without changing anything, send a batch of 9 good + 1 poison → observe whether the 9 good messages are retried too
- [ ] Enable `function_response_types = ["ReportBatchItemFailures"]` on the event source mapping
- [ ] Change the Lambda to process records one by one and return failures in `batchItemFailures` (`itemIdentifier` = `messageId`)
- [ ] Create the DynamoDB table `processed-transactions` (PK = `transaction_id`, TTL 7 days)
- [ ] Before processing, do a **conditional put** (`attribute_not_exists(transaction_id)`); skip if it already exists
- [ ] Send the same `transaction_id` 3 times with the simulator

**Hint:** As a stretch, you can use the Idempotency utility in **Powertools for AWS Lambda (Python)** — but hand-write it once first so you understand the mechanism.

**Acceptance:**
- 9 good + 1 poison → the 9 are processed **once** each; the poison message is processed **5 times** then moves to the DLQ
- Same transaction sent 3 times → points are awarded **once**

**Checkpoint:**
1. Without `ReportBatchItemFailures`, why does one bad message spoil the whole batch? How does this relate to R4 (no double points)?
2. Why is idempotency a **prerequisite** for DLQ redrive?

---

### Phase 4 — Alerting + Outage Drill (~1.5 hours)

**Goal:** Get notified within 5 minutes of a DLQ receiving messages, and experience first-hand what happens when an outage outlasts the retry window.

**Tasks**
- [ ] In the module, add a **CloudWatch alarm** for each DLQ: `ApproximateNumberOfMessagesVisible` ≥ 1, period 60 s, statistic `Maximum`
- [ ] Add a second alarm: DLQ `ApproximateAgeOfOldestMessage` > 7 days (messages nearing expiry must be handled)
- [ ] Alarm action → `ops-alerts` SNS topic → email subscription
- [ ] Add a **subscription DLQ** (`sns-delivery-dlq`) to the `pos-transactions` SNS subscriptions
- [ ] **Drill:** set the Loyalty Lambda environment variable `LOYALTY_API_DOWN=true` (simulating a 503 from the loyalty API), **send 50 transactions at the start of the drill**, and keep the outage on for 20 minutes (> the 15-minute retry window)
- [ ] Build a CloudWatch dashboard: depth of the 3 source queues + 3 DLQs + Lambda errors

**Acceptance:**
- After ~15 minutes, all 50 messages have moved into `loyalty-dlq`, and **inventory and e-invoice are completely unaffected**
- Alarm email received within 5 minutes
- (Stretch) Delete one queue's queue policy → messages land in `sns-delivery-dlq`

**Checkpoint:**
1. Why alarm on `ApproximateNumberOfMessagesVisible` rather than the DLQ's `NumberOfMessagesSent`?
2. The outage lasted 40 minutes; the retry window is 15 minutes. Would you raise maxReceiveCount or change the code? Explain your trade-off.

---

### Phase 5 — Redrive + Runbook (~1.5 hours)

**Goal:** After the fix, safely send DLQ messages back to the source queue, and write a runbook someone else can follow.

**Tasks**
- [ ] Set `LOYALTY_API_DOWN` back to `false` ("fix deployed")
- [ ] Write `redrive.sh`: call `aws sqs start-message-move-task` with `--max-number-of-messages-per-second 10` (rate-limit so you don't knock over the freshly recovered loyalty platform)
- [ ] Track progress with `list-message-move-tasks`
- [ ] Verify all 50 point awards arrived with no duplicates
- [ ] Write `docs/runbook-dlq.md`, covering at least:
  - **Triage** steps after an alert (which DLQ → read one message → search Logs Insights by `transaction_id` → classify transient vs permanent)
  - **Transient errors** → fix / wait for recovery → redrive
  - **Permanent errors (poison)** → archive to S3 → notify Store Ops to upgrade firmware → delete
  - Ownership and escalation path (see the RACI in Section 10)
- [ ] Stretch: GitHub Actions pipeline (`terraform plan` on PR, `apply` on merge)

**Acceptance:** Someone who wasn't involved (or me, playing a new teammate) can complete a redrive using only the runbook.

**Checkpoint:**
1. Can you redrive poison messages straight back to the source queue? What would happen?
2. Why rate-limit the redrive?
3. If the DLQ's source were a Lambda asynchronous invocation (not an SQS queue), could you use `StartMessageMoveTask`?

---

## 9. Test Cases

| ID | Scenario | Expected Result | Requirement |
|---|---|---|---|
| TC-01 | Send 10 normal transactions | All processed, DLQ = 0 | — |
| TC-02 | 1 poison message (`items: null`) | 5 retries → `loyalty-dlq` = 1, alarm fires | R1, R3 |
| TC-03 | Batch of 9 good + 1 poison | The 9 processed once; 1 moves to DLQ | R2 |
| TC-04 | Same `transaction_id` sent 3 times | Points awarded once | R4 |
| TC-05 | Loyalty API down for 20 minutes | `loyalty-dlq` receives messages; other two queues unaffected | R1 |
| TC-06 | Redrive after recovery | All points awarded, no duplicates | R4 |
| TC-07 | Delete a queue policy | Messages land in `sns-delivery-dlq` | R1 |
| TC-08 | Search logs by `transaction_id` | Failure reason visible for every attempt | R5 |

---

## 10. Roles & Responsibilities (RACI)

R = Responsible · A = Accountable · C = Consulted · I = Informed

| Activity | Cloud/DevOps Platform | Loyalty Team | Finance (e-Invoice) | Store Ops | Security |
|---|---|---|---|---|---|
| Build queues / DLQs / alarms (Terraform) | **R/A** | C | C | I | C |
| First response to DLQ alarms (triage) | **R/A** | I | I | — | — |
| Fix loyalty platform issues | C | **R/A** | — | I | — |
| Review e-invoice DLQ messages | C | — | **R/A** | — | — |
| Execute redrive | **R** | **A** (confirms replay is safe) | C | — | — |
| Poison messages → firmware upgrade | I | — | — | **R/A** | — |
| KMS encryption / queue policy audit | C | — | — | — | **R/A** |

---

## 11. Cost & Cleanup

- SQS, SNS, Lambda and DynamoDB usage for this lab **stays mostly within the Free Tier**.
- Main visible costs: **CloudWatch alarms** (about USD 0.10/month per standard alarm; ~7 in this project), and a **KMS customer managed key** if you use one (about USD 1/month per key).
- Run `terraform destroy` when you're done. Keep or manually delete the S3 state bucket separately.

---

## 12. Interview Talking Points

Tell the story using **STAR** (30-second version):

> **Situation:** A 180-store retail chain sends every POS transaction to three systems — loyalty, inventory and e-invoice. The old system had no DLQ: one loyalty-platform outage lost 3,000+ point awards, and poison messages retried for 4 days before silently expiring.
> **Task:** Design a message pipeline with zero silent data loss.
> **Action:** Built SNS fan-out with a dedicated SQS queue and DLQ per downstream service in Terraform; sized parameters using visibility timeout = 6 × Lambda timeout, maxReceiveCount ≥ 5, and DLQ retention > source retention; enabled partial batch responses to isolate poison messages; used DynamoDB conditional writes for idempotency; added CloudWatch alarms, rate-limited redrive and an on-call runbook.
> **Result:** All 8 test cases passed; in a simulated 20-minute outage, 50 transactions had zero loss and zero duplicates, and were replayed with a single command after recovery.

**Likely follow-up questions (I'll quiz you on these after the phases):**
- How is a DLQ different from Lambda Destinations?
- Why not FIFO?
- The DLQ has 100,000 messages piled up — what do you do?
- How do you prove no messages were lost?

---

*Next step: start with Phase 0. When you finish each phase, come back and say "Phase N done" — I'll quiz you on its checkpoint questions in learn-coach mode.*
