# FinOps Pipeline Digest: How the CORTEX Daily Cost Message Is Produced

Written 2026-10-13; describes the code as it is on disk in this folder (`Cloud-Tibot/`, identical to `HEAD` on branch `feat/pos-dlq-pipeline`), read without making any AWS, Lambda, Terraform or Telegram call.

> All `path:line` references are relative to `/Users/brendonang/Code/AWS Project/Cloud-Tibot/`.

## Table of Contents

1. [Summary](#summary)
2. [End-to-End Flow](#end-to-end-flow)
3. [Q1. Trigger](#q1-trigger)
4. [Q2. Which Code Produces the Digest](#q2-which-code-produces-the-digest)
5. [Q3. Cost Data](#q3-cost-data)
6. [Q4. Top Spenders](#q4-top-spenders)
7. [Q5. Telegram Delivery](#q5-telegram-delivery)
8. [Q6. Weekly Report and the Webhook Route](#q6-weekly-report-and-the-webhook-route)
9. [Q7. IAM](#q7-iam)
10. [Q8. Docs vs Code](#q8-docs-vs-code)
11. [Q9. Bot Token Handling](#q9-bot-token-handling)
12. [Gotchas and Things Worth Knowing](#gotchas-and-things-worth-knowing)
13. [Verified vs Inferred](#verified-vs-inferred)

## Summary

Every day at 01:00 UTC, which is 09:00 in Singapore and Malaysia, an EventBridge schedule invokes the
FinOps Sentinel Lambda (Module 3) with a one-field payload, `{"report_type": "daily"}`. The Lambda makes
two Cost Explorer `GetCostAndUsage` requests (yesterday's cost per service, and the month-to-date total),
formats the result as a short text message, and posts it with the Telegram Bot API `sendMessage` method
into one forum topic of the team supergroup. The bot token, chat ID and topic ID are plain Lambda
environment variables filled from Terraform variables; Secrets Manager is not used by this Lambda. The
same Lambda also sends a longer weekly report on Mondays and answers an unauthenticated
`POST /webhook/finops` route. Two things need the Boss's attention: the message seen in Telegram today is
not what the code in this folder would print, so the deployed Lambda is running a different build from the
one in git, and a real-looking bot token is committed in 11 places in a repository that GitHub reports as
public.

## End-to-End Flow

```
┌──────────────────────────────────────────────────────────────────────┐
│ EventBridge rule  <project_name>_finops_daily_report                 │
│ schedule: cron(0 1 * * ? *)  =  01:00 UTC  =  09:00 SGT, every day   │
└──────────────────────────────────────────────────────────────────────┘
                                   │  async invoke, constant input:
                                   │  {"report_type": "daily"}
                                   ▼
┌──────────────────────────────────────────────────────────────────────┐
│ Lambda  <project_name>_finops_sentinel   (python3.11, us-east-1)     │
│ handler: lambda_function.lambda_handler                              │
│                                                                      │
│  1. top-level event key report_type is "daily"                       │
│  2. read env: TELEGRAM_TOKEN, TELEGRAM_CHAT_ID, TELEGRAM_TOPIC_ID    │
│  3. handle_finops_report("daily", token, chat_id, topic_id)          │
└──────────────────────────────────────────────────────────────────────┘
           │
           ├── Cost Explorer call 1: GetCostAndUsage
           │     period [yesterday, today)  DAILY  BlendedCost
           │     GroupBy SERVICE; drop < $0.001; sort high to low
           │
           ├── Cost Explorer call 2: GetCostAndUsage
           │     period [1st of month, today)  MONTHLY  UnblendedCost
           │     no grouping; skipped on the 1st of the month
           ▼
┌──────────────────────────────────────────────────────────────────────┐
│ _build_daily_message()                                               │
│ header, date line, Yesterday, Month-to-Date,                         │
│ up to 12 top spenders with an emoji each, Cost Explorer console link │
└──────────────────────────────────────────────────────────────────────┘
                                   │  HTTPS POST (urllib3), JSON body:
                                   │  chat_id, text, parse_mode=Markdown,
                                   │  message_thread_id=<topic id>
                                   ▼
┌──────────────────────────────────────────────────────────────────────┐
│ Telegram Bot API   https://api.telegram.org/bot<token>/sendMessage   │
└──────────────────────────────────────────────────────────────────────┘
                                   │
                                   ▼
┌──────────────────────────────────────────────────────────────────────┐
│ Supergroup forum topic "FinOps Sentinel"                             │
│ message shows under the bot's display name, stamped 9:00 AM (UTC+8)  │
└──────────────────────────────────────────────────────────────────────┘
```

**Flow in one line:** EventBridge schedule, then Lambda `lambda_handler`, then two Cost Explorer reads,
then a formatted string, then one `sendMessage` POST, then the FinOps forum topic.

The same Lambda has two other entrances, covered in [Q6](#q6-weekly-report-and-the-webhook-route):

| Entrance | Trigger | Payload | Code path |
|---|---|---|---|
| Daily digest | `finops_daily_report` rule | `{"report_type":"daily"}` | `handle_finops_report`, daily branch |
| Weekly deep dive | `finops_weekly_report` rule, Mondays | `{"report_type":"weekly"}` | `handle_finops_report`, weekly branch |
| Webhook | API Gateway `POST /webhook/finops` | HTTP request, JSON in `body` | plan review or AI agent handlers |

## Q1. Trigger

### What fires the run

| Item | Daily | Weekly |
|---|---|---|
| Terraform resource | `aws_cloudwatch_event_rule.finops_daily_report` (`infrastructure/terraform/eventbridge.tf:137-146`) | `aws_cloudwatch_event_rule.finops_weekly_report` (`infrastructure/terraform/eventbridge.tf:162-171`) |
| Rule name | `<project_name>_finops_daily_report` | `<project_name>_finops_weekly_report` |
| Schedule | `cron(0 1 * * ? *)` (`eventbridge.tf:140`) | `cron(0 1 ? * MON *)` (`eventbridge.tf:165`) |
| Meaning | every day, 01:00 UTC = 09:00 SGT | every Monday, 01:00 UTC = 09:00 SGT |
| Target input | `jsonencode({ report_type = "daily" })` (`eventbridge.tf:153`) | `jsonencode({ report_type = "weekly" })` (`eventbridge.tf:178`) |
| Target retry policy | 2 attempts, max event age 3600 s (`eventbridge.tf:155-158`) | same (`eventbridge.tf:180-183`) |
| Permission to invoke | `aws_lambda_permission.finops_sentinel_eventbridge_daily` (`infrastructure/terraform/lambda.tf:163-169`) | `aws_lambda_permission.finops_sentinel_eventbridge_weekly` (`lambda.tf:172-178`) |

EventBridge rule cron expressions are evaluated in UTC and Singapore has no daylight saving, so the run
is always 09:00 local. The "9:00 AM" under the message is Telegram's own timestamp shown in the viewer's
timezone; the code does not print a time.

> `<project_name>` is `cortex` by default (`infrastructure/terraform/variables.tf:20-24`), giving
> `cortex_finops_sentinel`, the name the docs call live (`FINOPS_SETUP_CHECKLIST.md:5`,
> `AUDIT_RESULT.md:30`). `infrastructure/terraform.tfvars.dev:4` sets it to `cloud-tibot` instead. Which
> name is actually posting the digest was not checked against AWS.

### What the Lambda receives

Because each target sets a constant `input`, the Lambda's `event` is exactly that JSON object:

```json
{"report_type": "daily"}
```

It is not the usual scheduled-event envelope, so there is no `time`, `source` or `detail-type` field to
read. The handler logs the whole event first (`src/module3/lambda_function.py:520`).

### How the handler tells the three callers apart

| Step | Code | Behaviour |
|---|---|---|
| 1 | `src/module3/lambda_function.py:523-524` | Reads `event.get("report_type")`. If it is `"daily"` or `"weekly"`, this is a scheduled run |
| 2 | `src/module3/lambda_function.py:525-528` | Reads `TELEGRAM_TOKEN`, `TELEGRAM_CHAT_ID`, `TELEGRAM_TOPIC_ID` and returns `handle_finops_report(...)` |
| 3 | `src/module3/lambda_function.py:531` | Anything else is treated as an API Gateway call: `json.loads(event.get("body", "{}"))` |
| 4 | `src/module3/lambda_function.py:323`, `:344` | Inside `handle_finops_report`, `report_type` selects the daily or weekly branch |

The handler does not inspect `routeKey`, `source` or headers. An HTTP caller cannot reach the scheduled
path, because with payload format 2.0 (`infrastructure/terraform/api_gateway.tf:98`) the request body
arrives as a string inside `event["body"]`, not as top-level keys. The `else` branch for an unknown
`report_type` (`src/module3/lambda_function.py:370-371`) is unreachable from `lambda_handler`.

## Q2. Which Code Produces the Digest

### What Terraform packages

| Evidence | Reference |
|---|---|
| The zip for Module 3 is built from `src/module3/build/package/`, not from `src/module3/` or `scripts/` | `infrastructure/terraform/lambda.tf:126-130` (`source_dir` at `:128`) |
| The function uses that zip and the entry point `lambda_function.lambda_handler` | `lambda.tf:133`, `:136-137` |
| `build/package/` is created by the build script: `pip install -r requirements.txt -t` into it, then copy every `*.py` from `src/module3/` | `Build-LambdaPackages.ps1:31-32`, `:50`, `:81-85`, `:182` |
| So the packaged `lambda_function.py` is a copy of `src/module3/lambda_function.py` at build time, plus vendored `urllib3`, `boto3`, `PyJWT`, `cryptography` | `src/module3/requirements.txt:5-10` |
| `scripts/daily_cost.py` is referenced by no Terraform file, workflow or other script | search of all 181 tracked files; the only hits are inside the file itself |
| `scripts/daily_cost.py` could not run as this Lambda: no `lambda_handler`, imports `requests`, reads different variable names | `scripts/daily_cost.py:26`, `:32-34`, `:284-328` |

> `src/module3/build/package/` does not exist in this checkout and is ignored by git (`.gitignore:37`,
> `.gitignore:41`). The exact files that were zipped and uploaded therefore cannot be inspected here.
> Modules 1 and 2 zip their source folders directly (`lambda.tf:17`, `lambda.tf:65`); only Module 3 goes
> through a build directory.

### Which implementation matches the live message

The emoji next to each service is a usable fingerprint, because the two implementations choose emoji
differently.

| Aspect | `src/module3/lambda_function.py` | `scripts/daily_cost.py` | Live message (2026-10-13) |
|---|---|---|---|
| Emoji lookup | exact match on lowercased name, fallback blue diamond (`:64-65`) | substring match, fallback money-with-wings (`:76-82`) | consistent with exact match |
| AWS Secrets Manager | blue diamond (fallback) | key (`:69`) | blue diamond |
| AmazonCloudWatch | blue diamond (fallback) | bar chart (`:59-60`) | blue diamond |
| AWS Cost Explorer | blue diamond (fallback) | money-with-wings (fallback) | blue diamond |
| AWS Key Management Service | key (`:41`) | closed lock with key (`:70`) | key |
| Maximum rows | 12 (`:56`) | 5 (`:36`) | 4 shown |
| Minimum cost | $0.001 (`:55`) | $0.01 (`:37`) | not determinable |
| Date line | `Date: <yesterday>` (`:213`) | `Date: <yesterday>` (`:221`) | `Costs for: <date> (sent <date>)` |
| Parse mode | legacy `Markdown` (`:1049`) | `MarkdownV2` (`:263`) | not determinable |

All four emoji match the Module 3 Lambda and none match `scripts/daily_cost.py`, so the digest comes from
the Lambda lineage.

### What `scripts/daily_cost.py` is for

It is a standalone command-line version of the same report. It uses whatever AWS credentials are in the
shell, reads `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID` and `TELEGRAM_TOPIC_FINOPS`
(`scripts/daily_cost.py:32-34`), and prints a dry-run preview instead of sending when the token or chat
ID is missing (`scripts/daily_cost.py:251-257`). Its dependencies are listed separately in
`scripts/requirements.txt:5-10`. The sibling `scripts/weekly_cost_report.py` says its variables are
"injected by GitHub Actions" (`scripts/weekly_cost_report.py:10-18`). Both look like the local or CI
predecessors of what the Lambda now does on a schedule, but no workflow in this folder runs either one.

### Caveat: the deployed build is not the one in git

> The live message cannot have been produced by the code in this folder as written.
>
> - The wording `Costs for:` and `(sent ...)` appears nowhere in the working tree and nowhere in git
>   history for this folder (`git log --all -S` returns nothing). The code prints `Date:` instead
>   (`src/module3/lambda_function.py:213`).
> - The code writes MarkdownV2-style escapes such as `Month\-to\-Date`, `\(Yesterday\)` and `1\.`
>   (`src/module3/lambda_function.py:217`, `:219`, `:226`) but sends with legacy `Markdown`
>   (`src/module3/lambda_function.py:1049`). The Bot API documentation defines backslash escaping in
>   legacy mode only for `_`, `*`, `` ` `` and `[`, so those backslashes would be expected to show in the
>   chat. The live message shows none.
>
> The folder has a single commit (`defb2c2`, 2026-06-09). The deployed function was evidently updated
> from somewhere else afterwards. Direct code pushes are already a habit in this project:
> `deploy_lambda.py:12-14` and `revert_lambda.py:36-38` call `update_function_code` on another CORTEX
> Lambda, and `Build-LambdaPackages.ps1:121-125` recommends `aws lambda update-function-code`.
> Everything below describes the repository version, which is the closest available ancestor.

## Q3. Cost Data

### API calls on the daily path

| # | boto3 call | Time period | Granularity | Metric | Group-by | Filter | Code |
|---|---|---|---|---|---|---|---|
| 1 | `ce.get_cost_and_usage` | `Start` = yesterday, `End` = today | `DAILY` | `BlendedCost` | `DIMENSION` / `SERVICE` | none | `src/module3/lambda_function.py:72-92`, called at `:330` |
| 2 | `ce.get_cost_and_usage` | `Start` = first of the month, `End` = today | `MONTHLY` | `UnblendedCost` | none | none | `src/module3/lambda_function.py:185-201`, called at `:339` |

The client is `boto3.client("ce", region_name="us-east-1")` (`src/module3/lambda_function.py:318`). The
`End` date is exclusive in the Cost Explorer API, so call 1 covers exactly one day and call 2 covers the
first of the month through yesterday. No amortized or net metric is used anywhere.

> With no filter, both calls cover every region and every record type (usage, tax, credits, refunds) in
> the account, and member accounts too if this is an Organizations management account.

> The two figures use different metrics. The comment at `src/module3/lambda_function.py:328` says
> `UnblendedCost` for call 1, but the code requests `BlendedCost` (`:78`, `:86`). On a standalone account
> the two metrics are the same number.

### How "Yesterday" and "Month-to-Date" are computed

| Figure | Computation | Code |
|---|---|---|
| Per-service cost | Sum of `BlendedCost` per `SERVICE` key over the returned days (one day here) | `src/module3/lambda_function.py:83-87` |
| Yesterday | Sum of the per-service costs that are at least $0.001 | `src/module3/lambda_function.py:331` |
| Month-to-Date | Sum of `Total.UnblendedCost.Amount` over the returned periods; a separate, ungrouped query | `src/module3/lambda_function.py:195-198` |
| Month-to-Date on the 1st | Returns `0.0` without calling the API | `src/module3/lambda_function.py:187-188` |
| Month-to-Date on API error | Returns `0.0` and logs | `src/module3/lambda_function.py:199-201` |

"Yesterday" is therefore the total of the listed services, not the account total: services under $0.001
and any service with a net credit are left out. In the Boss's message 0.11 + 0.04 + 0.04 + 0.02 = 0.21,
which agrees. "Month-to-Date" includes yesterday, excludes today, and is not derived from call 1.

### Dates and timezone

| Value | Derivation | Code |
|---|---|---|
| `today` | `date.today()` in the Lambda process | `src/module3/lambda_function.py:321` |
| `yesterday` | `today - timedelta(days=1)` | `src/module3/lambda_function.py:325` |
| `mtd_start` | `today.replace(day=1)` | `src/module3/lambda_function.py:326` |
| Date printed | `yesterday`, as `YYYY-MM-DD` | `src/module3/lambda_function.py:213`, `:342` |

The Lambda sets no `TZ` variable (`infrastructure/terraform/lambda.tf:142-154`), so `date.today()` is the
UTC date. Cost Explorer's daily buckets are UTC days as well. A run at 01:00 UTC on 2026-10-13 gives
`today` = 2026-10-13 and `yesterday` = 2026-10-12. In Singapore terms, "yesterday" is 08:00 on the 12th
to 08:00 on the 13th.

> The live line `Costs for: 2026-10-12 (sent 2026-10-13)` is not in this repository, so how its two dates
> are derived cannot be traced. By analogy the first is `yesterday` and the second is the run date. At
> 01:00 UTC the UTC date and the Singapore date are the same calendar day, so the sample cannot show which
> timezone the deployed build uses.

### Request count and the $0.04 Cost Explorer line

| Run | Cost Explorer requests | Why |
|---|---|---|
| Daily, not the 1st | 2 | one grouped query plus one month-to-date query; more only if the response paginates (`src/module3/lambda_function.py:81-91`) |
| Daily, on the 1st | 1 | month-to-date query skipped (`src/module3/lambda_function.py:187-188`) |
| Weekly, Mondays | 2, plus up to 5 | two 7-day breakdowns (`:352-353`) plus a drill-down per top-5 service (`:362-365`) |

At $0.01 per request, the daily run alone costs $0.02 and does not explain $0.04. However 2026-10-12 was a
Monday, so the weekly rule fired in the same minute. Daily (2) plus the weekly run's two breakdown
requests (2) is 4 requests, or $0.04, which matches the digest.

> This reconciliation is an inference. It holds only if the weekly run's five drill-down requests were
> rejected and not billed; they use a group-by that the API does not list as valid (see
> [Q6](#q6-weekly-report-and-the-webhook-route)). If rejected requests are billed, the day would be up to
> $0.09. Other Cost Explorer API users in the account (CLI sessions, audits, agent tooling) cannot be
> ruled out, and the deployed build may not make the same calls as the repository version. On a
> non-Monday the repository code accounts for $0.02.

## Q4. Top Spenders

| Rule | Value | Code |
|---|---|---|
| Sort order | descending by yesterday's cost | `src/module3/lambda_function.py:332-335` |
| Minimum cost | `_MIN_COST = 0.001` USD; smaller services are dropped | `src/module3/lambda_function.py:55`, `:333` |
| Maximum rows | `_TOP_SERVICES = 12`; no "other" roll-up on the daily digest | `src/module3/lambda_function.py:56`, `:224` |
| Amount format | two decimals, so $0.001 to $0.0049 prints as `$0.00` | `src/module3/lambda_function.py:226` |
| Nothing above the minimum | prints a "no significant spend" line | `src/module3/lambda_function.py:221-222` |

Four rows appear in the Boss's message because four services cleared the minimum that day, not because of
a limit of four.

The emoji comes from `_service_emoji` (`src/module3/lambda_function.py:64-65`). It lowercases the service
name returned by Cost Explorer and does an exact dictionary lookup in `_SERVICE_EMOJIS`
(`src/module3/lambda_function.py:25-53`); anything not found gets the fallback. The relevant lines,
verbatim:

```python
    "amazon cloudwatch":                   "📊",
    "aws key management service":          "🔑",
    "amazon secrets manager":              "🔒",

def _service_emoji(name: str) -> str:
    return _SERVICE_EMOJIS.get(name.lower(), "💠")
```

| Service name from Cost Explorer | Lowercased lookup key | In the map? | Result |
|---|---|---|---|
| `AWS Secrets Manager` | `aws secrets manager` | No. The map key is `amazon secrets manager` (`:46`) | fallback, the blue diamond |
| `AmazonCloudWatch` | `amazoncloudwatch` | No. The map key is `amazon cloudwatch`, with a space (`:38`) | fallback |
| `AWS Cost Explorer` | `aws cost explorer` | No entry | fallback |
| `AWS Key Management Service` | `aws key management service` | Yes (`:41`) | the key |

Secrets Manager gets the diamond because the map names the service "Amazon" where Cost Explorer says
"AWS". KMS gets the key because its map entry happens to match Cost Explorer's name exactly.

## Q5. Telegram Delivery

### The request

| Property | Value | Code |
|---|---|---|
| Bot API method | `sendMessage`, HTTP POST to `https://api.telegram.org/bot<token>/sendMessage` | `src/module3/lambda_function.py:1045`, `:1055-1059` |
| HTTP client | `urllib3.PoolManager()`, JSON body, no explicit timeout or retry setting | `src/module3/lambda_function.py:1044` |
| `text` | the built message, cut to 4096 characters | `src/module3/lambda_function.py:1048` |
| `parse_mode` | `Markdown` (the legacy mode) | `src/module3/lambda_function.py:1049` |
| `chat_id` | value of `TELEGRAM_CHAT_ID` | `src/module3/lambda_function.py:526`, `:1047` |
| `message_thread_id` | `int(TELEGRAM_TOPIC_ID)`, only added when the variable is non-empty | `src/module3/lambda_function.py:527`, `:1052-1053` |
| Link at the bottom | Markdown link to the Cost Explorer console dashboard | `src/module3/lambda_function.py:229` |

The display name and avatar ("CLOUD TIBOT") belong to the bot's BotFather profile, not to the code.

### Where chat, topic and token come from

| Value | Lambda variable | Terraform wiring | Terraform variable | Value source |
|---|---|---|---|---|
| Bot token | `TELEGRAM_TOKEN` | `infrastructure/terraform/lambda.tf:144` | `telegram_token`, sensitive, no default (`infrastructure/terraform/variables.tf:32-36`) | a `-var-file`; a value is present at `infrastructure/terraform.tfvars.dev:9` |
| Chat ID | `TELEGRAM_CHAT_ID` | `lambda.tf:145` | `telegram_chat_id`, sensitive (`variables.tf:38-42`) | a `-var-file` (`infrastructure/terraform.tfvars.dev:10`) |
| Topic ID | `TELEGRAM_TOPIC_ID` | `lambda.tf:146` | `telegram_topic_finops_sentinel`, default `""` (`variables.tf:57-61`) | `134` in `infrastructure/terraform.tfvars.dev:16` and `infrastructure/terraform.tfvars.example:16`; empty in `infrastructure/terraform.tfvars.staging:22` |

No Secrets Manager entry is involved. The three secrets in `infrastructure/terraform/secrets.tf:14-42`
(under `/cortex-infra/`) belong to a different Lambda, the Telegram approval handler, and are created
empty (`secrets.tf:4-5`). If the topic variable is empty the message goes to the group's General topic.

> `sensitive = true` only hides the values in plan output. They are stored in plain text in the Lambda
> configuration and in the Terraform state object (`infrastructure/terraform/backend.tf:34-42`).

### Failure handling

| Failure | What the code does | Result |
|---|---|---|
| Cost Explorer call 1 raises | Not caught (`src/module3/lambda_function.py:82`, `:330`) | Invocation fails; nothing is posted to Telegram |
| Cost Explorer call 2 raises | Caught, returns `0.0` (`src/module3/lambda_function.py:199-201`) | Digest is sent showing Month-to-Date as `$0.00` |
| Telegram answers non-200 | Prints the response body (`src/module3/lambda_function.py:1063`) | Handler still returns 200 "report sent" (`:376-379`); message is lost |
| Network error to Telegram | Caught, prints the exception (`src/module3/lambda_function.py:1064-1065`) | Same as above |
| `TELEGRAM_TOPIC_ID` not a number | `int()` sits outside the `try` (`src/module3/lambda_function.py:1053`) | Invocation fails |
| `TELEGRAM_TOKEN` or `TELEGRAM_CHAT_ID` missing | `os.environ[...]` raises `KeyError` (`src/module3/lambda_function.py:525-526`) | Invocation fails |
| Message longer than 4096 characters | Truncated (`src/module3/lambda_function.py:1048`) | May cut a Markdown entity in half, which Telegram rejects |

There is no retry loop in the code. The only configured retry is the EventBridge target policy
(`infrastructure/terraform/eventbridge.tf:155-158`), which covers delivery of the event to Lambda. No
dead-letter queue, no on-failure destination, no `aws_lambda_function_event_invoke_config` and no
CloudWatch alarm exists in `infrastructure/terraform/`.

> When an invocation fails, the Lambda service's default behaviour for asynchronous invocations applies,
> which is to retry the function. Each retry repeats the Cost Explorer requests. That default is general
> AWS behaviour and is not set anywhere in this Terraform.

## Q6. Weekly Report and the Webhook Route

### Weekly report

On Mondays the second rule sends `{"report_type":"weekly"}` to the same Lambda and the same
`handle_finops_report` function (`src/module3/lambda_function.py:344-369`). It makes two
`_get_cost_by_service` requests, for the last 7 days and the 7 days before that (`:346-353`), merges them
into a per-service table with delta and week-over-week percentage, and flags a spike at 50 percent growth
and more than $0.10 (`:137-156`, `:59-60`). It adds a count of Lambda invocations from CloudWatch
`GetMetricStatistics` (`:120-134`), attempts a per-resource drill-down for the top five services
(`:362-365`), and sends a message titled "DND Platform — Weekly Deep Dive" (`:245`) with an alert line when
the week exceeds $30 (`:61`, `:242`). It shares the entry function, `_get_cost_by_service`,
`_service_emoji`, the `_MIN_COST` and `_TOP_SERVICES` constants, `send_telegram_message`, the environment
variables and the topic with the daily path. Because the daily rule also fires on Mondays, two messages
arrive at 09:00 that day.

> The drill-down groups `get_cost_and_usage` by `RESOURCE_ID` (`src/module3/lambda_function.py:98-104`).
> The Cost Explorer API reference lists the valid group-by dimensions for `GetCostAndUsage` and
> `RESOURCE_ID` is not among them; resource-level data needs `GetCostAndUsageWithResources`, an opt-in
> feature limited to the last 14 days and a different IAM action. The call is expected to fail, the
> `except` swallows it (`:115-117`), and the report prints "no resource data" (`:167-168`).

### `POST /webhook/finops`

API Gateway (HTTP API, `AWS_PROXY`, payload 2.0) routes `POST /webhook/finops` to the same Lambda
(`infrastructure/terraform/api_gateway.tf:93-108`); the URL is exported as `finops_webhook_url`
(`infrastructure/terraform/outputs.tf:18-21`). With no `report_type` at the top level, the handler parses
the HTTP body (`src/module3/lambda_function.py:531`), creates a GitHub App installation token
(`:544-546`), and routes on `alert_type` (`:549-556`): `terraform_plan_review` scores a Terraform plan
with a static price table (`:614-735`), while `terraform_failure` and the default `cost_alert` run an AI
agent that can read the repository and open pull requests (`:742-878`). The result is posted to the same
topic through the same `send_telegram_message` and the same three variables (`:559-564`). This path never
calls Cost Explorer. No file in this folder calls the route.

> The route has no authorizer (`infrastructure/terraform/api_gateway.tf:104-108`), CORS allows any origin
> (`api_gateway.tf:18-23`), and the handler checks no signature or shared secret. Anyone with the URL can
> post text into the FinOps topic or start the agent.

> `CopilotAgent` is used at `src/module3/lambda_function.py:778` and `:847` but is never imported; the
> only import from that module is `get_installation_token, GitHubAPI` (`:544`). As written, the
> `cost_alert` and `terraform_failure` branches would stop with `NameError`. Only `terraform_plan_review`
> can complete.

### The `dnd-deploy.yml` notification

`.github/workflows/dnd-deploy.yml:328-368` is the last job of a "DND Platform Deployment" workflow. After a
push to `main` or a manual run (`dnd-deploy.yml:3-24`) it posts a deployment result message (infrastructure,
Lambda, frontend and test status) with `curl` to `sendMessage`, routed to the FinOps topic when the GitHub
secret `TELEGRAM_TOPIC_FINOPS` is set (`dnd-deploy.yml:337-339`, `:363-368`).

| Aspect | Daily digest | `dnd-deploy.yml` notification |
|---|---|---|
| What it reports | AWS cost | CI/CD deployment outcome |
| Trigger | EventBridge schedule | push to `main` or manual dispatch |
| Runs in | Lambda | GitHub Actions runner |
| Credentials | Lambda environment variables | GitHub secrets `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`, `TELEGRAM_TOPIC_FINOPS` |
| Cost Explorer | 2 requests | none |

> This file sits in `Cloud-Tibot/.github/workflows/`. GitHub only runs workflows from the repository
> root, and the root of this repository holds four `terraform-*.yml` files and nothing for Cloud-Tibot, so
> the workflow is inert here. It only shares the topic by naming convention.

## Q7. IAM

Role `<project_name>_lambda_finops_sentinel_role` (`infrastructure/terraform/iam.tf:116-124`), trusted by
`lambda.amazonaws.com` (`iam.tf:13-24`).

| Permission | Granted by | Used by the code |
|---|---|---|
| CloudWatch Logs write (managed policy `AWSLambdaBasicExecutionRole`) | `infrastructure/terraform/iam.tf:127-130` | Yes, all `print` output |
| `ce:GetCostAndUsage` on `*` | `infrastructure/terraform/iam.tf:141-145` | Yes: `src/module3/lambda_function.py:82`, `:98`, `:190` |
| `cloudwatch:GetMetricStatistics` on `*` | `infrastructure/terraform/iam.tf:146-151` | Yes, weekly only: `src/module3/lambda_function.py:123` |

| Who may invoke the function | Granted by |
|---|---|
| `events.amazonaws.com`, from the daily rule ARN | `infrastructure/terraform/lambda.tf:163-169` |
| `events.amazonaws.com`, from the weekly rule ARN | `infrastructure/terraform/lambda.tf:172-178` |
| `apigateway.amazonaws.com`, any route and stage of the CORTEX API | `infrastructure/terraform/lambda.tf:192-198` |

The role matches what the code calls, with nothing spare: every granted action is used, and the code makes
no AWS call that is not granted. It has no Secrets Manager, DynamoDB, SNS or
`ce:GetCostAndUsageWithResources` permission, and the code never calls those. Telegram and GitHub are
reached over plain outbound HTTPS, which IAM does not govern.

## Q8. Docs vs Code

### Claims the code does not back

| Claim | Where it is made | What the code does |
|---|---|---|
| A DynamoDB table `finops-cost-history` stores 90 days of cost history | `FINOPS_SETUP_CHECKLIST.md:14-17`, `:162-164`; `README.md:18`, `:94`, `:182`, `:461-475` | No DynamoDB call in `src/module3/lambda_function.py`, no such table in `infrastructure/terraform/dynamodb.tf` (only `cortex_radar_state`, `:8`), no DynamoDB permission. Creating the table would change nothing |
| CloudWatch cost-threshold alarms | `FINOPS_SETUP_CHECKLIST.md:42-74` | Not in Terraform; the Lambda neither needs nor reads them |
| SNS topic as a backup channel | `FINOPS_SETUP_CHECKLIST.md:82-107`; `README.md:260-279` | No SNS code or permission |
| Real-time anomaly alerts through an "Anomaly Detected" EventBridge rule | `README.md:15`, `:38-45`, `:80`, `:90`, `:346-356` | `infrastructure/terraform/eventbridge.tf` has only the two schedules (`:137-184`) and Amplify rules. The only spike logic is in the weekly report |
| "Top 4 services" | `README.md:14`, `:505` | Up to 12 rows, no cap of four |
| Sample digest, `format_daily_digest`, `get_service_icon`, a clock time in the footer | `README.md:479-506`, `:535-587` | Those functions do not exist; the sample's emoji are not what the code emits; the code prints no time |
| Variables `cost_anomaly_threshold` and `lambda_memory`, defaults of 60 s and 256 MB | `README.md:317-321`, `:375-384` | Not in `infrastructure/terraform/variables.tf`; real defaults are 300 s and 1024 MB (`:108-118`) |
| Handler "processes cost anomaly events and stores them in DynamoDB" | `README.md:431-459` | The real handler is `src/module3/lambda_function.py:513-573` |
| IAM role has "Telegram API access" | `README.md:92` | IAM does not govern Telegram access |
| Module 3 is triggered by API Gateway only and has 12 functions | `LAMBDA_FUNCTIONS_SUMMARY.md:73-91`; comments at `infrastructure/terraform/lambda.tf:123` and `infrastructure/terraform/iam.tf:113` | The scheduled reports and their helpers are not mentioned; `send_telegram_message` also takes `topic_id` (`src/module3/lambda_function.py:1042`) |
| The function is 1 GB and 300 s | `FINOPS_SETUP_CHECKLIST.md:5` | True for the defaults, but `infrastructure/terraform.tfvars.dev:30-31`, the file `infrastructure/terraform/apply-finops.ps1:21` applies, sets 60 s and 256 MB |
| The EventBridge rules are deployed and running since May | `FINOPS_SETUP_CHECKLIST.md:6-7`; `README.md:24` | `AUDIT_RESULT.md:47-48` and `:130-133`, dated one day earlier, found no rule with the prefix `cortex`. The documents contradict each other |
| Test commands use `BlendedCost` and `parse_mode=HTML` | `FINOPS_SETUP_CHECKLIST.md:202`, `:215` | The code mixes blended and unblended and sends `Markdown` |
| "`terraform.tfvars.dev` is in `.gitignore`" | `TERRAFORM_DEPLOYMENT_GUIDE.md:353` | The file is tracked. The pattern `*.tfvars` (`.gitignore:11`) does not match a name ending in `.dev` |

> `README.md:281` still contains a leftover merge-conflict marker.

> The two alarm commands in `FINOPS_SETUP_CHECKLIST.md:47-74` deserve a second look before anyone runs
> them. `EstimatedCharges` is a cumulative month-to-date figure, not a daily one, so a $3.00 threshold
> would not behave as a daily limit; the second alarm names a metric, `UnblendedCost` in `AWS/Billing`,
> that is not a standard billing metric; and neither alarm has an action. This comes from general
> CloudWatch knowledge and was not tested.

### Things the code does that the docs do not mention

- The Monday resource drill-down and Lambda invocation count (`src/module3/lambda_function.py:95-134`).
- The `terraform_plan_review` mode of the webhook (`src/module3/lambda_function.py:614-735`).
- The webhook being unauthenticated.
- The mix of MarkdownV2 escapes with legacy `Markdown` parse mode.
- The need to run `Build-LambdaPackages.ps1` before Terraform can package Module 3.

### Unfinished checklist items

`FINOPS_SETUP_CHECKLIST.md` has 6 checked items (`:5-10`) and 28 unchecked ones. Its own status line reads
"INCOMPLETE - Missing DynamoDB & Alarms", priority high (`:228-229`), last verified June 10, 2026.

| Group | Lines | Unchecked items |
|---|---|---|
| Recommended actions, today | `:143-146` | 4 |
| Recommended actions, this week | `:149-152` | 4 |
| Recommended actions, this month | `:155-157` | 3 |
| Phase 1, immediate | `:162-166` | 5 |
| Phase 2, today | `:169-172` | 4 |
| Phase 3, this week | `:175-178` | 4 |
| Phase 4, ongoing | `:181-184` | 4 |

> Phase 1 item "Verify Lambda can write to DynamoDB" (`FINOPS_SETUP_CHECKLIST.md:164`) cannot pass with
> the current code and role, because neither touches DynamoDB.

## Q9. Bot Token Handling

### Where the token is read at runtime

| Consumer | Source | Reference |
|---|---|---|
| FinOps Lambda | environment variable `TELEGRAM_TOKEN`, set by Terraform from `var.telegram_token` | `src/module3/lambda_function.py:525`, `:537`; `infrastructure/terraform/lambda.tf:144` |
| `scripts/daily_cost.py` | environment variable `TELEGRAM_BOT_TOKEN` | `scripts/daily_cost.py:32` |
| `scripts/weekly_cost_report.py` | environment variable `TELEGRAM_BOT_TOKEN` | `scripts/weekly_cost_report.py:45` |
| `scripts/telegram_bot.py` | environment variable `TELEGRAM_BOT_TOKEN` | `scripts/telegram_bot.py:267`, `:328` |
| `scripts/test-telegram-topics.py` | environment variable `TELEGRAM_TOKEN` | `scripts/test-telegram-topics.py:66` |
| `scripts/test_topic_routing.py` | hardcoded in the file | `scripts/test_topic_routing.py:20` |
| `dnd-deploy.yml` | GitHub secret `TELEGRAM_BOT_TOKEN` | `.github/workflows/dnd-deploy.yml:337` |

### Token-shaped values in git-tracked files

Method: `git ls-files` piped to `grep -E` with the pattern `\d{8,10}:[A-Za-z0-9_-]{35}`. Values were
compared and classified in memory and never printed. The pattern matches 12 lines.

| File | Line | Finding |
|---|---|---|
| `MODULE1_UPGRADE_SUMMARY.md` | 43 | full token-shaped value, random-looking |
| `README.md` | 137 | full token-shaped value, shown as the live Lambda's `TELEGRAM_TOKEN` |
| `infrastructure/terraform.tfvars.dev` | 9 | full token-shaped value |
| `scripts/deploy_copilot_guardian.sh` | 93 | full token-shaped value |
| `scripts/get_credentials.sh` | 73 | full token-shaped value |
| `scripts/test_cortex_approval_flow.py` | 22 | full token-shaped value |
| `scripts/test_git_radar_webhook.py` | 27 | full token-shaped value |
| `scripts/test_lambda_locally.py` | 15 | full token-shaped value |
| `scripts/test_real_lambda_infra.py` | 24 | full token-shaped value |
| `scripts/test_topic_routing.py` | 20 | full token-shaped value |
| `scripts/trigger_production_workflow.py` | 38 | full token-shaped value |
| `TERRAFORM_DEPLOYMENT_GUIDE.md` | 179 | matches the pattern but is a different, longer string with placeholder wording; looks like a documentation example |

Also found, outside the exact pattern:

| File | Line | Finding |
|---|---|---|
| `README.md` | 93 | a truncated fragment of a token (the numeric part and the first few characters of the secret part) |

The 11 full values are one and the same string. The other `terraform.tfvars.*` files hold placeholders
only: `infrastructure/terraform.tfvars.example:7`, `infrastructure/terraform.tfvars.staging:16` and
`infrastructure/terraform/terraform.tfvars.deploy:4` do not match the pattern.

### Exposure

> - All 12 files are on `origin/main` of `Aterpise-MY/AWS-Projects`, and `gh repo view` reports that
>   repository's visibility as public.
> - `README.md:137` presents the value as the environment variable of the deployed Lambda, verified on
>   June 10, 2026. Whether it is still valid was not tested; nothing was sent to Telegram.
> - If it is the live token, anyone can post as the bot in any chat it belongs to. The safe assumption is
>   that it is compromised: revoke it with BotFather, then update the Lambda variable and the
>   var-file. Deleting it from git afterwards is housekeeping; a public repository's history has already
>   been readable. This is a decision for the Boss and no action was taken.
> - A wider scan for other credential shapes found only placeholders: PEM header lines with no key body
>   in seven locations (documentation, an example var-file and a helper script), and one
>   placeholder-looking API key string at `docs/implementation/CORTEX_GUARDIAN_README.md:69`.

## Gotchas and Things Worth Knowing

1. **The repository is not what is running.** The live message format is absent from git (see
   [Q2](#q2-which-code-produces-the-digest)). Before changing anything, pull the deployed code and compare.
2. **A fresh clone cannot package Module 3.** `infrastructure/terraform/lambda.tf:128` points at
   `src/module3/build/package/`, which is ignored by git and absent here. `Build-LambdaPackages.ps1` must
   run first, and it installs wheels for the machine it runs on.
3. **Two naming schemes exist.** Defaults produce `cortex_*` names; `infrastructure/terraform.tfvars.dev:4`
   produces `cloud-tibot_*` names with 60 s and 256 MB (`:30-31`).
   `infrastructure/terraform/apply-finops.ps1:20-23` applies that file with `-auto-approve`, which skips
   the team's approval gate and, against the shared state, would likely replace resources rather than
   update them. Do not run it without a plan.
4. **"Yesterday" may be incomplete.** The run happens one hour after the UTC day closes, and Cost Explorer
   data lags. The comment "no billing lag" (`src/module3/lambda_function.py:324`) is an assumption. In the
   Boss's message month-to-date averages about $1.22 per day while yesterday shows $0.21; that gap fits
   under-reporting but could equally be lumpy spend earlier in the month.
5. **The two headline numbers do not reconcile.** Yesterday is blended and filtered to services of at
   least $0.001; month-to-date is unblended and unfiltered.
6. **On the 1st of the month** the digest shows Month-to-Date `$0.00` by design
   (`src/module3/lambda_function.py:187-188`). The same `$0.00` appears if the second query fails.
7. **Most emoji map entries can never match.** The lookup is exact, and several keys use names that Cost
   Explorer does not use. Two are proven by the Boss's own message; others, such as the short forms for
   S3, EC2 and RDS, are likely.
8. **Failures are silent.** If Telegram rejects the message the Lambda still reports success, nothing
   retries, and there is no alarm. A missing 09:00 message is the only signal.
9. **The token can end up in logs.** On a connection error the exception text is printed
   (`src/module3/lambda_function.py:1064-1065`), and HTTP client errors normally include the request URL,
   which contains the token.
10. **Legacy Markdown is fragile.** A service name containing `_`, `*`, `` ` `` or `[` would break parsing
    and the whole message would be rejected.
11. **Mondays send two messages**, and the weekly drill-down cannot work with `get_cost_and_usage`.
12. **The webhook is open and partly broken**: no authentication, and two of its three branches would
    raise `NameError`.
13. **The stack lives in `us-east-1`** (`infrastructure/terraform/variables.tf:8-12`), not the team
    default `ap-southeast-1`. Cost Explorer itself covers all regions. The Lambda invocation count in the
    weekly report covers `us-east-1` only.
14. **The digest pays for itself.** About $0.02 per daily run and more on Mondays, roughly $0.70 a month,
    which is a visible share of a bill this small.
15. **Project-local workflows do not run** in this repository, so `dnd-deploy.yml` and the other files
    under `.github/workflows/` here are reference copies.

## Verified vs Inferred

### Verified from code

- Schedules, target payloads and retry policy of both rules (`infrastructure/terraform/eventbridge.tf:137-184`).
- The handler's routing on a top-level `report_type` key (`src/module3/lambda_function.py:523-531`).
- Terraform zips `src/module3/build/package/` for Module 3 (`infrastructure/terraform/lambda.tf:126-130`),
  and the build script fills that directory from `src/module3/*.py` (`Build-LambdaPackages.ps1:81-85`).
- `scripts/daily_cost.py` and `scripts/weekly_cost_report.py` are referenced by nothing else in the 181
  tracked files.
- Both Cost Explorer queries: periods, granularity, metrics, grouping, thresholds and sorting.
- The emoji lookup rule and why each of the four services gets the emoji it does.
- The Telegram request shape, the three environment variables and their Terraform wiring.
- Every row of the failure-handling table, as static reading of the code paths.
- The IAM policy contents and their match to the calls in the code.
- `CopilotAgent` is used but never imported in `src/module3/lambda_function.py`.
- The strings `Costs for` and `(sent` are absent from the working tree and from git history.
- Token-shaped values at the listed paths and lines, that 11 of them are identical, and that the files
  are on `origin/main`.
- The checklist counts: 6 checked, 28 unchecked.
- 2026-10-12 was a Monday.
- Legacy `Markdown` escaping rules, from the Telegram Bot API documentation.
- Valid group-by dimensions for `GetCostAndUsage`, from the botocore service model bundled in this folder.

### Inferred or could not confirm

- **What is deployed.** The live function's code, name (`cortex_*` or `cloud-tibot_*`), memory, timeout,
  environment variables and last-modified date were not read from AWS. Everything about the live build
  beyond the Boss's message is unknown.
- **How the live `Costs for: ... (sent ...)` dates are derived** and in which timezone.
- **Whether the live build makes the same Cost Explorer calls**, uses the same threshold of $0.001, or the
  same row limit.
- **The $0.04 reconciliation.** It assumes rejected requests are not billed and that nothing else called
  the Cost Explorer API that day.
- **That stray backslashes would be visible** with the repository code. This follows from the documented
  escaping rules but was not tested by sending a message.
- **That the event is the bare input object.** This is standard EventBridge behaviour for a constant
  target input and is consistent with the handler, but no real invocation log was read.
- **Lambda's default timezone (UTC) and default asynchronous retry behaviour.** General AWS knowledge, not
  set in this Terraform.
- **That the token is live.** Its validity was deliberately not tested.
- **Public visibility of the repository.** Reported by one read-only `gh repo view` call on 2026-10-13.
- **That `scripts/daily_cost.py` came first** and the Lambda was ported from it. The folder has one
  commit, so the order cannot be shown.
- **The alarm caveats in Q8** and the claim that further emoji map keys never match.
- **Whether the account is an Organizations management account**, which would change what the unfiltered
  queries cover and whether blended and unblended costs differ.
- **That `apply-finops.ps1` would replace rather than update resources.** This follows from the function
  name changing with `project_name`; no plan was run.
- **The untracked, vendored `infrastructure/lambda_src/` tree** was not reviewed as project code; only its
  bundled Cost Explorer API model was read, as a reference. One token-shaped string matched there, in a
  bundled AWS sample-data file that is not in git; it was not inspected.
