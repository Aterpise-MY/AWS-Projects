# Ebteqdesk Business Sync：Serverless Pipeline（weekday 上班时间 sync + 18:00 日报）

这个项目用 AWS serverless 把每个 brand（`salonv3`、`warni`）的 **POS business directory** 同步进 **Ebteqdesk**（Ebteq 的 Laravel ticketing app）。**Mon–Fri 09:00–17:00（MYT）每小时**，EventBridge Scheduler 往 SQS trigger queue 放一条消息。Lambda runner 调 Ebteqdesk 的 **Business Sync Trigger API**（`POST` → `202`），然后 poll `GET …/runs/{id}` 直到跑完。每次尝试的报告都写进 S3，失败会自动重试一次（约 15 分钟后），两次都失败就进 DLQ。Telegram 提醒按"连续失败 streak"规则发，不会每小时刷屏。**每个工作日 18:00**，reporter Lambda 只读 S3 里当天的 run 报告和 DLQ depth，产出日报（S3 + Telegram + CSV）。没有 API Gateway，没有 VPC；所有调用都是 AWS 主动 outbound 到 Ebteqdesk 和 Telegram。

> 状态：Terraform `fmt` / `validate` / `terraform test`（5/5）通过；离线 `terraform plan` 共 40 个 resource。**尚未部署**（没有 `terraform apply`）。
> Ebteqdesk 那边的 Laravel 改动见 [`ebteqdesk/README.md`](ebteqdesk/README.md)（这个仓库只有文档，要在 Ebteqdesk repo 里改）。

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Networking & Routing](#networking--routing)
3. [Component Details](#component-details)
4. [Directory Structure](#directory-structure)
5. [Prerequisites](#prerequisites)
6. [Quick Start](#quick-start)
7. [Input Variables](#input-variables)
8. [Outputs](#outputs)
9. [Scaling Behaviour：排程、重试、提醒与日报](#scaling-behaviour排程重试提醒与日报)
10. [Tagging Strategy](#tagging-strategy)
11. [Security Considerations](#security-considerations)
12. [Cost Estimate](#cost-estimate)
13. [Destroying the Stack](#destroying-the-stack)
14. [Frequently Asked Questions](#frequently-asked-questions)

## Architecture Overview

```
                   EventBridge Scheduler (Asia/Kuala_Lumpur)
 ┌──────────────────────────────────────────────┬──────────────────────────────────┐
 │ sync-salonv3  cron(0 9-17 ? * MON-FRI *)     │ daily-report                      │
 │ sync-warni    cron(30 9-16 ? * MON-FRI *)    │ cron(0 18 ? * MON-FRI *)          │
 │               (DISABLED until rollout)       │ Lambda templated target (async)   │
 └──────────────┬───────────────────────────────┴───────────────┬──────────────────┘
                │ SQS SendMessage          投递失败 ──► Scheduler DLQ │ lambda:InvokeFunction
                ▼                                                 ▼
 ┌──────────────────────────────┐                   ┌──────────────────────────────┐
 │ SQS trigger queue            │  2 次都失败        │ Lambda reporter              │
 │ visibility 900 s             ├──────────────┐    │ 读 S3 当天 run 报告 + DLQ depth │
 │ maxReceiveCount 2            │              ▼    │ 重试 2 次 ──► Report DLQ       │
 └──────────────┬───────────────┘          Sync DLQ └──────┬──────────────┬────────┘
                │ batch 1, max concurrency 2                │              │
                ▼                                           ▼              ▼
 ┌──────────────────────────────┐   HTTPS   ┌───────────┐  S3 daily-reports/  Telegram 日报
 │ Lambda runner (600 s)        ├──────────►│ Ebteqdesk │                     + runs.csv
 │ trigger → poll → report      │ POST 202  │ (Laravel) │
 │ streak → Telegram            │ GET runs  └───────────┘
 └───────┬──────────────┬───────┘
         ▼              ▼
   S3 run reports   Telegram（❌ 失败 / ✅ 恢复）
   + failures/
   + latest.json

 CloudWatch alarms（3 × DLQ not empty + daily-report-missing）──► SNS ──► Lambda notifier ──► Telegram 🚨
```

**Traffic flow:** Scheduler 整点放消息进 SQS → runner 触发 Ebteqdesk sweep 并 poll 到结束 → 报告与失败记录写入 S3，按 streak 规则发 Telegram → 18:00 reporter 汇总当天 S3 报告，写日报并发 Telegram → 任何 DLQ 有消息或 74 小时没有日报，CloudWatch alarm 经 SNS → notifier → Telegram。

## Networking & Routing

这个 stack **没有 VPC**：三个 Lambda 都跑在 AWS 管理的网络里，只有 outbound HTTPS。没有任何 inbound endpoint（没有 API Gateway、没有 Function URL）。

### Outbound calls

| From | To | Protocol | Auth |
|---|---|---|---|
| Lambda runner | Ebteqdesk `POST /api/integrations/business-sync/{portal}`、`GET …/runs/{id}` | HTTPS（强制 `https://`） | `Authorization: Bearer <token>`（Secrets Manager） |
| Lambda runner / reporter / notifier | `api.telegram.org` `sendMessage`、`sendDocument` | HTTPS | bot token（Secrets Manager，从不写进 log） |
| All Lambdas | S3、SQS、Secrets Manager、CloudWatch Logs | AWS public endpoints over TLS | IAM role |

### AWS service-to-service paths

| Source | Target | Mechanism |
|---|---|---|
| EventBridge Scheduler | SQS trigger queue | Scheduler execution role `sqs:SendMessage` |
| EventBridge Scheduler | Lambda reporter | Scheduler execution role `lambda:InvokeFunction` (async) |
| EventBridge Scheduler | Scheduler DLQ | 同一个 role，投递失败时 |
| SQS trigger queue | Lambda runner | Event source mapping（batch 1，max concurrency 2） |
| SQS trigger queue | Sync DLQ | Redrive policy，`maxReceiveCount = 2` |
| Lambda reporter (async) | Report DLQ | `on_failure` destination，`maximum_retry_attempts = 2` |
| CloudWatch alarm | SNS → Lambda notifier | Topic policy（`aws:SourceAccount`）+ Lambda permission |

### Traffic Flow

```
 Scheduler ──► SQS trigger ──► Lambda runner ──HTTPS──► Ebteqdesk ──► POS（Ebteqdesk 自己连，AWS 不碰 POS）
                   │                  ├──► S3
                   ▼                  └──HTTPS──► Telegram
               Sync DLQ ──► CloudWatch ──► SNS ──► notifier ──HTTPS──► Telegram
```

## Component Details

### 1. EventBridge Scheduler

| Attribute | Value |
|---|---|
| Resources | `aws_scheduler_schedule.sync` (`for_each = var.portals`), `aws_scheduler_schedule.daily_report` |
| Timezone | `Asia/Kuala_Lumpur`（MYT，UTC+8，无 DST） |
| Salon V3 | `cron(0 9-17 ? * MON-FRI *)` → 09:00…17:00，每天 9 次，`ENABLED` |
| Warni | `cron(30 9-16 ? * MON-FRI *)` → 09:30…16:30，每天 8 次，`DISABLED` 直到 rollout |
| Daily report | `cron(0 18 ? * MON-FRI *)`，Lambda templated target |
| `state` | `each.value.enabled ? "ENABLED" : "DISABLED"` |
| Retry | sync：5 次、最多 30 分钟；report：5 次、最多 1 小时 |
| DLQ | `…-scheduler-dlq`（sync 和 report schedule 共用） |
| `input` | heredoc 字符串，**不用 `jsonencode()`**（它会把 `<` `>` 转义，Scheduler 就不会替换 `<aws.scheduler.scheduled-time>`） |

> Warni 比 Salon V3 晚 30 分钟，两个 sweep 不会同时占用 Ebteqdesk 的 web worker。

### 2. SQS Queues

| Queue | Visibility | Retention | Purpose |
|---|---|---|---|
| `…-trigger` | `900` s（= Lambda timeout 600 + 300） | 1 天 | 每条消息 = 一个 brand 的一次 sync |
| `…-sync-dlq` | default | 14 天 | 两次尝试都失败的 sync；可 redrive |
| `…-scheduler-dlq` | default | 14 天 | Scheduler 投递失败 |
| `…-report-dlq` | default | 14 天 | reporter async invoke 重试 2 次仍失败 |

> 全部 SSE-SQS（`sqs_managed_sse_enabled`），不用 CMK。`visibility ≥ timeout` 由 variable validation 保证。
> 刻意**不**用 AWS 建议的"6 × timeout"：那条建议是给高流量、会被 throttle 的 queue。这条 queue 一天最多 17 条消息、max concurrency 2。理由也写在 `terraform/sqs.tf` 的注释里。

### 3. Lambda Functions

| Function | Handler | Runtime | Timeout | Memory | Trigger |
|---|---|---|---|---|---|
| `…-runner` | `handler.lambda_handler` | python3.13 arm64 | 600 s | 256 MB | SQS event source mapping |
| `…-reporter` | `reporter.lambda_handler` | python3.13 arm64 | 120 s | 256 MB | Scheduler 18:00（async，retry 2 → report DLQ） |
| `…-notifier` | `notifier.lambda_handler` | python3.13 arm64 | 30 s | 128 MB | SNS |

三个 function 共用一个 zip（`archive_file`，`excludes` 掉 `tests/` 和 `__pycache__/`），各自有 log group。只用 stdlib + boto3，没有 pip dependency。

**Runner environment**

| Variable | Value |
|---|---|
| `ALLOWED_PORTALS` | `join(",", sort(keys(var.portals)))` → `salonv3,warni`（包括 disabled 的 brand，手动测试才能跑） |
| `MAX_RECEIVE_COUNT` | `2`，判断是不是最后一次尝试 |
| `ALERT_EVERY_N_FAILURES` | `3` |
| `EBTEQDESK_BASE_URL` / `…_SECRET_ARN` / `TELEGRAM_SECRET_ARN` / `REPORT_BUCKET` / `SERVICE_NAME` | 由 Terraform 填 |

**Reporter environment**：`PORTALS_JSON = jsonencode(var.portals)`（enabled 与 expected runs）、`SYNC_DLQ_URL`、`SCHEDULER_DLQ_URL`、`ALLOWED_PORTALS`、`REPORT_BUCKET`、`TELEGRAM_SECRET_ARN`。

### 4. S3 Report Bucket

| Attribute | Value |
|---|---|
| Name | `<name>-reports-<account_id>` |
| Access | Block Public Access 全开、`BucketOwnerEnforced`、只接受 TLS（bucket policy deny `aws:SecureTransport = false`） |
| Encryption | SSE-S3（AES256） |
| Lifecycle | `business-sync/` 180 天后过期 |

| Key（日期是 MYT） | 写入者 | 内容 |
|---|---|---|
| `business-sync/<portal>/<YYYY>/<MM>/<DD>/<run>/attempt-<n>/summary.json` | runner | 每次尝试的结果、counts、remote run、error |
| `…/attempt-<n>/changes.csv` | runner | `run_id,portal,action,id,name,changed_columns`（UTF-8 BOM），有变动才写 |
| `…/attempt-<n>/output.log` | runner | Ebteqdesk command 完整 output |
| `business-sync/<portal>/latest.json` | runner | 最新一次尝试 + `consecutive_failures`、`failing_since`、`last_success_at` |
| `business-sync/failures/<portal>/<YYYY>/<MM>/<DD>/<run>-attempt-<n>.json` | runner | **每一次**失败的尝试 |
| `business-sync/daily-reports/<YYYY>/<MM>/<DD>/{report.json,runs.csv,new-businesses.csv}` | reporter | 日报（重跑会覆盖，idempotent） |

`<run>` = scheduled time 的 MYT `HHMMSS` + trigger id 的 hash，例如 `090000-1a2b3c4d`，所以按名字排序就是时间顺序。

### 5. Secrets Manager

| Secret | Value（用 CLI 放，不进 tfstate） |
|---|---|
| `<name>/ebteqdesk-trigger-token` | `{"token":"<BUSINESS_SYNC_TRIGGER_TOKEN>"}`，要和 Ebteqdesk env 一模一样 |
| `<name>/telegram` | `{"bot_token":"…","chat_id":"-100…"}` |

> Lambda 每次执行都重新读 secret，换 token 不需要重新部署。

### 6. CloudWatch Alarms & Notifier

| Alarm | Metric | Rule | Meaning |
|---|---|---|---|
| `…-sync-dlq-not-empty` | `AWS/SQS ApproximateNumberOfMessagesVisible` | Max > 0，5 分钟 | 某次 sync 两次尝试都失败 |
| `…-scheduler-dlq-not-empty` | 同上 | Max > 0，5 分钟 | Scheduler 连投递都失败 |
| `…-report-dlq-not-empty` | 同上 | Max > 0，5 分钟 | 18:00 日报重试后仍失败 |
| `…-daily-report-missing` | `EbteqdeskBusinessSync ReportGenerated`（dimension `Service`） | Sum，period 3600，`evaluation_periods = datapoints_to_alarm = 74`，`LessThanThreshold 1`，`treat_missing_data = breaching` | 74 小时没有日报 |

> 旧的 28 小时 heartbeat alarm **已移除**：周末没有 sync，它每个周末都会响。现在由 18:00 日报当每日 health check（没有成功 run 的 enabled brand = 🔴 + 🚨），再用 `daily-report-missing` 看住 reporter 本身。
> 74 h = Fri 18:00 → Mon 18:00（72 h）+ 2 h slack。74 × 3600 s = 266,400 s，在 CloudWatch 对 period ≥ 1 小时的 alarm 的 7 天（604,800 s）上限内（`terraform/tests/schedules.tftest.hcl` 有 assert）。
> SNS topic 不加密：CloudWatch alarm 不能 publish 到用 AWS managed key `alias/aws/sns` 加密的 topic，而这个项目不用 CMK。alarm 内容没有 secret。

### 7. IAM (least privilege)

| Role | Permissions |
|---|---|
| runner | 自己的 log group；trigger queue receive/delete/attrs；`s3:PutObject` `business-sync/*`；`s3:GetObject` `business-sync/*/latest.json`；两个 secret 的 `GetSecretValue` |
| reporter | 自己的 log group；`s3:ListBucket`（`s3:prefix` 限 `business-sync/*`）；`s3:GetObject` `business-sync/*`；`s3:PutObject` `business-sync/daily-reports/*`；两个 DLQ 的 `sqs:GetQueueAttributes`；report DLQ `sqs:SendMessage`（on_failure destination 需要）；telegram secret |
| notifier | 自己的 log group；telegram secret |
| scheduler | trust policy 带 `aws:SourceAccount`；trigger queue + scheduler DLQ `sqs:SendMessage`；reporter `lambda:InvokeFunction` |

> runner 没有 `s3:ListBucket`，所以某个 brand 第一次读 `latest.json` 会拿到 403 而不是 404，`handler.py` 把两者都当成"还没有 streak"。

## Directory Structure

```
Serverless Business Sync Pipeline/
├── CLAUDE.md                          # 项目约束与 contracts（给 agent 看）
├── PROMPT.md                          # v3 → v4 的任务说明
├── README.md                          # 本文件（operator README）
├── ebteqdesk/
│   └── README.md                      # Ebteqdesk repo 需要做的 store() 改动、feature tests、queue worker 注意事项
├── lambda/
│   ├── handler.py                     # runner：trigger → poll → S3 报告 / 失败记录 → streak → Telegram
│   ├── reporter.py                    # 18:00 日报：读 S3 + DLQ depth → S3 日报 + Telegram + CSV
│   ├── notifier.py                    # CloudWatch alarm (SNS) → Telegram
│   ├── ebteqdesk_api.py               # Ebteqdesk trigger API client（https、HTML 200 当失败）
│   ├── report.py                      # MYT 时间、output parsing、S3 key、CSV、EMF metrics
│   ├── telegram_client.py             # sendMessage / sendDocument（不 log 带 token 的 URL）
│   └── tests/
│       ├── conftest.py                # fake boto3 + 本地 stub HTTP server（Ebteqdesk + Telegram）
│       ├── test_runner.py             # 13 个 runner case
│       ├── test_reporter.py           # 13 个 reporter case（含 4 个 MYT 边界）
│       └── test_notifier_and_parsing.py  # 8 个 notifier / parsing / URL case
└── terraform/
    ├── versions.tf                    # Terraform >= 1.9、AWS ~> 5.80、archive ~> 2.7、default_tags
    ├── variables.tf                   # 所有 input + validation（portals map、visibility ≥ timeout…）
    ├── main.tf                        # locals（name、visibility、ALLOWED_PORTALS）+ 两个 secret container
    ├── scheduler.tf                   # 每个 brand 一条 sync schedule + 18:00 daily_report
    ├── sqs.tf                         # trigger queue + sync / scheduler / report DLQ（含重试模型注释）
    ├── lambda.tf                      # zip + runner / notifier / reporter + event source + async config
    ├── s3.tf                          # 私有、加密、TLS-only、180 天过期的报告 bucket
    ├── iam.tf                         # 四个 role 的最小权限 policy
    ├── monitoring.tf                  # SNS topic + 3 个 DLQ alarm + daily-report-missing alarm
    ├── outputs.tf                     # 手动触发 / redrive / 看 log / 重跑日报等指令
    ├── terraform.tfvars.example       # 示例 tfvars（无 secret）
    └── tests/
        └── schedules.tftest.hcl       # mock provider 的离线 plan 测试（5 个 run）
```

## Prerequisites

| Tool | Minimum Version | Install |
|---|---|---|
| Terraform | 1.9 | https://developer.hashicorp.com/terraform/install |
| AWS CLI | 2.15（需要 `sqs start-message-move-task`） | https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html |
| Python（只跑 test） | 3.11（Lambda runtime 是 3.13） | https://www.python.org/downloads/ |
| pytest（只跑 test） | 7 | `pip install pytest` |
| jq | 1.6 | https://jqlang.github.io/jq/download/ |

Account-level requirements:

- AWS account + `ap-southeast-1` region 可用 EventBridge Scheduler、Lambda arm64。
- Ebteqdesk 已部署 trigger API，并设好 `BUSINESS_SYNC_TRIGGER_TOKEN`（见 [`ebteqdesk/README.md`](ebteqdesk/README.md)）。
- Telegram bot 已加入告警群，并拿到 `chat_id`（群组是 `-100…` 开头的负数）。

## Quick Start

```bash
# 1. 本地测试（不连网络）
cd lambda && python -m pytest -q && cd ..

# 2. Terraform 检查
cd terraform
terraform fmt -check -recursive
terraform init -backend=false && terraform validate && terraform test

# 3. 部署
cp terraform.tfvars.example terraform.tfvars      # 填 ebteqdesk_base_url
terraform init
terraform plan -out=tfplan && terraform apply tfplan

# 4. 放 secret（不进 tfstate）。token 必须和 Ebteqdesk 的一模一样
aws secretsmanager put-secret-value \
  --secret-id "$(terraform output -raw ebteqdesk_secret_arn)" \
  --secret-string '{"token":"<BUSINESS_SYNC_TRIGGER_TOKEN>"}'
aws secretsmanager put-secret-value \
  --secret-id "$(terraform output -raw telegram_secret_arn)" \
  --secret-string '{"bot_token":"<BOT_TOKEN>","chat_id":"<CHAT_ID>"}'

# 5. Smoke test：手动跑一次 Salon V3 sync，看 log 和 latest.json
eval "$(terraform output -json cmd_manual_trigger | jq -r '.salonv3')"
eval "$(terraform output -raw cmd_tail_logs)"
eval "$(terraform output -json cmd_latest_report | jq -r '.salonv3')"

# 6. 手动跑一次日报（同时把 daily-report-missing alarm 带回 OK）
terraform output -raw cmd_run_report | sed "s/YYYY-MM-DD/$(TZ=Asia/Kuala_Lumpur date +%F)/" | sh

# 7. Ebteqdesk Settings 里的 Business Sync schedule switch 两个 brand 都保持 OFF
```

Allow 5 minutes for the first sync to finish and the report files to appear in S3.

> 刚部署完还没有日报时，`daily-report-missing` 会因为 `treat_missing_data = breaching` 进 ALARM。第 6 步手动跑一次日报后，它会在一个 period 内回到 OK。
> 第一天可以设 `telegram_notify_on_success = true` 确认 Telegram 收得到，之后关掉（每小时一条太吵）。

## Input Variables

| Variable | Type | Default | Description |
|---|---|---|---|
| `aws_region` | `string` | `"ap-southeast-1"` | 所有 resource 的 region |
| `project_name` | `string` | `"ebteqdesk-business-sync"` | 名字前缀，`^[a-z0-9-]{3,40}$` |
| `environment` | `string` | `"prod"` | `local.name = <project_name>-<environment>`，也是 metric dimension `Service` |
| `owner` | `string` | `"brendon"` | `Owner` tag |
| `extra_tags` | `map(string)` | `{}` | 额外 default tags |
| `ebteqdesk_base_url` | `string` | — (required) | 必须是 `https://<host>`，不带 path |
| `portals` | `map(object({schedule_expression, enabled, expected_runs_per_day}))` | salonv3 enabled 9/day；warni disabled 8/day | 每个 brand 的 schedule |
| `schedule_timezone` | `string` | `"Asia/Kuala_Lumpur"` | 所有 schedule 的 timezone |
| `report_schedule_expression` | `string` | `"cron(0 18 ? * MON-FRI *)"` | 日报时间 |
| `lambda_timeout_seconds` | `number` | `600` | runner timeout（60–900） |
| `visibility_timeout_seconds` | `number` | `null` → timeout + 300 = `900` | 重试间隔 |
| `max_receive_count` | `number` | `2` | 进 sync DLQ 前的投递次数（1–5） |
| `runner_max_concurrency` | `number` | `2` | event source mapping max concurrency（AWS 最小 2） |
| `alert_every_n_failures` | `number` | `3` | 连续失败第 1 次提醒，之后每 N 次 |
| `telegram_notify_on_success` | `bool` | `false` | 每次成功都发 Telegram |
| `poll_interval_seconds` | `number` | `10` | poll `GET /runs/{id}` 的间隔 |
| `report_retention_days` | `number` | `180` | S3 过期天数 |
| `log_retention_days` | `number` | `90` | CloudWatch Logs 保留天数 |
| `report_alarm_hours` | `number` | `74` | 几小时没有日报就 alarm（1–168） |

Validation rules:

- `portals` 的 key 必须是 `["salonv3","warni"]` 的非空子集；每个 `schedule_expression` 必须以 `cron(` 或 `rate(` 开头；`expected_runs_per_day` 是 ≥ 1 的整数。
- **Cross-variable：** `visibility_timeout_seconds`（如果有设）必须 ≥ `lambda_timeout_seconds`，否则第一次尝试还在跑，SQS 就会重投。

## Outputs

| Output | Description |
|---|---|
| `report_bucket` | 报告 bucket 名字 |
| `ebteqdesk_secret_arn` / `telegram_secret_arn` | 用 CLI 放 secret 的目标 |
| `trigger_queue_url` / `sync_dlq_url` / `scheduler_dlq_url` / `report_dlq_url` | 四条 queue |
| `schedules` | 每个 brand 的 schedule 名字、expression、state |
| `failure_records_prefix` | `s3://…/business-sync/failures/` |
| `cmd_manual_trigger` | map：每个 brand 手动放一条 sync 消息（disabled 的也可以） |
| `cmd_tail_logs` | tail runner log |
| `cmd_latest_report` | map：印出每个 brand 的 `latest.json` |
| `cmd_redrive_dlq` | 把 sync DLQ 的消息搬回 trigger queue |
| `cmd_run_report` | 重跑 / 补跑某一天的日报（把 `YYYY-MM-DD` 换掉） |
| `cmd_daily_report` | 列出某天的日报文件 |

```bash
terraform output schedules
terraform output -json cmd_manual_trigger | jq -r '.warni'
```

## Scaling Behaviour：排程、重试、提醒与日报

这个 pipeline 不按 CPU scale：它按**时间表**跑，每个 brand 同时只有一个 sweep（Ebteqdesk 保证），runner max concurrency 2。

### 排程 / Schedule（MYT，Mon–Fri）

| Job | Time | Expression | Runs/day | State |
|---|---|---|---|---|
| Salon V3 sync | 09:00 → 17:00 每小时 | `cron(0 9-17 ? * MON-FRI *)` | 9 | `ENABLED` |
| Warni sync | 09:30 → 16:30 每小时 | `cron(30 9-16 ? * MON-FRI *)` | 8 | `DISABLED`（rollout 前） |
| Daily report | 18:00 | `cron(0 18 ? * MON-FRI *)` | 1 | `ENABLED` |

周六、周日什么都不跑。马来西亚公共假期**没有**排除（见 FAQ）。

```
 MYT   09   10   11   12   13   14   15   16   17   18
       │    │    │    │    │    │    │    │    │    │
 SV3   ●    ●    ●    ●    ●    ●    ●    ●    ●    │      ● = sync（每次最多 2 次尝试）
 Warni  ○    ○    ○    ○    ○    ○    ○    ○        │      ○ = 09:30…16:30（disabled 时不跑）
 Report                                             ■      ■ = 18:00 日报
```

### 某个整点失败时会发生什么 / What happens when an hour fails

| 时间 (MYT) | 发生什么 | Telegram |
|---|---|---|
| 10:00 | attempt 1 ✗（例如 POS 暂时连不上），写 `failures/…-attempt-1.json` | **不发**（不是最后一次） |
| ~10:15 | visibility timeout（900 s）到期 → attempt 2 ✗，同一个 `X-Trigger-Id`；写 `failures/…-attempt-2.json`，`consecutive_failures + 1` | 按 streak 规则：连续第 1 次、第 3 次、第 6 次…才发，附 `output.log` |
| ~10:30 | SQS 把消息搬进 sync DLQ | `sync-dlq-not-empty` alarm（notifier 发） |
| 11:00 | 下一个排程照常跑；成功的话 | 如果之前有失败：`✅ Salon V3 已恢复`（失败次数 + downtime） |

提醒规则（每个 brand 一个 streak，存在 `latest.json`）：

| 情况 | Telegram | Lambda |
|---|---|---|
| 非最后一次尝试失败 / `still_running` | 不发 | raise → SQS 重试（`still_running` 会由重试接手同一个 run） |
| 最后一次尝试失败（含 `still_running`） | `consecutive_failures == 1` 或 `% 3 == 0` 才发，含 streak 与距上次成功多久 | raise → DLQ |
| 失败后成功 | `✅ <brand> 已恢复` | 正常结束 |
| portal 不在白名单 / 消息不是 JSON | 马上发 | 不重试（重试也修不好） |

`failures/` 失败记录：**每一次**失败的尝试都写，不受提醒规则影响。

### 18:00 日报 / Daily report

reporter 只读 S3（不调 Ebteqdesk）：每个 run 取**最大的 attempt** 当最终结果，再读 SQS 两个 DLQ 的 depth。

| Status | 条件 |
|---|---|
| 🟢 | 所有 run 都成功，且 recorded ≥ expected − 1 |
| 🟡 | 有失败，但最后一次 run 成功 |
| 🔴 | 今天没有成功，或最后一次 run 失败（enabled brand 🔴 时整条消息以 🚨 开头） |
| ⚪ | brand 是 disabled |

Sample 18:00 Telegram（mock）：

```
📊 Business Sync 日报 2026-09-28（一）
🟡 Salon V3：成功 8/9 · 失败 1 · 新 business 3（Glow Beauty KL、Mane Studio、Nail Bar PJ）· 更新 12 · record 失败 0
   首次/最后成功 first/last success：09:01 / 17:02
⚪ Warni：已停用 disabled（今天 0 次手动 run）
DLQ：sync 1 · scheduler 0
报告 report：s3://ebteqdesk-business-sync-prod-reports-123456789012/business-sync/daily-reports/2026/09/28/
[附件] runs-2026-09-28.csv
[附件] new-businesses-2026-09-28.csv
```

有 enabled brand 🔴 时（mock）：

```
🚨 📊 Business Sync 日报 2026-09-29（二）
🔴 Salon V3：成功 0/9 · 失败 9 · 新 business 0 · 更新 0 · record 失败 0
   ↳ 今天没有成功的 sync
⚪ Warni：已停用 disabled（今天 0 次手动 run）
DLQ：sync 9 · scheduler 0
```

EMF metrics（namespace `EbteqdeskBusinessSync`）：runner 每次尝试发 `SyncSucceeded`、`SyncFailed`、`RecordsSeen`、`RecordsFailed`、`SyncDurationMs`（`Service` + `Portal`）；reporter 发 `ReportGenerated=1`（`Service`），以及每个 brand 的 `DailySyncSuccesses`、`DailySyncFailures`、`NewBusinesses`。

### Runbook

**❌ 单次失败（Telegram）**：先看附件 `output.log` 或 `failures/` 记录。POS 暂时连不上（run-level abort）→ 等下一个整点。`failed: N > 0`（record-level）→ 重试修不好，要看是哪几笔数据。

**🚨 `sync-dlq-not-empty`**
1. 修好原因。
2. `eval "$(terraform output -raw cmd_redrive_dlq)"` 把消息搬回去重跑。
3. DLQ 积了很多小时的消息时只要跑一次：`aws sqs purge-queue --queue-url "$(terraform output -raw sync_dlq_url)"`，再手动触发一次（`cmd_manual_trigger`）。下一个整点也会自动补上。

**🔁 重跑 / 补跑日报**
```bash
terraform output -raw cmd_run_report | sed 's/YYYY-MM-DD/2026-09-28/' | sh
```
重跑会覆盖同一天的 `report.json`、`runs.csv`、`new-businesses.csv`，并再发一次 Telegram。

**🔴 日报上某个 brand 是红的**，按顺序检查：
1. `terraform output schedules`：该 brand 的 schedule 是不是 `ENABLED`；
2. Lambda console：runner 的 SQS event source mapping 是不是 `Enabled`；
3. `cmd_latest_report`：`consecutive_failures`、`last_success_at`、最近的 error；
4. 两边 token 对不对得上（401）、Ebteqdesk 有没有被 firewall 拦（HTML 200）；
5. sync DLQ 有没有消息（日报上的 DLQ depth）。

**🚨 `report-dlq-not-empty`**：reporter 重试 2 次仍失败（通常是 Telegram 连不上或 secret 错）。S3 日报在失败前已经写好了。修好后用上面的指令重跑那一天，再 `aws sqs purge-queue --queue-url "$(terraform output -raw report_dlq_url)"`。

**🚨 `daily-report-missing`**：74 小时没有日报。检查 `daily_report` schedule 是否 `ENABLED`、scheduler DLQ、reporter log；然后手动重跑日报。

**🚨 `scheduler-dlq-not-empty`**：`terraform plan` 找 drift（IAM / queue / Lambda 被改），`apply` 修复，手动补跑，再 purge scheduler DLQ。

**🔑 换 token**：Ebteqdesk env 和 AWS secret **一起换**，不需要重新部署。

### Warni rollout checklist

1. Ebteqdesk：Warni 的 settings row、POS credentials 已设好；Settings 里 Warni 的 Business Sync schedule switch 保持 **OFF**。
2. Ebteqdesk 的 `store()` 改动（"任何 active run 都回 200"）已上线（见 [`ebteqdesk/README.md`](ebteqdesk/README.md)）。
3. 手动测试（schedule 还是 disabled 也可以跑）：`eval "$(terraform output -json cmd_manual_trigger | jq -r '.warni')"`，确认 `latest.json` 是 `success`、counts 合理。
4. 在 tfvars 把 `warni.enabled = true`，`terraform plan` 应该**只**改 `aws_scheduler_schedule.sync["warni"]` 的 `state`（`terraform test` 的 `enable_warni_only_flips_its_schedule` 也验证这一点），然后 `apply`。
5. 第一天 09:30、10:30… 看 runner log；18:00 日报里 Warni 应该从 ⚪ 变成 🟢（8/8）。
6. 第一周后在 Ebteqdesk Settings → Business Sync 看两个 brand 的 `durationMs`，确认两个 sweep 不会互相卡住（Warni 晚 30 分钟就是为了错开）。

## Tagging Strategy

| Tag Key | Value |
|---|---|
| `Project` | `var.project_name`（`ebteqdesk-business-sync`） |
| `Environment` | `var.environment`（`prod`） |
| `ManagedBy` | `terraform` |
| `Owner` | `var.owner` |
| *(extra)* | `var.extra_tags` 的所有 key |

> 全部用 provider `default_tags`。`aws_scheduler_schedule` 本身**不支持 tags**（只有 schedule group 支持），所以 schedule 上看不到这些 tag。S3 object 和 Lambda 自动建的 log stream 也不带 tag。

## Security Considerations

| Topic | Current posture | Recommended hardening |
|---|---|---|
| Secrets | Terraform 只建 container；值用 CLI 放，不进 tfvars / tfstate / log；Telegram error message 不含 URL | 开 Secrets Manager rotation reminder；token 半年换一次 |
| Inbound exposure | 没有 API Gateway / Function URL / VPC；全部 outbound | — |
| Ebteqdesk call | 强制 `https://`；token 只放 header；HTML 200 当失败；`X-Trigger-Id` 格式验证 | Ebteqdesk 端加 IP allowlist（Lambda 没有固定 IP，需要 NAT，本项目不做） |
| IAM | 四个 role 各自最小权限；Scheduler trust 带 `aws:SourceAccount`；SNS topic policy 带 `aws:SourceAccount` | Scheduler trust 再加 `aws:SourceArn`（schedule ARN） |
| S3 | Block Public Access、`BucketOwnerEnforced`、SSE-S3、TLS-only、180 天过期 | 需要审计时开 access logging |
| SQS | SSE-SQS；sync DLQ redrive 只允许 trigger queue | — |
| SNS | 未加密（CloudWatch 不能用 AWS managed key publish） | 若要加密需 CMK（本项目刻意不用） |
| Portal whitelist | runner 只接受 `ALLOWED_PORTALS`；非法 portal 马上 Telegram、不重试 | — |

## Cost Estimate

| Resource | Quantity | Monthly cost (USD) |
|---|---|---|
| EventBridge Scheduler | ~400 invocations | 0.00（free tier 14M） |
| SQS | < 2,000 requests | 0.00 |
| Lambda（arm64） | ~400 runner + 22 reporter invocations | 0.00（free tier 内） |
| SNS | 少量 | 0.00 |
| Secrets Manager | 2 secrets | 0.80 |
| CloudWatch alarms | 4 standard alarms | 0.40 |
| CloudWatch custom metrics（EMF） | 5 × 2 portal + 1 + 3 × 2 portal = 17 | 5.10 |
| CloudWatch Logs | < 1 GB | ~0.50 |
| S3 | < 100 MB | ~0.01 |
| **Total** | | **~6.80** |

> 最大的一项是 EMF custom metric（每个 metric × dimension 组合 US$0.30/月）。如果不需要 per-brand 的日报 metric，可以只留 `ReportGenerated`，省下约 US$1.80。
> 估算工具：[AWS Pricing Calculator](https://calculator.aws/)。

## Destroying the Stack

```bash
# 1. 先把报告 bucket 清空（bucket 没有 force_destroy，里面有 object 时 destroy 会失败）
aws s3 rm "s3://$(terraform output -raw report_bucket)" --recursive

# 2. Destroy
terraform destroy
```

以下**不**由 Terraform 管理，destroy 后仍然存在：

- Secrets Manager 的 secret 会进入 **7 天 recovery window**，期间同名 secret 不能重建（可用 `aws secretsmanager delete-secret --force-delete-without-recovery` 立刻删）。
- Ebteqdesk 那边的 trigger API、`business_sync_remote_runs` 表、`BUSINESS_SYNC_TRIGGER_TOKEN` env。
- Telegram bot 和告警群。
- `terraform/.build/lambda.zip`（本地 build 产物）。

## Frequently Asked Questions

**Q: runner 报 401 / 503 / "不是 JSON"（类似 LB 的 502）是什么意思？**
A: 401 = AWS secret 的 token 和 Ebteqdesk 的 `BUSINESS_SYNC_TRIGGER_TOKEN` 不一致；503 = Ebteqdesk 没设 token；"不是 JSON" = 收到 HTML（firewall challenge、登录页、Laravel Cloud 维护页）。这三种都算失败，走正常的重试 + streak 提醒。

**Q: 为什么所有 brand 共用一个 queue 和一个 runner？会不会集中在一个点出事？**
A: 刻意的（CLAUDE.md 的 shared-infra 约束）：一天最多 17 条消息，一个 runner（max concurrency 2）足够，alarm 和 DLQ 也只要一套。每个 brand 的隔离在 Ebteqdesk（settings、lock）和 schedule 层；Salon V3 失败不会影响 Warni 的消息。Lambda 本身跨 AZ，没有单一 AZ 的问题。

**Q: 为什么只重试一次，而且间隔 15 分钟？**
A: 下一个排程最多一小时后就到。旧的夜间模型（3 次 × 90 分钟）会和下一个整点重叠。现在：attempt 1 → 15 分钟后 attempt 2 → ~30 分钟进 DLQ → 下一个整点重新来过。

**Q: 为什么提醒规则是"第 1 次，之后每 3 次"？**
A: 每小时跑一次，如果 POS 挂一整个下午，每次都发会有 8 条一样的消息。第 1 次马上告诉你，之后每 3 小时提醒一次还没好，恢复时发一条 ✅。18:00 日报再汇总。`alert_every_n_failures` 可以调。

**Q: 怎么更新 Lambda code？**
A: 改 `lambda/` 下的文件，跑 `python -m pytest -q`，再 `terraform apply`。`archive_file` 会重新打包，`source_code_hash` 变了三个 function 都会更新。

**Q: 要不要用 remote state？**
A: 正式环境建议用 S3 backend + DynamoDB lock（或 S3 native locking）。这个仓库没有写死 backend，`terraform init -backend=false` 可以离线验证。

**Q: 马来西亚公共假期会跑吗？**
A: 会。目前**没有**排除公共假期（open question）。假期当天没人 onboard 客户，跑了也只是没有变动；日报照常发。如果要跳过，需要加一个假期清单（例如在 runner / reporter 里判断）或假期前手动 disable schedule。

**Q: 要加 HTTPS 吗？**
A: 没有 inbound endpoint，不需要。所有 outbound 调用都已经是 HTTPS，`ebteqdesk_base_url` 的 validation 也只接受 `https://`。
