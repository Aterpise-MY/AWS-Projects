# Task: Weekday business-hours Business Sync + 18:00 daily report

Read `CLAUDE.md` first (constraints and contracts), then `README.md` and `docs/ebteqdesk-business-sync.md`
(sections 3, 8, 9, 10, 12). The code in this repo is **v3**: one nightly 00:00 sync, `portals` as a list, and a 28-hour
heartbeat. Change it as described below. Work in the order given; each part must leave the repo with passing tests.

## Why

New customers are onboarded during the day and may contact support right away. A ticket then needs their business
record already in Ebteqdesk. A nightly sync is too slow. Hourly syncs during office hours keep the lag under an hour,
and a daily 18:00 report tells the team what changed and what failed.

## Part 1 — Schedules (Terraform)

1. Replace `variable "portals"` (currently `list(string)`) with a map:
   ```hcl
   variable "portals" {
     type = map(object({
       schedule_expression   = string
       enabled               = bool
       expected_runs_per_day = number
     }))
     default = {
       salonv3 = { schedule_expression = "cron(0 9-17 ? * MON-FRI *)",  enabled = true,  expected_runs_per_day = 9 }
       warni   = { schedule_expression = "cron(30 9-16 ? * MON-FRI *)", enabled = false, expected_runs_per_day = 8 }
     }
   }
   ```
   Validate that the keys are a non-empty subset of `["salonv3","warni"]` and that each expression starts with `cron(` or `rate(`.
2. `aws_scheduler_schedule.daily_sync` → rename to `sync` and use `for_each = var.portals` (all brands).
   Set `state = each.value.enabled ? "ENABLED" : "DISABLED"` and `schedule_expression_timezone = var.schedule_timezone`
   (Asia/Kuala_Lumpur). Keep the heredoc `input`, never `jsonencode()`.
3. Runner env `ALLOWED_PORTALS = join(",", sort(keys(var.portals)))`, i.e. all brands. That way a manual test of a
   disabled brand still works.
4. Remove the old `schedule_expression` default of `cron(0 0 * * ? *)` and every "00:00" reference in comments and README.

## Part 2 — Retry and alert model for hourly runs

The next scheduled run is never more than an hour away, so the nightly 3×90-minute retry model no longer fits.

1. **Lambda timeout 600s** (default). **Visibility timeout = timeout + 300s = 900s. `max_receive_count` = 2.**
   That gives one automatic retry about 15 minutes later, then the DLQ.
   - This deliberately departs from AWS's "6× timeout" advice, which is about throttling on busy queues.
     This queue carries ≤ 17 messages a day at max concurrency 2.
   - Put that reasoning in a Terraform comment.
   - Keep the validation `visibility ≥ timeout`.
2. **Alert policy** (runner, `handler.py`). Per brand, keep a streak in `business-sync/<portal>/latest.json`:
   add `consecutive_failures` and `last_success_at`. Read the previous `latest.json` before overwriting it; this needs
   `s3:GetObject` on `business-sync/*/latest.json`.
   - Non-final failed attempt (attempt < max): **no Telegram**. Log and raise so SQS retries.
   - Final failed attempt: Telegram **only if** `consecutive_failures == 1` or `consecutive_failures % ALERT_EVERY_N_FAILURES == 0`
     (new env var, default 3). Include the streak count and time since last success.
     Always attach `output.log` when there is output.
   - Success after one or more failures: Telegram "✅ <brand> 已恢复" with the failure count and the downtime.
   - `still_running`: no Telegram on a non-final attempt. Raise so the retry adopts the run.
     On the final attempt, treat it as a failure (streak + alert rule above).
   - An invalid portal still alerts immediately.
   - Failure records in `business-sync/failures/…` are still written for **every** failed attempt, as now.
3. **No overlapping sweeps per brand** (Ebteqdesk, `ebteqdesk/`). Change `BusinessSyncTriggerController::store` so that
   **any** active, non-stale run for the portal is returned with `200`, whatever its `X-Trigger-Id`. Today it only
   matches the same trigger id. This matters now that runs are hourly.
   - Keep storing the caller's `trigger_id` on new runs.
   - Update or add feature tests: "an active run from another trigger is returned instead of starting a second sweep",
     "a stale active run from another trigger is abandoned and a new sweep starts".
   - Update `ebteqdesk/README.md`.

## Part 3 — Replace the 28-hour heartbeat

The 28-hour alarm would fire every weekend, so remove it.

1. The 18:00 reporter (Part 4) is the daily health check. For each **enabled** brand with zero successful runs today,
   the report is marked 🔴 and the Telegram message starts with 🚨.
2. Add a CloudWatch alarm for the reporter itself:
   - metric `ReportGenerated`, dimension `Service`, emitted by the reporter via EMF
   - Sum, period 3600, `evaluation_periods = datapoints_to_alarm = 74`, `LessThanThreshold 1`, `treat_missing_data = breaching`
   - 74h covers Friday 18:00 → Monday 18:00 plus slack. Confirm this is within CloudWatch's multi-day alarm limit.
   - Route it through SNS → notifier → Telegram, like the others.
3. Keep both DLQ alarms (sync DLQ, scheduler DLQ). Add the report DLQ alarm from Part 4.

## Part 4 — 18:00 daily report (new `lambda/reporter.py`)

**Trigger**
- `aws_scheduler_schedule.daily_report`: `cron(0 18 ? * MON-FRI *)` MYT, **Lambda templated target**.
- Input (heredoc): `{"trigger":"eventbridge-scheduler","scheduled_time":"<aws.scheduler.scheduled-time>"}`.
- Scheduler retry policy plus a scheduler DLQ, reusing the existing one.
- Lambda async config: `aws_lambda_function_event_invoke_config` with `maximum_retry_attempts = 2` and `destination_config.on_failure` → new SQS **report DLQ** (14 days) + alarm.
- Manual/backfill invoke must work: `{"report_date":"2026-09-28"}`. Without it, use the MYT date of `scheduled_time`, else today MYT.

**Data** (from S3 only; don't call Ebteqdesk)
- For each portal in `ALLOWED_PORTALS`, list `business-sync/<portal>/<YYYY>/<MM>/<DD>/` for the report date.
  Group by run folder and take the **highest attempt** per run as that run's final result.
- Read that attempt's `summary.json`, and its `changes.csv` when present.
- Read the current `ApproximateNumberOfMessagesVisible` of the sync DLQ and the scheduler DLQ.

**Per-brand figures**
- `enabled` flag (from a new env var `PORTALS_JSON` = `jsonencode(var.portals)`)
- expected runs, runs recorded, succeeded, failed (by final outcome)
- first and last successful sync time (MYT)
- **new businesses today:** distinct `id` from `changes.csv` rows with `action=created`, with their names
- updated businesses today (distinct ids)
- latest `counts.failed` (record-level failures) and up to 10 failure lines
- status:
  - 🟢 every recorded run succeeded and recorded ≥ expected − 1
  - 🟡 some failures but the last run succeeded
  - 🔴 no success today, or the last run failed
  - ⚪ brand disabled

**Outputs** (overwrite on re-run; idempotent)
- `business-sync/daily-reports/<YYYY>/<MM>/<DD>/report.json`: everything above.
- `…/runs.csv`: one row per run with portal, run_id, scheduled time MYT, attempts, outcome, seen, created, updated, unchanged, failed, duration_s, error.
- `…/new-businesses.csv`: portal, id, name, first seen run.
- Telegram:
  - one message in Chinese with a line per brand (status emoji, successes/expected, new businesses count and the first 5 names, failures, DLQ depth);
  - attach `runs.csv`, plus `new-businesses.csv` when non-empty;
  - start the message with 🚨 if any enabled brand is 🔴.
- EMF metrics: `ReportGenerated=1`, and per portal `DailySyncSuccesses`, `DailySyncFailures`, `NewBusinesses`.

**IAM (least privilege)**
- `s3:ListBucket` on the bucket, with an `s3:prefix` condition limited to `business-sync/*`
- `s3:GetObject` on `business-sync/*`
- `s3:PutObject` on `business-sync/daily-reports/*`
- `sqs:GetQueueAttributes` on the two DLQs
- `sqs:SendMessage` on the report DLQ (required for the async on-failure destination)
- `secretsmanager:GetSecretValue` on the telegram secret only
- The Scheduler execution role also needs `lambda:InvokeFunction` on the reporter.

**Lambda settings:** python3.13 arm64, timeout 120s, memory 256, its own log group. Reuse `telegram_client.py`.

## Part 5 — Tests

1. **Python** (`lambda/tests/`, pytest, stub HTTP server + fake boto3, no network).
   Runner:
   - no alert on a non-final failure
   - alert on the 1st and 3rd consecutive final failure but not the 2nd
   - recovery message
   - streak persisted in `latest.json`
   - adopt-any-active-run response (200)

   Reporter:
   - a mixed day (success, failure with retry, still_running)
   - an empty day for an enabled brand → 🔴 + 🚨
   - a disabled brand → ⚪ and no 🚨
   - backfill date
   - MYT date boundary (`scheduled_time` `2026-09-28T01:00:00Z` = 09:00 MYT on the 28th)
   - new-business dedupe across runs
   - Telegram down → report still written to S3, and the Lambda raises so the async retry happens
   Exclude `tests/` and `__pycache__/` from the Lambda zip (`archive_file` `excludes`).
2. **Terraform**: fmt, validate, `plan` with example tfvars. Report the resource count, and confirm that flipping
   `warni.enabled` changes only the Warni schedule state.
3. **Laravel**: updated `BusinessSyncTriggerApiTest` passes (run it in a Laravel 12 app if the Ebteqdesk repo isn't available).

## Part 6 — Docs

Update `README.md` (Chinese + English terms):
- schedule table
- "what happens when an hour fails" timeline: 10:00 attempt 1 ✗ → 10:15 attempt 2 ✗ → Telegram (per the streak rule) → DLQ at about 10:30 → 11:00 next scheduled run
- a sample 18:00 Telegram report (mock text)
- runbook:
  - redrive the sync DLQ
  - re-run or backfill a daily report
  - what 🔴 means and what to check
  - the report DLQ
- the Warni rollout checklist (unchanged, but with the new times)

Add a short note to `ebteqdesk/README.md`: sweeps now run during office hours while agents use Ebteqdesk.
After the first week, check `durationMs` in Settings → Business Sync. If sweeps exceed about 60 seconds or slow the app,
the next step is a queue worker (make `RunRemoteBusinessSync` `ShouldQueue`). Document it only; don't implement.

## Report back with

- Changed/added files per folder, with a one-line reason each.
- Test results: counts and anything skipped, and why.
- Terraform plan summary.
- Open questions. At least: should Malaysian public holidays be skipped? Is the alert streak rule (1st, then every 3rd) right?

## Don't

- Don't apply/destroy, call real Ebteqdesk/Telegram, or put secrets anywhere.
- Don't change Ebteqdesk's sync logic, or add per-brand queues/runners, API Gateway, a VPC or KMS CMKs.
- Don't add pip dependencies (reporting uses `csv`/`json` from the stdlib; no Excel).
