# On-Call Runbook — POS Transaction DLQs

**MekarMart Retail Group — Cloud Platform Team**
*Project: `pos-dlq-pipeline` · Region: `ap-southeast-1` (Singapore) · Account: `<account-id>` (lab: `022499047467`)*
*Phase 5 deliverable. Last reviewed: 2026-09-11.*

> **Acceptance bar for this document:** an engineer who was not involved in building this pipeline
> must be able to complete a full redrive using only this runbook. If you hit a step where you had
> to ask someone, that is a bug in this runbook — raise a PR against `docs/runbook-dlq.md`.

---

## Contents

1. [Purpose and Scope](#1-purpose-and-scope)
2. [Alert Reference](#2-alert-reference)
3. [Triage — First 5 Minutes](#3-triage--first-5-minutes)
4. [Classify — Transient vs Permanent](#4-classify--transient-vs-permanent)
5. [Path A — Transient Failure (Downstream Outage)](#5-path-a--transient-failure-downstream-outage)
6. [Path B — Permanent Failure (Poison Message)](#6-path-b--permanent-failure-poison-message)
7. [Path C — `pos-sns-delivery-dlq` Is Non-Empty](#7-path-c--pos-sns-delivery-dlq-is-non-empty)
8. [Verification After Any Action](#8-verification-after-any-action)
9. [Escalation](#9-escalation)
10. [Known Traps](#10-known-traps)
11. [Appendix — Quick Reference](#11-appendix--quick-reference)

---

## 1. Purpose and Scope

> **Deployment status — the stack is authored but not yet deployed.** The Terraform in
> `terraform/` is complete and `terraform validate`-clean, and `terraform plan` shows **48
> resources to add**, but no `apply` has run. Nothing described below exists in AWS yet. If you run
> a triage command today you will get `AWS.SimpleQueueService.NonExistentQueue`,
> `ResourceNotFoundException` on the log group, or `404` on the archive bucket — that is the stack
> being unapplied, not an incident. Confirm with `terraform -chdir=terraform plan` (an empty plan
> means it is deployed) before you go looking for a cause. Every command here is written against
> the deployed state and needs no change once `apply` has run.

This runbook covers the operational response when a **dead-letter queue in the POS transaction
pipeline receives messages**. It is the procedure the on-call Cloud/DevOps engineer follows from
the moment a CloudWatch alarm fires until the messages are either replayed successfully or
deliberately archived and removed.

### In scope

- Alerts from `pos-loyalty-dlq`, `pos-inventory-dlq`, `pos-einvoice-dlq`, `pos-sns-delivery-dlq`
- Triage, classification, redrive, archive-and-purge, and post-action verification
- Escalation to the Loyalty team, Finance, Store Ops and Security

### Out of scope

- Building or changing the pipeline (Terraform lives in `terraform/`, owned by Cloud Platform)
- Fixing the third-party loyalty platform itself (Loyalty team owns that vendor relationship)
- POS firmware distribution (Store Ops owns that)

### Requirements this runbook serves

| Req | Requirement | How this runbook serves it |
|---|---|---|
| **R1** | Zero silent loss — failed messages land in a DLQ and are retained 14 days | §3 confirms the message is in the DLQ and not lost; §10 explains the retention clock so nothing expires unnoticed |
| **R2** | Isolate poison messages — one bad transaction must not drag down its batch | §4 classification separates the single poison record from the rest; §6 removes it without touching healthy traffic |
| **R3** | Alert within 5 minutes of the first DLQ message | §2 maps every alarm to a first action; §3 is scoped to complete inside 5 minutes |
| **R4** | Safe replay — redrive must not award points twice | §5 gates redrive on idempotency being healthy; §8 proves exactly-once |
| **R5** | Traceability — every DLQ message traceable by `transaction_id` to its failure reason | §4 gives the exact Logs Insights queries against the structured JSON log lines |

### Who is on the hook (RACI, from scenario §10)

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

> **Read this table twice before acting.** You (Cloud/DevOps) are *Responsible* for executing a
> redrive, but the Loyalty team is *Accountable* — you do not press the button on
> `pos-loyalty-dlq` until they confirm replay is safe. For `pos-einvoice-dlq`, Finance is
> Accountable for reviewing what is in the queue before anything is replayed or deleted, because
> those messages are tax filings.

### Assumed prerequisites

- AWS CLI v2 configured with a profile that can read SQS, CloudWatch Logs, DynamoDB and SNS in
  account `<account-id>`, region `ap-southeast-1`
- The repository checked out, so `scripts/redrive.sh` and `scripts/pos_simulator.py` are on disk
- `jq` installed (every command below that parses JSON uses it)

```bash
export AWS_REGION=ap-southeast-1
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "Operating in ${AWS_REGION} / ${ACCOUNT_ID}"
```

---

## 2. Alert Reference

Seven alarms watch this pipeline: a not-empty and an aging alarm on each of the three consumer
DLQs, plus a not-empty alarm on `pos-sns-delivery-dlq`. All of them publish to the SNS topic
`pos-ops-alerts`, which fans out to the on-call email and the `#mekarmart-ops` Slack channel.

| Alarm name | Metric / condition | What it means | Urgency | First action |
|---|---|---|---|---|
| `pos-loyalty-dlq-not-empty` | `ApproximateNumberOfMessagesVisible` >= 1, period 60 s, stat `Maximum`, 1 datapoint | At least one loyalty message exhausted its 5 receives (~15 min retry window) and was moved to `pos-loyalty-dlq`. Customer-visible: these are unawarded points. | **P2** — respond within 15 min, business hours or not | Go to §3 with `SERVICE=loyalty` |
| `pos-inventory-dlq-not-empty` | `ApproximateNumberOfMessagesVisible` >= 1, period 60 s, stat `Maximum` | An inventory deduction failed its 5 receives (~10 min retry window). Stock levels are now drifting from reality for the affected stores. | **P2** — respond within 15 min | Go to §3 with `SERVICE=inventory` |
| `pos-einvoice-dlq-not-empty` | `ApproximateNumberOfMessagesVisible` >= 1, period 60 s, stat `Maximum` | An e-invoice submission failed its 8 receives (~48 min retry window). This is a **compliance exposure** — unfiled invoices with the tax authority. | **P1** — respond immediately, page Finance on-call if not cleared in 60 min | Go to §3 with `SERVICE=einvoice`, then notify Finance (they are Accountable) |
| `pos-loyalty-dlq-message-aging` | `ApproximateAgeOfOldestMessage` > 7 days (604800 s) | A message has been sitting in the DLQ for over half its 14-day retention. It is on a path to silent expiry — exactly the 2026 CNY incident repeating. | **P1** — must be resolved this shift | Go to §3, then commit to Path A or Path B **today**. Do not defer. |
| `pos-inventory-dlq-message-aging` | `ApproximateAgeOfOldestMessage` > 7 days | As above, for inventory. | **P1** | As above |
| `pos-einvoice-dlq-message-aging` | `ApproximateAgeOfOldestMessage` > 7 days | As above, for e-invoice. Filing deadlines may already have been missed. | **P1** | As above, plus escalate to Finance immediately |
| `pos-sns-delivery-dlq-not-empty` | `ApproximateNumberOfMessagesVisible` >= 1, period 60 s, stat `Maximum`, `treat_missing_data = notBreaching` | SNS could **not deliver to a subscribed queue at all**. This is not a consumer failure — the message never reached `pos-loyalty-queue` / `pos-inventory-queue` / `pos-einvoice-queue`. Usually a broken queue policy or KMS key policy. | **P1** — this can be silently dropping *all* traffic for one fan-out leg | Go to §7. Do **not** use §3–§6, they do not apply, and **`scripts/redrive.sh` will not work on this queue**. |

> **`pos-sns-delivery-dlq-not-empty` is defined in `terraform/sns.tf`, not in
> `modules/consumer_queue/`.** The module is instantiated once per *consumer lane*, and the SNS
> subscription DLQ is not a consumer lane — so this alarm is declared alongside the queue itself.
> It carries `ok_actions` as well as `alarm_actions`, so `pos-ops-alerts` also tells you when the
> queue is empty again. There is deliberately **no aging alarm** on this queue: recovery is a
> manual re-publish (§7) rather than a redrive, so the 7-day "safe-replay window is closing" signal
> that the aging alarms carry does not apply here. Treat any non-zero depth as needing action the
> same shift.

> **Why the alarm is on `ApproximateNumberOfMessagesVisible` and not `NumberOfMessagesSent`:**
> `NumberOfMessagesSent` fires once when a message arrives and then goes quiet, so an alarm on it
> returns to `OK` while the DLQ is still full. `ApproximateNumberOfMessagesVisible` with statistic
> `Maximum` stays in `ALARM` for as long as there is anything in the queue — the alarm state is a
> live indicator of "there is unfinished work", which is what an on-call engineer needs.

> **The aging alarm is the safety net for the original incident.** In 2026 the poison messages
> retried for four days and then expired with nobody watching. The 7-day aging alarm exists so
> that a message can never quietly run out its 14-day clock.

---

## 3. Triage — First 5 Minutes

Target: within five minutes you know **which DLQ**, **how deep**, **one sample message**, and
**one `transaction_id`** to trace.

### Triage decision flow

```
                        ┌──────────────────────────────┐
                        │  Alarm fires → pos-ops-alerts│
                        └──────────────┬───────────────┘
                                       │
                                       ▼
                        ┌──────────────────────────────┐
                        │  Which DLQ is in ALARM?      │
                        └──────┬────────────────┬──────┘
                               │                │
              pos-sns-delivery-dlq       pos-<service>-dlq
                               │                │
                               ▼                ▼
                     ┌──────────────┐   ┌─────────────────────────┐
                     │  §7 Path C   │   │ Step 1  depth + age     │
                     │  delivery    │   │ Step 2  peek one msg    │
                     │  failure     │   │ Step 3  receive count   │
                     └──────────────┘   │ Step 4  transaction_id  │
                                        └───────────┬─────────────┘
                                                    │
                                                    ▼
                                        ┌─────────────────────────┐
                                        │ §4  Logs Insights       │
                                        │ classify by error_type  │
                                        └──────┬───────────┬──────┘
                                               │           │
                          transient / many stores          permanent / one store
                          /  downstream outage             /  schema or firmware
                                               │           │
                                               ▼           ▼
                                    ┌──────────────┐  ┌──────────────┐
                                    │  §5 Path A   │  │  §6 Path B   │
                                    │  wait → fix  │  │  archive →   │
                                    │  → redrive   │  │  notify →    │
                                    │  → verify    │  │  purge       │
                                    └──────┬───────┘  └──────┬───────┘
                                           │                 │
                                           └────────┬────────┘
                                                    ▼
                                        ┌─────────────────────────┐
                                        │ §8  Verify zero loss,   │
                                        │     zero duplicates     │
                                        └─────────────────────────┘
```

### Step 0 — Set your working variables

Pick the service from the alarm name and set it once. Every command below reuses these.

```bash
export AWS_REGION=ap-southeast-1
export ACCOUNT_ID=022499047467                 # or: $(aws sts get-caller-identity --query Account --output text)
export SERVICE=loyalty                         # loyalty | inventory | einvoice

export DLQ_URL="https://sqs.${AWS_REGION}.amazonaws.com/${ACCOUNT_ID}/pos-${SERVICE}-dlq"
export SRC_URL="https://sqs.${AWS_REGION}.amazonaws.com/${ACCOUNT_ID}/pos-${SERVICE}-queue"
export DLQ_ARN="arn:aws:sqs:${AWS_REGION}:${ACCOUNT_ID}:pos-${SERVICE}-dlq"
export SRC_ARN="arn:aws:sqs:${AWS_REGION}:${ACCOUNT_ID}:pos-${SERVICE}-queue"
export LOG_GROUP="/aws/lambda/pos-${SERVICE}-fn"
```

> If you prefer not to hardcode the URL, resolve it: `aws sqs get-queue-url --queue-name
> pos-${SERVICE}-dlq --region ${AWS_REGION} --output text`.

### Step 1 — Identify which DLQ fired and how deep it is

Confirm the alarm first, so you are working the queue that actually fired and not the one you
assumed:

```bash
aws cloudwatch describe-alarms \
  --state-value ALARM \
  --alarm-name-prefix pos- \
  --region ap-southeast-1 \
  --query 'MetricAlarms[].{Alarm:AlarmName,Metric:MetricName,Value:StateReason,Since:StateUpdatedTimestamp}' \
  --output table
```

Then read the depth and the age of the oldest message:

```bash
aws sqs get-queue-attributes \
  --queue-url "${DLQ_URL}" \
  --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible ApproximateAgeOfOldestMessage \
  --region ap-southeast-1 \
  --output json
```

How to read the three numbers:

| Attribute | Meaning | What it tells you |
|---|---|---|
| `ApproximateNumberOfMessages` | Messages available to be received right now | Your backlog. This is the number that must come back to `0`. |
| `ApproximateNumberOfMessagesNotVisible` | Messages currently in flight (someone received them and has not deleted them) | If this is non-zero and you did not just peek, **another engineer is working this queue** or a redrive task is already running. Stop and check §5 Step 3 before starting a second one. |
| `ApproximateAgeOfOldestMessage` | Seconds since the **original** enqueue of the oldest message | Your deadline. Subtract from 14 days (1209600 s) to get remaining life — and read [Trap 1](#trap-1--dlq-retention-does-not-reset-the-expiry-clock) first, because the source-queue time is already burnt into this number. |

Quick deadline calculation:

```bash
AGE=$(aws sqs get-queue-attributes --queue-url "${DLQ_URL}" \
  --attribute-names ApproximateAgeOfOldestMessage --region ap-southeast-1 \
  --query 'Attributes.ApproximateAgeOfOldestMessage' --output text)
echo "Oldest message age: $((AGE/3600)) h — approx $(( (1209600 - AGE) / 3600 )) h of retention left"
```

Also check the **source** queue, because a full source queue with a climbing age means the outage
is still in progress and the DLQ will keep filling:

```bash
aws sqs get-queue-attributes \
  --queue-url "${SRC_URL}" \
  --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible ApproximateAgeOfOldestMessage \
  --region ap-southeast-1 \
  --output json
```

### Step 2 — Read one sample message without destroying it

```bash
aws sqs receive-message \
  --queue-url "${DLQ_URL}" \
  --attribute-names All \
  --message-attribute-names All \
  --max-number-of-messages 1 \
  --visibility-timeout 0 \
  --region ap-southeast-1 \
  --output json | tee /tmp/dlq-sample.json | jq '.'
```

Three things make this non-destructive:

1. **You never call `delete-message`.** In SQS, receiving does not remove a message; only an
   explicit delete does. Once the visibility timeout lapses the message is available again.
2. **`--visibility-timeout 0`** overrides the queue's visibility timeout for this receive only, so
   the message becomes visible again immediately instead of being hidden from your colleagues (and
   from a redrive task) for the queue default.
3. **`--max-number-of-messages 1`** keeps the blast radius of the peek to a single message.

> **Visibility-timeout caveat when peeking at a DLQ.** If you omit `--visibility-timeout 0`, the
> message you peeked disappears from `ApproximateNumberOfMessagesVisible` for the queue's
> visibility timeout and shows up under `ApproximateNumberOfMessagesNotVisible` instead. Two
> consequences bite people: (a) the depth number you read in Step 1 no longer matches what you
> see, and you conclude messages are being lost; (b) if you start a redrive inside that window,
> the hidden message is **not moved** and gets left behind in the DLQ after the task reports
> "Completed". Always peek with `--visibility-timeout 0`, and if you forget, wait out the
> visibility timeout before redriving.

> **Peeking is not free.** See [Trap 5](#trap-5--peeking-increments-approximatereceivecount) — each
> `receive-message` increments `ApproximateReceiveCount` on the message you touched.

### Step 3 — Read `ApproximateReceiveCount` and interpret it

```bash
jq -r '.Messages[0].Attributes' /tmp/dlq-sample.json
```

You will get something shaped like:

```json
{
  "ApproximateReceiveCount": "6",
  "ApproximateFirstReceiveTimestamp": "1789200125431",
  "SentTimestamp": "1789200100000",
  "SenderId": "AIDAEXAMPLEEXAMPLE"
}
```

| Observation | Interpretation |
|---|---|
| `ApproximateReceiveCount` == the queue's `maxReceiveCount` (`5` for loyalty and inventory, `8` for e-invoice) | Normal. The message exhausted its retry window on the source queue and SQS moved it here. This is the DLQ working as designed. |
| `ApproximateReceiveCount` == `maxReceiveCount + N` | You (or a colleague) have peeked at this message `N` times in the DLQ. The counter follows the message across queues; peeks add to it. Not an error. |
| `ApproximateReceiveCount` **less than** `maxReceiveCount` | The message did **not** arrive here through the redrive policy. Something put it in the DLQ directly — a manual `send-message`, a misconfigured producer, or a `StartMessageMoveTask` pointed the wrong way. Investigate before redriving; you may be about to replay something that was never processed. |
| `SentTimestamp` far older than `ApproximateFirstReceiveTimestamp` | The message queued behind a backlog before the first attempt. Combined with a large `ApproximateAgeOfOldestMessage`, this means the retention clock is well advanced — see [Trap 1](#trap-1--dlq-retention-does-not-reset-the-expiry-clock). |

Convert the timestamps (they are epoch **milliseconds**):

```bash
jq -r '.Messages[0].Attributes | "sent=\(.SentTimestamp) first_recv=\(.ApproximateFirstReceiveTimestamp) recv_count=\(.ApproximateReceiveCount)"' /tmp/dlq-sample.json
date -r $(( $(jq -r '.Messages[0].Attributes.SentTimestamp' /tmp/dlq-sample.json) / 1000 ))   # macOS
# GNU/Linux: date -d @$(( ... / 1000 ))
```

### Step 4 — Extract the `transaction_id` from the body

The SNS subscriptions use `raw_message_delivery = true`, so the SQS message body **is** the
transaction JSON — there is no SNS envelope to unwrap.

```bash
jq -r '.Messages[0].Body' /tmp/dlq-sample.json | jq '.'

export TXN_ID=$(jq -r '.Messages[0].Body' /tmp/dlq-sample.json | jq -r '.transaction_id')
export STORE_ID=$(jq -r '.Messages[0].Body' /tmp/dlq-sample.json | jq -r '.store_id')
export MSG_ID=$(jq -r '.Messages[0].MessageId' /tmp/dlq-sample.json)
echo "txn=${TXN_ID} store=${STORE_ID} message_id=${MSG_ID}"
```

> If `jq` reports a parse error on the body, the body is not valid JSON. That is itself a finding:
> a malformed producer payload is a **permanent** failure — go straight to §6. Capture the raw
> body with `jq -r '.Messages[0].Body' /tmp/dlq-sample.json > /tmp/raw-body.txt` before you do.

To widen the sample before classifying — 10 bodies, still non-destructively:

```bash
aws sqs receive-message --queue-url "${DLQ_URL}" \
  --attribute-names All --max-number-of-messages 10 --visibility-timeout 0 \
  --region ap-southeast-1 \
  | jq -r '.Messages[].Body' \
  | jq -r '[.transaction_id, .store_id, .firmware_version, (.items|type)] | @tsv'
```

A column of `null` in the `items` position, all from the same two or three `store_id`s, is the
firmware-v2.3 signature — you are almost certainly in Path B.

---

## 4. Classify — Transient vs Permanent

Everything downstream of here depends on getting this call right. **Do not skip to a path based on
the sample message alone** — one sample tells you about one message; the aggregate query tells you
whether this is one bad store or a downstream outage.

### Decision table

The handlers classify the failure for you. `error_type` is the exception class name, and the two
that matter are **`TransientError`** and **`PermanentError`** — the `outcome` field carries the same
verdict as `transient_failure` / `permanent_failure`. `reason` is the exact string raised by the
handler, and it is stable across deploys, so you can filter on it literally.

| `error_type` | `reason` (exact strings from `lambda/common/`) | `outcome` | Classification | Retrying helps? | Go to |
|---|---|---|---|---|---|
| `TransientError` | `loyalty API returned 503` | `transient_failure` | **Transient** — loyalty platform outage | Yes | §5 Path A |
| `TransientError` | `tax authority returned 429` | `transient_failure` | **Transient** — tax API rate limit | Yes, but redrive slowly | §5 Path A |
| `TransientError` | `idempotency store unavailable: ProvisionedThroughputExceededException` (or another DynamoDB error code) | `transient_failure` | **Transient** — the idempotency table, not the downstream | Yes, **after** fixing table capacity | §5 Path A, and fix DynamoDB first |
| `PermanentError` | `items is null (POS firmware v2.3 poison message)` | `permanent_failure` | **Permanent (poison)** — the canonical firmware case | **No** | §6 Path B |
| `PermanentError` | `body is not valid JSON: ...` / `body is not a JSON object` / `record has no body` | `permanent_failure` | **Permanent (poison)** | **No** | §6 Path B |
| `PermanentError` | `transaction_id is missing or empty` | `permanent_failure` | **Permanent (poison)** — and untraceable, so archive it carefully | **No** | §6 Path B |
| `PermanentError` | `items field is missing` / `items is not a list` / `items is empty` | `permanent_failure` | **Permanent (poison)** | **No** | §6 Path B |
| `PermanentError` | `items[N].sku is missing or empty` / `items[N].qty is missing or not a number` / `items[N].qty must be greater than zero` / `items[N].unit_price must not be negative` | `permanent_failure` | **Permanent (poison)** | **No** | §6 Path B |
| `PermanentError` | `items[N].qty is negative (...): would inflate stock on hand` | `permanent_failure` | **Permanent (poison)** — inventory-specific guard | **No** | §6 Path B |
| `PermanentError` | `total_amount is missing or not a number` / `total_amount must not be negative` | `permanent_failure` | **Permanent (poison)** | **No** | §6 Path B |
| Any other class (`ClientError`, `KeyError`, `TypeError`, ...) | `unhandled exception: <message>` | `transient_failure` | **Unclassified** — the handler did not anticipate it, so it defaults to the retryable side | Read the message before deciding | Treat as transient only if the message names a dependency; otherwise §9 and involve Cloud Platform |
| `ClientError` | `unhandled exception: ... AccessDenied ...` | `transient_failure` | **Permanent in practice** until IAM changes — it will fail identically on every retry | No | §9 escalate to Cloud Platform / Security, then §5 once the policy is fixed |
| `ClientError` | `unhandled exception: ... KMS ... (KMSAccessDeniedException, KeyUnavailableException)` | `transient_failure` | **Permanent until Security acts** | No | §7 checks apply; escalate to Security (**R/A** for KMS) |
| *(no `outcome` line at all for the `message_id`, only a `Task timed out after ...` line)* | — | — | **Transient**, usually | Yes, once the downstream is healthy | §5 Path A, and check [Trap 2](#trap-2--visibility-timeout-must-be-at-least-6x-the-lambda-timeout) |
| `null` | `null`, with `outcome = "duplicate_skipped"` | `duplicate_skipped` | **Not a failure** | — | Idempotency working as designed. If the DLQ still has depth, the failures are elsewhere — widen the time window. |

> **Watch the "unhandled exception" rows — this is the one place `outcome` can mislead you.**
> Anything the handler did not explicitly classify is logged with `outcome = "transient_failure"`
> and is therefore retried and redriven by default. That default is deliberate and correct: a bug
> in our own code is fixed by a redeploy and the transaction then succeeds, whereas misclassifying
> a valid transaction as poison would archive and delete real revenue. But it means
> `transient_failure` is **not** proof that waiting will help.
>
> **The concrete tell:** if `reason` starts with `unhandled exception:` **and** the message names a
> permissions error — `AccessDenied`, `AccessDeniedException`, `UnauthorizedOperation`,
> `KMSAccessDeniedException`, `KeyUnavailableException`, `NotAuthorized` — then **no amount of
> waiting will fix it and a redrive will fail exactly the same way**, burning another full
> `maxReceiveCount` cycle and more of the message's retention. Fix the permission first (IAM policy,
> queue policy, or KMS key policy — Security is **R/A** for the latter two), confirm with a §5
> Step 1 canary, and only then redrive.
>
> Grep for it directly:
>
> ```
> filter outcome = "transient_failure" and reason like /unhandled exception/
> | stats count(*) as attempts, count_distinct(transaction_id) as transactions by error_type, reason
> | sort attempts desc
> | limit 20
> ```

> **The mixed case is the common case.** A DLQ with 50 messages from a 40-minute loyalty outage
> plus 3 firmware-v2.3 poison messages needs **both** paths: run §5 for the transient bulk, then
> §6 for the 3 that come straight back. Expect a second, smaller alarm after the redrive — that
> is the poison set surfacing, not a regression.

Split a mixed DLQ before you act, so you know the size of each half:

```
stats count(*) as attempts, count_distinct(transaction_id) as transactions by outcome, error_type, reason
| sort transactions desc
| limit 20
```

### Query 1 — Trace one `transaction_id` across every attempt (serves R5)

Run in CloudWatch Logs Insights against the log group `/aws/lambda/pos-<service>-fn`. Replace the
`transaction_id` literal with yours.

```
fields @timestamp, service, transaction_id, store_id, message_id, outcome, error_type, reason, attempt
| filter transaction_id = "TXN-JB012-20260911-000123"
| sort @timestamp asc
| limit 100
```

You should see one line per delivery attempt, with `attempt` climbing to `maxReceiveCount`. If the
last line's `outcome` is `transient_failure`, you are in Path A. If it is `permanent_failure`, you
are in Path B. If the `attempt` numbers stop short of `maxReceiveCount`, the function was killed
before it could log — check for `Task timed out` in the same window.

### Query 2 — Aggregate `outcome` by `reason` over the last hour (one bad store or an outage?)

```
filter outcome in ["permanent_failure", "transient_failure"]
| stats count(*) as attempts,
        count_distinct(transaction_id) as transactions,
        count_distinct(store_id) as stores,
        earliest(@timestamp) as first_seen,
        latest(@timestamp) as last_seen
      by outcome, error_type, reason
| sort attempts desc
| limit 20
```

How to read the result:

| Pattern | Conclusion |
|---|---|
| One `reason`, `stores` is large (double digits, tracking your active store count), `outcome = transient_failure` | **Downstream outage.** Every store is hitting the same wall. Path A. |
| One `reason`, `stores` is 1–3, `outcome = permanent_failure` | **One bad store or one bad firmware build.** Path B, and the store list is what you hand Store Ops. |
| `last_seen` is within the last minute | The failure is **still happening**. Do not redrive yet — §5 Step 1 first. |
| `last_seen` is 20+ minutes ago and `first_seen` bounds a discrete window | The incident is **over**; you are cleaning up after it. |

### Query 3 — Which stores, for the Store Ops handoff

```
filter outcome = "permanent_failure"
| stats count(*) as failures,
        count_distinct(transaction_id) as transactions
      by store_id, error_type, reason
| sort failures desc
| limit 50
```

### Running the queries from the CLI (when the console is unavailable)

Logs Insights takes epoch **seconds** for `--start-time` / `--end-time`. Start the query, then poll
for results — `start-query` returns only a `queryId`.

```bash
# macOS (BSD date). On GNU/Linux use: START=$(date -d '-1 hour' +%s)
START=$(date -v-1H +%s)
END=$(date +%s)

QID=$(aws logs start-query \
  --region ap-southeast-1 \
  --log-group-name "/aws/lambda/pos-${SERVICE}-fn" \
  --start-time "${START}" \
  --end-time "${END}" \
  --query-string 'fields @timestamp, service, transaction_id, store_id, message_id, outcome, error_type, reason, attempt
| filter transaction_id = "'"${TXN_ID}"'"
| sort @timestamp asc
| limit 100' \
  --query queryId --output text)

echo "queryId=${QID}"

# Poll until Status is Complete (usually 2-5 seconds)
until [ "$(aws logs get-query-results --query-id "${QID}" --region ap-southeast-1 --query status --output text)" = "Complete" ]; do
  sleep 2
done

aws logs get-query-results --query-id "${QID}" --region ap-southeast-1 \
  | jq -r '.results[] | map({(.field): .value}) | add
           | [.["@timestamp"], .outcome, .error_type, .attempt, .reason] | @tsv'
```

The same wrapper runs Query 2 — swap the `--query-string`:

```bash
QID=$(aws logs start-query \
  --region ap-southeast-1 \
  --log-group-name "/aws/lambda/pos-${SERVICE}-fn" \
  --start-time "$(date -v-1H +%s)" --end-time "$(date +%s)" \
  --query-string 'filter outcome in ["permanent_failure", "transient_failure"]
| stats count(*) as attempts, count_distinct(transaction_id) as transactions, count_distinct(store_id) as stores, earliest(@timestamp) as first_seen, latest(@timestamp) as last_seen by outcome, error_type, reason
| sort attempts desc
| limit 20' \
  --query queryId --output text)
```

> **Field names are contractual.** The handlers emit exactly one structured JSON line per record
> with the keys `service`, `transaction_id`, `store_id`, `message_id`, `outcome`, `error_type`,
> `reason`, `attempt`. Logs Insights auto-discovers top-level JSON keys, so you filter on bare
> names (`transaction_id`), not `@message`. If a query returns nothing, check for a typo in a field
> name before concluding there were no failures — a misspelled field silently matches zero rows.

---

## 5. Path A — Transient Failure (Downstream Outage)

Use when §4 classified the failure as transient: the code and the messages are fine, the thing they
were calling was not.

**Order matters. Never redrive into a downstream that is still broken** — you will burn the full
retry window again and land the same messages back in the DLQ, older by another 15 minutes of
retention.

### Step 1 — Confirm the downstream has actually recovered

Do all three of these. Any one on its own can lie to you.

**1a. The failures have stopped in the logs.** Re-run Query 2 from §4 over the **last 10 minutes**
and confirm zero rows, or that `last_seen` is well before now:

```bash
QID=$(aws logs start-query --region ap-southeast-1 \
  --log-group-name "/aws/lambda/pos-${SERVICE}-fn" \
  --start-time "$(date -v-10M +%s)" --end-time "$(date +%s)" \
  --query-string 'filter outcome = "transient_failure"
| stats count(*) as attempts, latest(@timestamp) as last_seen by error_type, reason
| limit 10' --query queryId --output text)
sleep 5 && aws logs get-query-results --query-id "${QID}" --region ap-southeast-1 | jq '.results'
```

**1b. Live traffic is succeeding.** Stores are still transacting; confirm the source queue is
draining and `outcome="processed"` lines are being written right now:

```bash
aws sqs get-queue-attributes --queue-url "${SRC_URL}" \
  --attribute-names ApproximateNumberOfMessages ApproximateAgeOfOldestMessage \
  --region ap-southeast-1 --output json
```

`ApproximateNumberOfMessages` should be at or near zero and `ApproximateAgeOfOldestMessage` should
be small (seconds, not minutes). A source queue that is still backed up means the consumer is not
keeping up and a redrive will make it worse.

**1c. The owning team confirms.** Per the RACI, the Loyalty team is **Accountable** for the decision
that replay is safe on `pos-loyalty-dlq`; Finance is Accountable for `pos-einvoice-dlq`. Get that
confirmation in writing in the incident channel before Step 3. You are Responsible for executing —
you are not Accountable for the decision.

> **If there is no live traffic to judge by** (off-hours, or you drained the source queue), send a
> controlled canary instead of guessing:
>
> ```bash
> python3 scripts/pos_simulator.py --mode normal --count 1 --region ap-southeast-1
> ```
>
> The simulator resolves the topic ARN from `terraform output` in `terraform/` unless you pass
> `--topic-arn`. Confirm a single `outcome="processed"` line appears for the printed
> `transaction_id`. One message is enough; do not canary with fifty, and never canary with
> `--mode poison`.

### Step 2 — Deploy or flip the fix

For the drill scenario, the "fix" is turning the simulated outage off — the Loyalty function's
`LOYALTY_API_DOWN` environment variable goes back to `false`.

The pipeline is Terraform-managed, so the durable fix is in `terraform/`:

```bash
# From the repository root. Cloud Platform owns this change.
terraform -chdir=terraform plan  -var 'loyalty_api_down=false'
terraform -chdir=terraform apply -var 'loyalty_api_down=false'    # Boss approval required
```

> **Terraform is the source of truth.** If you flip the variable with the CLI
> (`aws lambda update-function-configuration --function-name pos-loyalty-fn --environment
> 'Variables={LOYALTY_API_DOWN=false}'`) to shorten an outage, that is acceptable as a break-glass
> action — but you have created drift, and the next `terraform apply` will silently revert it.
> Record it in the incident channel and follow up with the Terraform change in the same shift.

Confirm the live configuration before moving on:

```bash
aws lambda get-function-configuration \
  --function-name pos-${SERVICE}-fn \
  --region ap-southeast-1 \
  --query 'Environment.Variables' --output json
```

For a real code fix rather than a flag, confirm the deployed version is the fixed one:

```bash
aws lambda get-function-configuration --function-name pos-${SERVICE}-fn \
  --region ap-southeast-1 --query '{Version:Version,LastModified:LastModified,CodeSha256:CodeSha256}'
```

### Step 3 — Check no redrive is already running

Only **one active message movement task per queue** is allowed. Starting a second returns an error,
and more usefully, a running task means a colleague is already on this.

```bash
aws sqs list-message-move-tasks \
  --source-arn "${DLQ_ARN}" \
  --max-results 10 \
  --region ap-southeast-1 \
  --output json | jq '.Results[] | {Status, SourceArn, DestinationArn, ApproximateNumberOfMessagesMoved, ApproximateNumberOfMessagesToMove, MaxNumberOfMessagesPerSecond, StartedTimestamp, FailureReason}'
```

If a task shows `Status: RUNNING`, stop. Coordinate in the incident channel. To cancel one
deliberately:

```bash
HANDLE=$(aws sqs list-message-move-tasks --source-arn "${DLQ_ARN}" --region ap-southeast-1 \
  --query 'Results[0].TaskHandle' --output text)
aws sqs cancel-message-move-task --task-handle "${HANDLE}" --region ap-southeast-1
```

### Step 4 — Record the "before" numbers

You cannot prove zero loss in §8 without them.

```bash
aws sqs get-queue-attributes --queue-url "${DLQ_URL}" \
  --attribute-names ApproximateNumberOfMessages --region ap-southeast-1 \
  --query 'Attributes.ApproximateNumberOfMessages' --output text | tee /tmp/dlq-depth-before.txt

aws dynamodb scan --table-name pos-processed-transactions --select COUNT \
  --region ap-southeast-1 --query 'Count' --output text | tee /tmp/ddb-count-before.txt
```

### Step 5 — Dry run the redrive

```bash
./scripts/redrive.sh --source-arn "${DLQ_ARN}" --dry-run
```

`--source-arn` is the **DLQ**, because the DLQ is the source of the *move*. This trips people up:
you are not naming the queue you want messages to end up in.

The dry run prints the DLQ depth and the exact command it would run. **Read it.** Confirm the ARN
is the DLQ you triaged — a redrive to the wrong destination is not reversible.

### Step 6 — Execute the redrive

```bash
./scripts/redrive.sh --source-arn "${DLQ_ARN}" --yes
```

Full options: `--source-arn` (required), `--destination-arn` (default: each message's original
source queue), `--region` (default `ap-southeast-1`), `--rate` (default `10`), `--yes`,
`--dry-run`. Run `./scripts/redrive.sh --help` for the current list.

> **Leave `--destination-arn` and `--rate` alone unless you have a specific reason.** Omitting the
> destination sends each message back to its own source queue, which the DLQ's redrive *allow*
> policy already constrains to `pos-<service>-queue`. Overriding `--rate` is a deliberate decision
> that belongs in the incident channel — see the rationale below.

`scripts/redrive.sh` wraps:

```bash
aws sqs start-message-move-task \
  --source-arn "${DLQ_ARN}" \
  --destination-arn "${SRC_ARN}" \
  --max-number-of-messages-per-second 10 \
  --region ap-southeast-1
```

and then polls `list-message-move-tasks` until `Status` is `COMPLETED` (or `FAILED` /
`CANCELLED`). Watch it to completion; do not background it and walk away.

> **`--destination-arn` is optional but we always set it.** Left blank, SQS redrives each message
> back to "its respective original source queue", which is what we want — but being explicit means
> the dry run can show you the destination and the command is self-documenting in the incident log.

To poll manually if the script is interrupted:

```bash
watch -n 5 'aws sqs list-message-move-tasks --source-arn '"${DLQ_ARN}"' --region ap-southeast-1 \
  --query "Results[0].{Status:Status,Moved:ApproximateNumberOfMessagesMoved,ToMove:ApproximateNumberOfMessagesToMove,Failure:FailureReason}" --output table'
```

### Why the redrive is rate-limited at 10 messages per second

Left unset, `StartMessageMoveTask` "optimizes the rate based on the queue message backlog size" —
which in practice means it moves as fast as it can, up to 500 msg/s. That is the wrong behaviour
here for three compounding reasons:

1. **The downstream just came back up.** A loyalty platform recovering from a 40-minute outage is
   already absorbing the live 6,000 tx/hour (~1.7/s) *plus* whatever its own backlog is. Firing a
   500/s replay at it re-breaks the thing you just waited for, and now you have a second outage
   that you caused — with the DLQ refilling behind it.
2. **Lambda scales with the queue.** A sudden burst of thousands of visible messages makes the
   event source mapping scale out hard. At high enough concurrency you hit the account limit, other
   functions in the account get throttled, and throttled invocations are themselves retries that
   burn `maxReceiveCount`.
3. **10 msg/s is calibrated, not arbitrary.** It is roughly 6× the normal 1.7 msg/s steady rate —
   fast enough to clear a 50-message drill backlog in 5 seconds and a 10,000-message backlog in
   under 20 minutes, slow enough to stay well inside what the downstream handles on a normal peak
   day (25,000/hour ≈ 7 msg/s). If you need it faster, raise it deliberately and say so in the
   incident channel; do not remove the flag.

> For a very large backlog (tens of thousands), raise the rate in steps — 10 → 25 → 50 — watching
> Lambda `Errors` and `Throttles` between steps, and be ready to `cancel-message-move-task`.

### Why idempotency is a prerequisite for redrive (R4)

SQS is **at-least-once**. A redrive is a deliberate second delivery of messages that may already
have been *partially* processed — the loyalty API call can have succeeded on the server side and
then timed out on the client side, so the record failed from the consumer's point of view while the
points were already awarded.

Without idempotency, redriving that message awards the points **again**. Fifty replayed
transactions become fifty double-awards, and you have converted a "my points never arrived"
complaint into a reconciliation problem across the loyalty ledger — worse than the original
incident, and entirely self-inflicted. That is exactly what **R4** exists to prevent.

The protection is the DynamoDB conditional write in the handler: before doing any work, it puts
`transaction_id` into `pos-processed-transactions` with
`ConditionExpression: attribute_not_exists(transaction_id)`. If the item already exists the
condition fails, the handler logs `outcome="duplicate_skipped"` and returns success without calling
the downstream. Items carry a 7-day TTL.

**Verify idempotency is healthy before you redrive:**

```bash
# Table is ACTIVE and TTL is enabled on the right attribute
aws dynamodb describe-table --table-name pos-processed-transactions \
  --region ap-southeast-1 --query '{Status:Table.TableStatus,Keys:Table.KeySchema,Items:Table.ItemCount}'
aws dynamodb describe-time-to-live --table-name pos-processed-transactions --region ap-southeast-1

# The sample transaction's guard row exists (or does not) as expected
aws dynamodb get-item --table-name pos-processed-transactions \
  --key "{\"transaction_id\":{\"S\":\"${TXN_ID}\"}}" \
  --region ap-southeast-1 --output json
```

> **The 7-day TTL is a hard limit on safe replay.** If a DLQ message is older than 7 days, its
> idempotency guard row may already have expired, and a redrive can genuinely double-process it.
> This is why the `pos-<service>-dlq-message-aging` alarm is set at 7 days and not at 13: past that
> point, redrive is no longer automatically safe, and you must reconcile with the owning team
> (Loyalty or Finance) before replaying. Treat the aging alarm as "the safe-replay window is
> closing", not "the message is about to expire".

### Step 7 — Verify

Go to [§8 Verification](#8-verification-after-any-action). Do not close the incident until §8
passes.

---

## 6. Path B — Permanent Failure (Poison Message)

Use when §4 classified the failure as permanent — the canonical case being POS firmware v2.3
sending `items: null`:

```json
{ "transaction_id": "TXN-PG004-20260911-000871", "store_id": "PG004",
  "items": null, "total_amount": 12.80, "firmware_version": "2.3.0" }
```

> **Do not redrive a poison message straight back to the source queue.** It will fail exactly the
> same way it failed before — nothing about the message or the code has changed. It will burn
> another full retry cycle (5 receives for loyalty and inventory, 8 for e-invoice), consume that
> many more Lambda invocations, land back in the DLQ minutes later with a higher
> `ApproximateReceiveCount` and *less* retention left, and fire the alarm again. That loop is the
> 2026 incident in miniature: hundreds of thousands of wasted invocations for messages that were
> never going to succeed. A poison message is only replayable after the **handler** or the
> **producer** has been fixed — and at that point it is a deployment, not a redrive decision.

The order is **archive → notify → purge**. Never delete before archiving; the message is the only
record of the transaction that exists outside the store's terminal.

### Step 1 — Archive to S3 before deleting anything

The archive bucket is `pos-dlq-archive-<account-id>`, defined in `terraform/s3.tf` and exposed as
the Terraform output `dlq_archive_bucket`. It has SSE-S3 (AES256) encryption, versioning enabled,
and all four public-access blocks on.

```bash
export ARCHIVE_BUCKET="pos-dlq-archive-${ACCOUNT_ID}"
# or, from the repository root:  ARCHIVE_BUCKET=$(terraform -chdir=terraform output -raw dlq_archive_bucket)
export ARCHIVE_PREFIX="poison/${SERVICE}/$(date -u +%Y/%m/%d)/$(date -u +%H%M%S)"
mkdir -p /tmp/dlq-archive && cd /tmp/dlq-archive

# Confirm the bucket exists and you can write to it BEFORE you start receiving messages
aws s3api head-bucket --bucket "${ARCHIVE_BUCKET}" --region ap-southeast-1
```

> **Run the `head-bucket` check every time, even though the bucket is in Terraform.** A resource
> existing in code is not the same as existing in AWS — if the stack has not been applied, or was
> applied to a different account, `head-bucket` fails and you find out *before* you have drained a
> DLQ into a local file you are about to lose. If it fails mid-incident, stop: the local
> `archive.ndjson` is then your only copy, and no DLQ message gets deleted until that file is
> somewhere durable that a colleague can reach.

> **You archive with your own credentials, not the pipeline's.** The consumer Lambda execution
> roles have **no S3 access at all** — deliberately, so a buggy or compromised consumer cannot
> tamper with the evidence trail it is supposed to preserve. Path B therefore runs entirely under
> the operator's IAM identity. If `s3 cp` returns `AccessDenied`, the problem is your own
> permissions, not the pipeline's.

> **The archive is not permanent.** A lifecycle rule expires current objects at **90 days** and
> noncurrent versions 90 days after they become noncurrent, so an archived poison batch is gone
> roughly three months after you write it. That window covers a firmware-upgrade cycle and any
> immediate follow-up audit. **If a batch carries a longer compliance obligation — e-invoice
> transactions in particular, which Finance owns — a separate copy must be taken into whatever
> system holds that retention.** Say so explicitly in the handoff; do not assume the bucket is the
> system of record.

Drain the DLQ into a local newline-delimited JSON file, keeping the system attributes so the
archive records the receive counts and timestamps as well as the body:

```bash
: > archive.ndjson
while :; do
  BATCH=$(aws sqs receive-message \
    --queue-url "${DLQ_URL}" \
    --attribute-names All \
    --message-attribute-names All \
    --max-number-of-messages 10 \
    --visibility-timeout 300 \
    --wait-time-seconds 5 \
    --region ap-southeast-1)
  COUNT=$(echo "${BATCH}" | jq '.Messages | length // 0')
  [ "${COUNT}" -eq 0 ] && break
  echo "${BATCH}" | jq -c '.Messages[] | {MessageId, Body, Attributes, MessageAttributes}' >> archive.ndjson
  echo "${BATCH}" | jq -r '.Messages[].ReceiptHandle' >> receipts.txt
  echo "archived ${COUNT} (total $(wc -l < archive.ndjson))"
done
wc -l archive.ndjson
```

> **Note the `--visibility-timeout 300` here** — this is the one place you deliberately *do* hide
> the messages. Five minutes gives you a window to archive and then delete by receipt handle
> without the same message being handed to you twice in the loop. Receipt handles expire with the
> visibility timeout, so finish Step 3 inside that window or re-receive.

Upload the archive:

```bash
aws s3 cp archive.ndjson \
  "s3://${ARCHIVE_BUCKET}/${ARCHIVE_PREFIX}/archive.ndjson" \
  --region ap-southeast-1

# Write a manifest alongside it so the archive is self-describing
jq -n --arg svc "${SERVICE}" --arg dlq "${DLQ_ARN}" --arg when "$(date -u +%FT%TZ)" \
      --arg who "$(aws sts get-caller-identity --query Arn --output text)" \
      --argjson count "$(wc -l < archive.ndjson)" \
      '{service:$svc, dlq_arn:$dlq, archived_at:$when, archived_by:$who, message_count:$count, classification:"permanent_failure", incident:"INC-REPLACE-ME"}' \
  > manifest.json
aws s3 cp manifest.json "s3://${ARCHIVE_BUCKET}/${ARCHIVE_PREFIX}/manifest.json" --region ap-southeast-1

# Confirm both objects landed before you delete anything
aws s3 ls "s3://${ARCHIVE_BUCKET}/${ARCHIVE_PREFIX}/" --region ap-southeast-1
```

Produce the store/transaction list you will hand to Store Ops:

```bash
jq -r '.Body | fromjson | [.transaction_id, .store_id, .terminal_id, .firmware_version, (.total_amount|tostring)] | @tsv' \
  archive.ndjson | sort | tee /tmp/poison-transactions.tsv

jq -r '.Body | fromjson | .store_id' archive.ndjson | sort | uniq -c | sort -rn
```

### Step 2 — Notify, per the RACI

| Who | Why | What they get |
|---|---|---|
| **Store Ops** — **R/A** for "poison messages → firmware upgrade" | They own the fix: rolling POS firmware forward off v2.3 | `/tmp/poison-transactions.tsv`, the affected `store_id` / `terminal_id` list, the firmware version, and the S3 archive URI |
| **Loyalty team** (`pos-loyalty-dlq`) or **Finance** (`pos-einvoice-dlq`) | They are Accountable for what happens to the business record — an unfiled e-invoice is a compliance item Finance must decide on | The same list, plus the count and value of affected transactions |
| **Cloud Platform** (you) — I on the firmware fix | You track the archive location and close the incident | Incident note with the S3 prefix |

Suggested notification text:

> `pos-<service>-dlq` received **N** permanently-failing messages between `<first_seen>` and
> `<last_seen>`, all from store(s) `<store_ids>` running firmware `2.3.0`, all failing schema
> validation with `items: null`. These cannot be replayed as-is. Messages are archived at
> `s3://<bucket>/<prefix>/archive.ndjson`. **Store Ops: please upgrade firmware on the listed
> terminals.** Once firmware is upgraded, new transactions will be well-formed; the archived ones
> need a business decision on manual re-entry.

> **e-Invoice messages are tax filings.** Finance is Accountable for reviewing `pos-einvoice-dlq`
> contents. Do not purge that DLQ on your own authority, even after archiving — get Finance's
> explicit sign-off in the incident channel first.

### Step 3 — Purge

Only after the archive is confirmed in S3 and the notification is sent.

**Preferred — delete by receipt handle**, because it removes exactly the messages you archived and
nothing that may have arrived since:

```bash
while read -r RH; do
  aws sqs delete-message --queue-url "${DLQ_URL}" --receipt-handle "${RH}" --region ap-southeast-1
done < receipts.txt
```

**Alternative — `purge-queue`**, only when you are certain the DLQ contains nothing but the
archived poison set:

```bash
aws sqs purge-queue --queue-url "${DLQ_URL}" --region ap-southeast-1
```

> **`purge-queue` caveats.** It deletes **every** message in the queue, including any that arrived
> in the seconds since you archived — those are gone with no record, which is a direct R1
> violation. It is also rate-limited to **once every 60 seconds per queue**, and deletion is
> asynchronous: messages sent *before* the purge call can still be deleted for up to 60 seconds
> afterwards. Prefer receipt-handle deletion. If the DLQ is a mixed bag of poison and transient
> messages, `purge-queue` is simply the wrong tool — run Path A first, then archive and
> receipt-delete what comes back.

### Step 4 — Verify

Go to [§8 Verification](#8-verification-after-any-action). For Path B, "zero loss" means the
messages exist in S3, not that they were processed.

---

## 7. Path C — `pos-sns-delivery-dlq` Is Non-Empty

This is a **different class of failure** and none of §3–§6 applies to it.

An SQS DLQ attached via a redrive policy catches **consumer** failures: the message reached
`pos-<service>-queue`, Lambda tried and failed `maxReceiveCount` times. `pos-sns-delivery-dlq` is
attached to the **SNS subscription**, and it catches the case where SNS **could not hand the
message to the queue at all**. The message never existed in `pos-loyalty-queue`. No consumer ever
saw it. Nothing in the Lambda logs will mention it, so §4's Logs Insights queries will come back
empty — that emptiness is the diagnostic signal, not a mistake on your part.

Usual causes, in order of likelihood:

1. A **queue policy** that no longer allows `sns.amazonaws.com` to `sqs:SendMessage` (often a
   Terraform change that dropped or narrowed the `aws:SourceArn` condition)
2. A **KMS key policy** that does not allow SNS to `kms:GenerateDataKey` / `kms:Decrypt` on the
   queue's encryption key, or a disabled/deleted key
3. The destination queue was **deleted or renamed** while the subscription still points at it
4. An SNS **filter policy or delivery-policy** change that made the subscription invalid

### Check 1 — How deep, and what is in there

```bash
export SNSDLQ_URL="https://sqs.${AWS_REGION}.amazonaws.com/${ACCOUNT_ID}/pos-sns-delivery-dlq"

aws sqs get-queue-attributes --queue-url "${SNSDLQ_URL}" \
  --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible ApproximateAgeOfOldestMessage \
  --region ap-southeast-1 --output json

aws sqs receive-message --queue-url "${SNSDLQ_URL}" \
  --attribute-names All --message-attribute-names All \
  --max-number-of-messages 1 --visibility-timeout 0 \
  --region ap-southeast-1 | jq '.Messages[0]'
```

Messages here arrive with SNS metadata attached. Look for the message attributes that name the
failing endpoint and the reason — typically `ERROR_CODE`, `ERROR_MESSAGE`, `RETRY_COUNT`, and the
subscription/endpoint ARN. **The endpoint ARN tells you which of the three queues is broken.**

```bash
aws sqs receive-message --queue-url "${SNSDLQ_URL}" \
  --attribute-names All --message-attribute-names All \
  --max-number-of-messages 10 --visibility-timeout 0 --region ap-southeast-1 \
  | jq -r '.Messages[].MessageAttributes | to_entries | map("\(.key)=\(.value.StringValue)") | join(" | ")'
```

### Check 2 — The subscriptions and their redrive policies

```bash
export TOPIC_ARN="arn:aws:sns:${AWS_REGION}:${ACCOUNT_ID}:pos-transactions"

aws sns list-subscriptions-by-topic --topic-arn "${TOPIC_ARN}" --region ap-southeast-1 \
  --query 'Subscriptions[].{Endpoint:Endpoint,Arn:SubscriptionArn}' --output table

# For each subscription ARN, confirm RawMessageDelivery and the subscription-level RedrivePolicy
for SUB in $(aws sns list-subscriptions-by-topic --topic-arn "${TOPIC_ARN}" --region ap-southeast-1 \
             --query 'Subscriptions[].SubscriptionArn' --output text); do
  echo "=== ${SUB}"
  aws sns get-subscription-attributes --subscription-arn "${SUB}" --region ap-southeast-1 \
    --query 'Attributes.{Endpoint:Endpoint,Raw:RawMessageDelivery,Redrive:RedrivePolicy,Filter:FilterPolicy,Confirmed:ConfirmationWasAuthenticated}'
done
```

### Check 3 — The destination queue policy (most likely culprit)

```bash
aws sqs get-queue-attributes \
  --queue-url "https://sqs.${AWS_REGION}.amazonaws.com/${ACCOUNT_ID}/pos-${SERVICE}-queue" \
  --attribute-names Policy QueueArn KmsMasterKeyId SqsManagedSseEnabled \
  --region ap-southeast-1 \
  | jq -r '.Attributes.Policy' | jq '.'
```

The policy must contain a statement that:

- `Effect: Allow`, `Principal: {"Service": "sns.amazonaws.com"}`, `Action: "sqs:SendMessage"`
- `Resource` equal to the queue ARN
- `Condition.ArnEquals."aws:SourceArn"` equal to `arn:aws:sns:ap-southeast-1:<account-id>:pos-transactions`

A **mismatched `aws:SourceArn`** is the single most common cause — a typo, or a topic that was
recreated with a new ARN. If the statement is missing entirely, the queue policy was dropped;
restore it from `terraform/` (`terraform -chdir=terraform plan` will show the drift).

### Check 4 — KMS, if the queue uses a customer managed key

```bash
KEY_ID=$(aws sqs get-queue-attributes \
  --queue-url "https://sqs.${AWS_REGION}.amazonaws.com/${ACCOUNT_ID}/pos-${SERVICE}-queue" \
  --attribute-names KmsMasterKeyId --region ap-southeast-1 \
  --query 'Attributes.KmsMasterKeyId' --output text)
echo "key=${KEY_ID}"

aws kms describe-key --key-id "${KEY_ID}" --region ap-southeast-1 \
  --query 'KeyMetadata.{State:KeyState,Enabled:Enabled,Manager:KeyManager}'

aws kms get-key-policy --key-id "${KEY_ID}" --policy-name default \
  --region ap-southeast-1 --query Policy --output text | jq '.'
```

The key policy must allow `sns.amazonaws.com` to call `kms:GenerateDataKey*` and `kms:Decrypt`. If
the key is `Disabled` or `PendingDeletion`, that is your answer.

> **Security is R/A for "KMS encryption / queue policy audit".** If the cause is a key policy or a
> queue policy change you did not make, escalate to Security rather than editing the policy
> yourself — the change may have been deliberate.

### Check 5 — The SNS-side metrics confirm the picture

```bash
aws cloudwatch get-metric-statistics \
  --namespace AWS/SNS --metric-name NumberOfNotificationsFailed \
  --dimensions Name=TopicName,Value=pos-transactions \
  --start-time "$(date -u -v-3H +%FT%TZ)" --end-time "$(date -u +%FT%TZ)" \
  --period 300 --statistics Sum --region ap-southeast-1 --output table
```

`NumberOfNotificationsFailedToRedriveToDlq` on the same topic is worth checking too — if that is
non-zero, SNS could not even write to `pos-sns-delivery-dlq`, and messages are being lost outright.
That is a **P1 with data loss in progress**; escalate immediately per §9.

### Recovering the messages in `pos-sns-delivery-dlq`

> **`StartMessageMoveTask` does not work here, and neither does `scripts/redrive.sh`.** The API
> accepts a `--source-arn` only when the DLQ's source is *another SQS queue* — the redrive policy
> on the source queue is what establishes that relationship. `pos-sns-delivery-dlq` has no redrive
> policy pointing at it from a queue; its source is an **SNS subscription**, so SQS has no
> destination to move messages back to and rejects the call outright.
>
> There is also nothing to move them *to*: these messages never reached `pos-<service>-queue` in
> the first place, so "returning" them to a source queue is not even the right mental model. The
> only way back into the pipeline is to **publish them again to `pos-transactions`** and let SNS
> fan out normally. That is a re-publish, not a redrive, and it is a different risk profile — it
> re-delivers to all three consumer lanes, so it is safe only because of idempotency.
> See [Trap 4](#trap-4--startmessagemovetask-only-redrives-sqs-to-sqs).

Recover manually, after the queue policy or key policy is fixed and verified:

```bash
# 1. Prove delivery works again with a single canary
python3 scripts/pos_simulator.py --mode normal --count 1 --region ap-southeast-1
# confirm it lands in the previously-broken queue and is processed

# 2. Archive the sns-delivery-dlq contents to S3 (use the §6 Step 1 loop against ${SNSDLQ_URL})

# 3. Re-publish each archived body to the topic, slowly
jq -r '.Body' archive.ndjson | while read -r BODY; do
  aws sns publish --topic-arn "${TOPIC_ARN}" --message "${BODY}" --region ap-southeast-1 >/dev/null
  sleep 0.1                       # ~10 msg/s, the same rate discipline as §5
done

# 4. Delete the archived messages from pos-sns-delivery-dlq by receipt handle (§6 Step 3)
```

> **Re-publishing goes to the topic, so it fans out to all three queues again.** The other two
> services will receive these transactions a second time. This is safe *only because* of
> idempotency — the loyalty, inventory and e-invoice handlers will log `duplicate_skipped` for the
> ones they already processed. Confirm the DynamoDB table is healthy (§5) before re-publishing, and
> confirm the `duplicate_skipped` counts afterwards in §8.

---

## 8. Verification After Any Action

Do not close the incident until every check below passes. The claim you are making is **zero loss
and zero duplicates** — R1 and R4. Prove it, do not assume it.

### Check 1 — DLQ depth is back to 0

```bash
aws sqs get-queue-attributes --queue-url "${DLQ_URL}" \
  --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible \
  --region ap-southeast-1 --output json
```

Both must be `0`. A non-zero `ApproximateNumberOfMessagesNotVisible` with a zero visible count
usually means an in-flight peek — wait out the visibility timeout and re-check rather than
declaring victory.

Confirm the alarms have returned to `OK`:

```bash
aws cloudwatch describe-alarms --alarm-name-prefix "pos-${SERVICE}-dlq" \
  --region ap-southeast-1 \
  --query 'MetricAlarms[].{Alarm:AlarmName,State:StateValue,Since:StateUpdatedTimestamp}' --output table
```

### Check 2 — The source queue drained

```bash
aws sqs get-queue-attributes --queue-url "${SRC_URL}" \
  --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible ApproximateAgeOfOldestMessage \
  --region ap-southeast-1 --output json
```

After a redrive, the source queue spikes and then drains. Poll every 30 seconds until
`ApproximateNumberOfMessages` is at its normal baseline and `ApproximateAgeOfOldestMessage` is
seconds, not minutes. If the DLQ starts filling again while the source drains, your classification
in §4 was wrong — go back to §4.

```bash
for i in $(seq 1 20); do
  printf '%s  src=%s  dlq=%s\n' "$(date +%T)" \
    "$(aws sqs get-queue-attributes --queue-url "${SRC_URL}" --attribute-names ApproximateNumberOfMessages --region ap-southeast-1 --query 'Attributes.ApproximateNumberOfMessages' --output text)" \
    "$(aws sqs get-queue-attributes --queue-url "${DLQ_URL}" --attribute-names ApproximateNumberOfMessages --region ap-southeast-1 --query 'Attributes.ApproximateNumberOfMessages' --output text)"
  sleep 30
done
```

### Check 3 — Logs Insights: `processed` count vs messages redriven

Run over a window that starts just before the redrive:

```
filter outcome in ["processed", "duplicate_skipped", "permanent_failure", "transient_failure"]
| stats count(*) as log_lines,
        count_distinct(transaction_id) as unique_transactions
      by outcome
| sort log_lines desc
```

Read it against the "before" depth you saved in `/tmp/dlq-depth-before.txt`:

| Expectation | Meaning |
|---|---|
| `processed.unique_transactions` + `duplicate_skipped.unique_transactions` == messages redriven | **Zero loss.** Every message you moved was accounted for. |
| `processed.log_lines` == `processed.unique_transactions` | **Zero duplicates.** No `transaction_id` was processed twice. If `log_lines` exceeds `unique_transactions`, the idempotency guard did not hold — stop and escalate to the Loyalty team (§9) before anyone reconciles points. |
| `duplicate_skipped` > 0 | **Expected and healthy** after a redrive of messages that had partially succeeded. This is the idempotency guard doing its job, and it is the evidence for R4. |
| `permanent_failure` > 0 after a Path A redrive | The poison subset surfaced. Run §6 for those `transaction_id`s. Not a failure of the redrive. |
| `transient_failure` > 0 after a Path A redrive | The downstream is **not** actually recovered. Stop redriving; go back to §5 Step 1. |

Per-transaction proof for the specific messages that were in the DLQ:

```
filter outcome = "processed"
| stats count(*) as times_processed by transaction_id
| filter times_processed > 1
| limit 50
```

> **This query must return zero rows.** Any row is a double-award — an R4 violation. Escalate
> immediately.

### Check 4 — DynamoDB shows one item per `transaction_id`

The table's partition key **is** `transaction_id`, so DynamoDB structurally cannot hold two items
for the same transaction. That is the point: the guard row is the thing that makes replay safe, and
its existence is the proof a transaction was claimed exactly once.

```bash
# Total guard rows now vs before the action
aws dynamodb scan --table-name pos-processed-transactions --select COUNT \
  --region ap-southeast-1 --query 'Count' --output text
cat /tmp/ddb-count-before.txt
```

The delta should equal the number of **newly** processed transactions — for a redrive of messages
that had already partially succeeded, the delta will be *smaller* than the number redriven, and the
shortfall should match the `duplicate_skipped` count from Check 3. That arithmetic closing is your
zero-duplicate proof.

Spot-check individual transactions from the DLQ sample:

```bash
for T in $(jq -r '.Body | fromjson | .transaction_id' /tmp/dlq-archive/archive.ndjson 2>/dev/null | head -20); do
  N=$(aws dynamodb get-item --table-name pos-processed-transactions \
        --key "{\"transaction_id\":{\"S\":\"${T}\"}}" \
        --region ap-southeast-1 --query 'Item.transaction_id.S' --output text 2>/dev/null)
  printf '%-40s %s\n' "${T}" "${N:-MISSING}"
done
```

`MISSING` means that transaction was never successfully claimed — it was neither processed nor
guarded. Combined with a zero DLQ depth, `MISSING` is the signature of actual message loss.
**Escalate per §9 immediately.**

> **TTL caveat on this check.** Guard rows expire after 7 days, and DynamoDB deletes them
> asynchronously (typically within 48 hours of expiry). A `MISSING` result for a transaction older
> than 7 days may be TTL expiry rather than loss. Cross-check against the Logs Insights
> `outcome="processed"` line for that `transaction_id` before declaring an incident — the log
> retention outlives the guard row.

### Check 5 — Write the incident record

Record in the incident channel and in the ticket:

| Field | Value |
|---|---|
| DLQ and depth before | `pos-<service>-dlq`, N messages |
| Classification | transient / permanent / delivery-failure, with the `error_type` and `reason` |
| Action taken | Path A redrive at 10 msg/s / Path B archive+purge / Path C policy fix |
| S3 archive URI | `s3://<bucket>/<prefix>/` (Path B and C only) |
| Processed / duplicate_skipped / still-failing counts | from Check 3 |
| DLQ depth after, alarm state | 0, `OK` |
| Follow-ups | firmware upgrade ticket, Terraform drift PR, etc. |

> If this was a non-trivial issue, it also gets an Obsidian vault note under
> `/Users/brendonang/Documents/Obsidian/AWS KB/Troubleshooting/` named `YYYY-MM-DD_slug.md`. Use
> the `/troubleshoot` command — it writes the note for you.

---

## 9. Escalation

Escalate on the clock, not on frustration. The thresholds below are derived from the RACI in §1 and
from R3 (alert within 5 minutes).

### Escalation ladder

| Elapsed since alarm | Condition | Escalate to | Why |
|---|---|---|---|
| **0–5 min** | Alarm fires | On-call Cloud/DevOps (you) acknowledges in `#mekarmart-ops` | Cloud Platform is **R/A** for first response to DLQ alarms. R3's 5-minute promise is only kept if someone answers. |
| **15 min** | §3 triage done, classification is transient and the downstream is still failing | **Loyalty team** (for `pos-loyalty-dlq`) — they are **R/A** for fixing loyalty platform issues | You cannot fix a third-party API. Hand it over early; you keep the queue side. |
| **15 min** | Any `pos-einvoice-dlq` alarm, regardless of classification | **Finance (e-Invoice)** — **R/A** for reviewing e-invoice DLQ messages | These are tax filings. Finance decides what happens to them; compliance exposure starts accruing immediately. |
| **30 min** | Classification is permanent / poison and the affected `store_id` list is known | **Store Ops** — **R/A** for firmware upgrades | Until firmware moves off v2.3 the DLQ will keep refilling. Every hour of delay is more poison messages. |
| **30 min** | `pos-sns-delivery-dlq` non-empty and the cause is a queue policy or KMS key policy you did not change | **Security** — **R/A** for KMS encryption / queue policy audit | The change may have been deliberate. Do not revert a security control unilaterally. |
| **60 min** | DLQ depth still non-zero and not trending down, any service | **Platform lead**, then declare an incident | An hour of a full DLQ means the standard runbook did not resolve it. |
| **Before any redrive** | Ready to run `scripts/redrive.sh` | **Loyalty team** (loyalty) or **Finance** (e-invoice) must confirm replay is safe | They are **A** on "Execute redrive". You are **R** — you execute, they authorise. This is not optional. |
| **Any time** | §8 Check 3 shows a `transaction_id` processed more than once, **or** §8 Check 4 shows `MISSING` | **Loyalty team + Platform lead immediately**, page if out of hours | A double-award or a lost transaction is exactly the failure mode this whole pipeline exists to prevent. Stop all redrives. |
| **Any time** | `NumberOfNotificationsFailedToRedriveToDlq` > 0 on `pos-transactions` | **Platform lead immediately**, page | SNS cannot even reach the delivery DLQ. Data is being lost right now. |
| **7 days** | `pos-<service>-dlq-message-aging` fires | **Owning team (Loyalty / Finance) same shift** | Past 7 days the idempotency guard rows have expired, so redrive is no longer automatically safe (§5). The decision to replay becomes a business decision. |
| **~13 days** | `ApproximateAgeOfOldestMessage` approaching 14 days | **Platform lead + owning team, treat as P1** | At 14 days SQS deletes the message. That is silent loss — the exact 2026 failure. There is no recovery after this point. |

### Contact routing

| Team | Channel | Out of hours |
|---|---|---|
| Cloud/DevOps Platform (on-call) | `#mekarmart-ops` | PagerDuty rotation `platform-oncall` |
| Loyalty team | `#loyalty-platform` | PagerDuty rotation `loyalty-oncall` |
| Finance (e-Invoice) | `#finance-einvoice` | Business hours; escalate via Platform lead |
| Store Ops | `#store-ops` | Business hours; escalate via Platform lead |
| Security | `#security-eng` | PagerDuty rotation `security-oncall` |

> Channel and rotation names above are placeholders for this lab — replace them with the real
> routing before this runbook is used in anger.

---

## 10. Known Traps

Each of these has bitten someone. The consequence column is what actually happens when you get it
wrong.

### Trap 1 — DLQ retention does not reset the expiry clock

For **Standard** queues, a message's expiry is measured from its **original enqueue timestamp**, and
moving it to a DLQ does **not** reset that timestamp. The DLQ's `MessageRetentionPeriod` is not a
fresh 14-day budget; it is a ceiling applied to a clock that has already been running.

```
   enqueue                 moved to DLQ                      expiry
      │◄──── 3 days in ────►│◄──────── 11 days left ────────►│
      │      pos-loyalty-   │          in pos-loyalty-dlq    │
      │      queue          │                                ▼
      ├─────────────────────┴────────────────────────────────┤
      0                                                     14 days
```

With source retention 4 days and DLQ retention 14 days, a message that sat 3 days in
`pos-loyalty-queue` has **11 days**, not 14, in `pos-loyalty-dlq`.

> **Consequence:** you plan your remediation against a 14-day deadline that does not exist, and the
> messages are silently deleted three days early. This is precisely the 2026 CNY failure mode.
> **Always compute the deadline from live `ApproximateAgeOfOldestMessage` (§3 Step 1), never from
> "when the alarm fired".** (FIFO queues *do* reset the timestamp on the move — we deliberately do
> not use FIFO here, so this does not help us.)

### Trap 2 — Visibility timeout must be at least 6x the Lambda timeout

The design sets visibility timeout to 6× the function timeout (`pos-loyalty-fn` 30 s → 180 s,
`pos-inventory-fn` 20 s → 120 s, `pos-einvoice-fn` 60 s → 360 s). Two separate rules are in play:

1. **Hard rule:** the function timeout must be **≤** the queue's visibility timeout. Lambda
   validates this when the event source mapping is created.
2. **Recommendation:** make it 6×, so a throttled invocation has room to be retried by the poller
   within one visibility window.

> **Consequence of breaking the hard rule:** `CreateEventSourceMapping` fails outright with an
> `InvalidParameterValueException` — a `terraform apply` that errors on the ESM resource while the
> queue and function are already created, leaving a half-built stack and a queue with **no
> consumer**. Messages pile up and eventually expire, uncollected, with no DLQ involvement at all
> because nothing ever received them.
>
> **Consequence of merely breaking the 6× recommendation** (e.g. visibility == function timeout):
> a slow-but-eventually-successful invocation can have its message become visible again and be
> delivered to a second invocation, so the same transaction is processed twice concurrently and
> `ApproximateReceiveCount` climbs on messages that are not actually failing — they reach the DLQ
> while succeeding. Idempotency saves you from double-awarding, but you get phantom DLQ traffic
> that wastes an on-call response.

### Trap 3 — Do not "fix" an outage by raising `maxReceiveCount`

The 2026 CNY loyalty outage lasted 40 minutes; the loyalty retry window is ~15 minutes
(5 receives × 180 s). The tempting fix is `maxReceiveCount = 15` to ride out longer outages.

> **Consequence:** every poison message now burns **15** invocations instead of 5 before it reaches
> the DLQ — a 3× increase in wasted invocations and in the time before the DLQ alarm fires, which
> directly degrades R3. You have also tripled the time before *any* failure becomes visible, which
> means longer outages are detected later, which is the opposite of what you wanted.
>
> **The right answer is to classify the error, not to tune the number.** A permanent failure should
> be recognised on the *first* attempt and quarantined immediately; a transient failure should be
> retried and then replayed via redrive after recovery. `maxReceiveCount` is a blunt instrument
> applied equally to both, so no single value is right. If you genuinely need to survive longer
> outages, the lever is the *redrive workflow* in §5 — which costs nothing while idle — not more
> retries.

### Trap 4 — `StartMessageMoveTask` only redrives SQS to SQS

The API accepts a `--source-arn` only where the DLQ's source is **another SQS queue**. From the CLI
documentation: *"Non-SQS queue sources of dead-letter queues, such as Lambda or Amazon SNS topics,
are currently not supported."*

| DLQ | Source | `StartMessageMoveTask` usable? |
|---|---|---|
| `pos-loyalty-dlq` | `pos-loyalty-queue` (SQS redrive policy) | **Yes** |
| `pos-inventory-dlq` | `pos-inventory-queue` | **Yes** |
| `pos-einvoice-dlq` | `pos-einvoice-queue` | **Yes** |
| `pos-sns-delivery-dlq` | SNS subscription on `pos-transactions` | **No** — §7 manual re-publish |
| A Lambda **asynchronous invocation** DLQ (`DeadLetterConfig` / on-failure destination) | Lambda async invoke queue | **No** |

> **Consequence:** you run `redrive.sh` against `pos-sns-delivery-dlq` during an incident, it fails
> with an `InvalidParameterValue`-class error, and you lose ten minutes debugging your own script
> instead of fixing the queue policy that caused the delivery failure. For those DLQs the recovery
> is a manual receive → re-publish loop (§7), and re-publishing goes to the **topic**, so it
> re-fans-out to all three services — safe only because of idempotency.

### Trap 5 — Peeking increments `ApproximateReceiveCount`

`ApproximateReceiveCount` counts receives *across queues*, and it does not care whether the receiver
was a Lambda poller or you with an AWS CLI on your laptop. Every `aws sqs receive-message` against
the DLQ adds one.

> **Consequence 1 — misdiagnosis.** You peek four times while triaging, see
> `ApproximateReceiveCount: 9` on a queue with `maxReceiveCount: 5`, and conclude the redrive
> policy is misconfigured or the message has been round-tripping. It has not. Subtract your own
> peeks.
>
> **Consequence 2 — invisible messages.** If you peek without `--visibility-timeout 0`, the message
> is hidden for the DLQ's visibility timeout. A redrive started in that window **skips it**, the
> task reports `COMPLETED`, the DLQ depth does not reach zero, and the alarm re-fires after you
> closed the incident. Always peek with `--visibility-timeout 0`, and if a colleague may have been
> peeking, re-check depth immediately before starting a move task.
>
> There is no true non-consuming "browse" API for SQS. The console's "Poll for messages" is the same
> `ReceiveMessage` call and has the same effect.

### Trap 6 — Redrive and the 7-day idempotency TTL

The guard rows in `pos-processed-transactions` carry a 7-day TTL, but DLQ retention is 14 days.
Between day 7 and day 14 a message is still replayable but is **no longer protected** by its
original guard row.

> **Consequence:** a redrive on day 10 re-processes transactions whose guard rows have expired, and
> awards their points a second time — an R4 violation produced by following the happy path a few
> days late. This is why the aging alarm sits at 7 days: it marks the end of the
> automatically-safe-replay window, not the approach of expiry. After day 7, replay needs the owning
> team's reconciliation (§9).

### Trap 7 — Only one active move task per queue

SQS permits **one** active message movement task per queue at a time.

> **Consequence:** two engineers responding to the same alarm both run `redrive.sh`; the second gets
> an error and, assuming the first attempt failed, starts investigating — or worse, cancels the
> running task and restarts it, so messages are moved twice and the "before" counts used for the §8
> arithmetic are wrong. Always run §5 Step 3 (`list-message-move-tasks`) first and announce in the
> incident channel before starting.

---

## 11. Appendix — Quick Reference

### Resource names and ARNs

Region `ap-southeast-1`. Replace `<account-id>` with `022499047467` in the lab account.

| Kind | Name | ARN / URL |
|---|---|---|
| SNS topic (ingest) | `pos-transactions` | `arn:aws:sns:ap-southeast-1:<account-id>:pos-transactions` |
| SNS topic (alerts) | `pos-ops-alerts` | `arn:aws:sns:ap-southeast-1:<account-id>:pos-ops-alerts` |
| Queue | `pos-loyalty-queue` | `arn:aws:sqs:ap-southeast-1:<account-id>:pos-loyalty-queue` · `https://sqs.ap-southeast-1.amazonaws.com/<account-id>/pos-loyalty-queue` |
| Queue | `pos-inventory-queue` | `arn:aws:sqs:ap-southeast-1:<account-id>:pos-inventory-queue` |
| Queue | `pos-einvoice-queue` | `arn:aws:sqs:ap-southeast-1:<account-id>:pos-einvoice-queue` |
| DLQ | `pos-loyalty-dlq` | `arn:aws:sqs:ap-southeast-1:<account-id>:pos-loyalty-dlq` |
| DLQ | `pos-inventory-dlq` | `arn:aws:sqs:ap-southeast-1:<account-id>:pos-inventory-dlq` |
| DLQ | `pos-einvoice-dlq` | `arn:aws:sqs:ap-southeast-1:<account-id>:pos-einvoice-dlq` |
| DLQ (SNS subscription) | `pos-sns-delivery-dlq` | `arn:aws:sqs:ap-southeast-1:<account-id>:pos-sns-delivery-dlq` |
| Function | `pos-loyalty-fn` | `arn:aws:lambda:ap-southeast-1:<account-id>:function:pos-loyalty-fn` |
| Function | `pos-inventory-fn` | `arn:aws:lambda:ap-southeast-1:<account-id>:function:pos-inventory-fn` |
| Function | `pos-einvoice-fn` | `arn:aws:lambda:ap-southeast-1:<account-id>:function:pos-einvoice-fn` |
| Table (idempotency) | `pos-processed-transactions` | `arn:aws:dynamodb:ap-southeast-1:<account-id>:table/pos-processed-transactions` · PK `transaction_id`, TTL attribute `expires_at`, 7 days |
| Log group | `/aws/lambda/pos-loyalty-fn` | `arn:aws:logs:ap-southeast-1:<account-id>:log-group:/aws/lambda/pos-loyalty-fn` |
| Log group | `/aws/lambda/pos-inventory-fn` | `arn:aws:logs:ap-southeast-1:<account-id>:log-group:/aws/lambda/pos-inventory-fn` |
| Log group | `/aws/lambda/pos-einvoice-fn` | `arn:aws:logs:ap-southeast-1:<account-id>:log-group:/aws/lambda/pos-einvoice-fn` |
| S3 archive | `pos-dlq-archive-<account-id>` (lab: `pos-dlq-archive-022499047467`) · Terraform output `dlq_archive_bucket` | `s3://pos-dlq-archive-<account-id>/poison/<service>/<YYYY>/<MM>/<DD>/` · AES256, versioned, public access blocked, 90-day lifecycle |

### Queue parameters

| Queue | Fn timeout | Visibility timeout | `maxReceiveCount` | Retry window | Source retention | DLQ retention |
|---|---|---|---|---|---|---|
| `pos-loyalty-queue` → `pos-loyalty-dlq` | 30 s | 180 s | 5 | ≈ 15 min | 4 days | 14 days |
| `pos-inventory-queue` → `pos-inventory-dlq` | 20 s | 120 s | 5 | ≈ 10 min | 4 days | 14 days |
| `pos-einvoice-queue` → `pos-einvoice-dlq` | 60 s | 360 s | 8 | ≈ 48 min | 4 days | 14 days |

### Alarms

| Alarm | Metric | Threshold | Status |
|---|---|---|---|
| `pos-loyalty-dlq-not-empty` / `pos-inventory-dlq-not-empty` / `pos-einvoice-dlq-not-empty` | `ApproximateNumberOfMessagesVisible` | >= 1, period 60 s, 1 evaluation period, statistic `Maximum` | Defined in `terraform/modules/consumer_queue/main.tf` |
| `pos-loyalty-dlq-message-aging` / `pos-inventory-dlq-message-aging` / `pos-einvoice-dlq-message-aging` | `ApproximateAgeOfOldestMessage` | > 604800 s (7 days), period 300 s, 1 evaluation period, statistic `Maximum` | Defined in `terraform/modules/consumer_queue/main.tf` |
| `pos-sns-delivery-dlq-not-empty` | `ApproximateNumberOfMessagesVisible` | >= 1, period 60 s, 1 evaluation period, statistic `Maximum`, `treat_missing_data = notBreaching`, `ok_actions` also on `pos-ops-alerts` | Defined in `terraform/sns.tf`. No aging alarm on this queue by design — see §2. |

### Structured log fields

| Field | Values / meaning |
|---|---|
| `service` | `loyalty` \| `inventory` \| `einvoice` |
| `transaction_id` | e.g. `TXN-JB012-20260911-000123` — the trace key for R5 |
| `store_id` | e.g. `JB012` — groups failures by store |
| `message_id` | SQS `MessageId`; matches `itemIdentifier` in `batchItemFailures` |
| `outcome` | `processed` \| `duplicate_skipped` \| `permanent_failure` \| `transient_failure` |
| `error_type` | Exception class name — `PermanentError`, `TransientError`, or the actual class for an unhandled exception. `null` on success. |
| `reason` | Exact failure string, e.g. `items is null (POS firmware v2.3 poison message)`, `loyalty API returned 503`. `null` on success. |
| `attempt` | Delivery attempt number for this record (compare against `maxReceiveCount`) |

### The three most-used commands

**1. How deep is the DLQ and how old is the oldest message?**

```bash
aws sqs get-queue-attributes \
  --queue-url "https://sqs.ap-southeast-1.amazonaws.com/<account-id>/pos-loyalty-dlq" \
  --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible ApproximateAgeOfOldestMessage \
  --region ap-southeast-1
```

**2. Peek one message without consuming it.**

```bash
aws sqs receive-message \
  --queue-url "https://sqs.ap-southeast-1.amazonaws.com/<account-id>/pos-loyalty-dlq" \
  --attribute-names All --message-attribute-names All \
  --max-number-of-messages 1 --visibility-timeout 0 \
  --region ap-southeast-1 | jq '.Messages[0] | {Attributes, Body}'
```

**3. Redrive, rate-limited, after the fix is confirmed.**

```bash
DLQ=arn:aws:sqs:ap-southeast-1:<account-id>:pos-loyalty-dlq
./scripts/redrive.sh --source-arn "$DLQ" --dry-run     # read the output
./scripts/redrive.sh --source-arn "$DLQ" --yes         # then commit

# Progress
aws sqs list-message-move-tasks \
  --source-arn "arn:aws:sqs:ap-southeast-1:<account-id>:pos-loyalty-dlq" \
  --max-results 10 --region ap-southeast-1 \
  --query 'Results[0].{Status:Status,Moved:ApproximateNumberOfMessagesMoved,ToMove:ApproximateNumberOfMessagesToMove,Failure:FailureReason}'
```

### Related files

| Path | What it is |
|---|---|
| `Enterprise_DLQ_Scenario_POS_EN.md` | The approved enterprise scenario. Sections 3, 5, 6, 8 and 10 are binding on this runbook. |
| `terraform/` | Queue, DLQ, alarm, Lambda and ESM definitions. Source of truth for all parameters above. |
| `terraform/modules/consumer_queue/` | The reusable queue + DLQ + redrive + alarm + Lambda module. |
| `scripts/redrive.sh` | `StartMessageMoveTask` wrapper. `--source-arn <dlq-arn>` (required), `--destination-arn`, `--region`, `--rate` (default 10 msg/s), `--yes`, `--dry-run`. Polls `list-message-move-tasks` until the task stops. |
| `scripts/pos_simulator.py` | Publishes simulated transactions. `--mode normal\|poison\|duplicate\|mixed\|burst`, `--count`, `--region`, `--topic-arn`, `--seed`, `--dry-run`. Used for the §5 canary. |
| `lambda/<service>/handler.py` | Consumers. They emit the structured log line documented above. |
