# Ebteqdesk Business Sync — serverless pipeline

Project instructions for any agent working in this repo. Read this file fully before changing anything.
The task to do right now is in `PROMPT.md`.

## What this project is

An AWS serverless pipeline that keeps **Ebteqdesk** (Ebteq's Laravel ticketing app, hosted on Laravel Cloud)
in sync with each brand's **POS business directory**, and reports on it every weekday.

- Brands ("portals"): `salonv3` (Salon V3) and `warni` (Warni). Each brand has its own POS.
  Ebteqdesk keeps the two brands fully separate: settings row, credentials, contacts, locks.
- The sync itself is Ebteqdesk's existing console command `ebteqdesk:syncBusinessContacts --portal=<brand>`.
  AWS never talks to the POS. It only tells Ebteqdesk to run the command and checks the result.
- Owner: Brendon, AWS Cloud & DevOps Engineer at Ebteq. User-facing text is **Chinese with English technical
  terms**; this covers Telegram messages and READMEs.

## Target schedule (source of truth)

All times are **Asia/Kuala_Lumpur (MYT, UTC+8, no DST)**. Weekdays = Monday–Friday. Nothing runs on Saturday or Sunday.
Public holidays are **not** excluded (open question; don't implement unless asked).

| Job | When (MYT) | EventBridge Scheduler expression | Runs/day |
|---|---|---|---|
| Salon V3 sync | Mon–Fri, hourly 09:00 → 17:00 | `cron(0 9-17 ? * MON-FRI *)` | 9 |
| Warni sync (disabled until rollout) | Mon–Fri, hourly 09:30 → 16:30 | `cron(30 9-16 ? * MON-FRI *)` | 8 |
| Daily Business Sync report | Mon–Fri 18:00 | `cron(0 18 ? * MON-FRI *)` | 1 |

Warni is offset by 30 minutes so two sweeps never occupy Ebteqdesk web workers at the same time.

## Architecture

```
Scheduler (per brand, weekday hourly) ─► SQS trigger queue ─► Lambda runner ─HTTPS─► Ebteqdesk
                                           │  (DLQ)              │   POST /api/integrations/business-sync/{portal} → 202
                                           │                     │   GET  /api/integrations/business-sync/runs/{id} (poll)
                                           ▼                     ├─► S3: per-run summary.json / changes.csv / output.log (+ failures/)
                                       Sync DLQ                  └─► Telegram (failure alerts, recovery)
Scheduler (weekday 18:00) ─► Lambda reporter ─► reads today's S3 run summaries + DLQ depth
                                              ─► S3 daily report + Telegram message with CSV
CloudWatch alarms ─► SNS ─► Lambda notifier ─► Telegram
```

- **No API Gateway, no Function URL, no VPC.** Every call goes outbound from AWS to Ebteqdesk.
- Ebteqdesk answers `POST` with `202` straight away and runs the sweep *after* the response (it has no queue worker:
  `QUEUE_DRIVER=sync`). The runner then polls `GET …/runs/{id}`.

## Repository layout

| Path | What |
|---|---|
| `ebteqdesk/` | Laravel code (trigger API) that gets copied into the **Ebteqdesk repo**. See `ebteqdesk/README.md`. |
| `lambda/` | Python 3.13 Lambda source, stdlib + boto3 only. `handler.py` is the runner. Also here: `notifier.py`, `ebteqdesk_api.py`, `report.py`, `telegram_client.py`. |
| `terraform/` | All AWS infrastructure. |
| `docs/ebteqdesk-business-sync.md` | Ebteqdesk's own reference for the sync feature. Read sections 3, 8, 9, 10 and 12 before touching anything about sync semantics. |
| `README.md` | Operator-facing README (deploy, runbook). Keep it in sync with the code. |

The code as delivered is **v3: one nightly 00:00 sync**. `PROMPT.md` moves it to the schedule above.

## Hard constraints

1. **Never change Ebteqdesk's sync logic.** That covers `SyncBusinessContacts`, `BusinessSynchronizer`, `BusinessRecordDiff`,
   `DuplicateDetector`, `BusinessSyncJournal` and similar. Only the trigger API under `ebteqdesk/` may change.
2. The **Laravel-side Business Sync schedule switches stay OFF** for both brands. AWS is the only scheduler.
3. **Secrets never** go in code, tfvars, Terraform state or logs. Terraform creates Secrets Manager *containers* only.
   Never log a URL that contains the Telegram bot token.
4. **Least-privilege IAM**, SSE-SQS (no CMK), S3 private + encrypted, `aws:SourceAccount` on the Scheduler trust policy.
5. **Shared infra:** one trigger queue, one runner, one sync DLQ, one notifier. Only schedules (and per-brand checks)
   are per brand.
6. **Never** run `terraform apply` / `destroy`, and never call the real Ebteqdesk or Telegram from tests. Use stubs.
7. Ask Brendon before deviating from this file or `PROMPT.md`.

## Contracts (don't break them silently)

- **Ebteqdesk API**
  - `POST /api/integrations/business-sync/{salonv3|warni}` with headers `Authorization: Bearer <token>` and `X-Trigger-Id` (`[A-Za-z0-9:._-]{1,100}`).
    Returns `202` for a new run, or `200` with the already-active run.
  - `GET /api/integrations/business-sync/runs/{id}` → `status` is `queued|running|succeeded|failed`. The body also has
    `exit_code`, `error`, `accepted_at`, `started_at`, `finished_at`, and `output` (only once finished).
- **SQS message** (from Scheduler):
  `{"trigger":"eventbridge-scheduler","portal":"<p>","scheduled_time":"<aws.scheduler.scheduled-time>","execution_id":"…","scheduler_attempt":"…"}`.
  Build Scheduler `input` with a heredoc string, **never `jsonencode()`**. It escapes `<` and `>`, and then
  Scheduler never substitutes the context attributes.
- **S3 layout** (dates are MYT):
  - `business-sync/<portal>/<YYYY>/<MM>/<DD>/<run>/attempt-<n>/{summary.json,changes.csv,output.log}`
  - `business-sync/<portal>/latest.json`
  - `business-sync/failures/<portal>/<YYYY>/<MM>/<DD>/<run>-attempt-<n>.json`
  - `business-sync/daily-reports/<YYYY>/<MM>/<DD>/…` (new, see `PROMPT.md`)
- **summary.json** fields the reporter relies on: `portal`, `run_id`, `attempt`, `max_attempts`, `final_attempt`,
  `outcome` (`success|failed|still_running|api_error`), `counts{seen,created,updated,unchanged,failed}`,
  `remote_run{…}`, `changes_count`, `failure_lines`, `error`, `lambda_duration_ms`, `generated_at`.
- **changes.csv** columns: `run_id,portal,action,id,name,changed_columns` (UTF-8 with BOM).
- **Metrics:** CloudWatch Embedded Metric Format, namespace `EbteqdeskBusinessSync`, dimensions `Service` + `Portal`.
  Metric names: `SyncSucceeded`, `SyncFailed`, `RecordsSeen`, `RecordsFailed`, `SyncDurationMs`.
  `Service` must equal Terraform `local.name`.
- **Console output parsing:**
  - The counts line `seen: N | created: N | updated: N | unchanged: N | failed: N` is pinned by Ebteqdesk tests, so it is safe to parse.
  - Change lines `created|updated #<id> <name> — <cols>` are best-effort.

## Commands

- Python tests: `cd lambda && python -m pytest -q`. Tests live in `lambda/tests/`; use a local stub HTTP server plus a
  fake `boto3` module, no network.
- Terraform: `terraform fmt -check -recursive && terraform init -backend=false && terraform validate`, then
  `terraform plan -var-file=terraform.tfvars.example`. **No apply.**
- Laravel (inside the Ebteqdesk repo, after copying `ebteqdesk/`): `php artisan test tests/Feature/Api/BusinessSyncTriggerApiTest.php`.

## Style

- Python: stdlib `urllib` for HTTP, small pure functions, no new pip dependencies without asking.
  Every failure path must be loud: a Telegram message or a raised exception. Never a silent pass.
- Terraform: one file per concern, `aws_iam_policy_document` data sources, validated variables, and short comments on
  non-obvious lines.
- Telegram and README text: Chinese, with English for AWS/technical terms (e.g. "进入 DLQ", "heartbeat alarm").
