# Cloud-Tibot (Project CORTEX) — Resume Summary

> Status: Deployed to `us-east-1` (account `022499047467`) and in live use, but **partially configured**. The 2026-06-09 audit found 5/5 Lambda functions active, the EventBridge schedule rules missing, and a Terraform state checksum mismatch, which was resolved. Figures below come from the project's own audit, test, and fix documents.

## Project Overview

Cloud-Tibot (internal codename **Project CORTEX**) is a serverless ChatOps and FinOps automation platform on AWS. It turns build, source-control, and cost events into Telegram notifications and AI-assisted remediation. It has **four modules (10 Python files, 56+ functions/methods)**. **Module 1 – Auto-Remediator** consumes AWS Amplify build-status events from EventBridge and posts status-specific Telegram messages. **Module 2 – Git Radar** receives GitHub webhooks via API Gateway and uses a Copilot-style agentic loop to review PRs, diagnose failed workflows, and summarise pushes, keeping dashboard state in DynamoDB. **Module 3 – FinOps Sentinel** sends a daily cost digest at 09:00 SGT, a weekly Monday deep dive, and cost/Terraform-failure webhooks that can open optimisation or fix PRs. **Module 4 – PR Guardian** runs in GitHub Actions, scans PR diffs with OpenAI GPT-4, and reports risk back to Module 2. Infrastructure is Terraform (S3 backend + DynamoDB locking), with a cross-region EventBridge forwarder because the Amplify app lives in `us-east-2` while the Lambdas run in `us-east-1`.

## Architecture

```
 ┌────────────────────┐    ┌────────────────────┐    ┌──────────────────────┐
 │ AWS Amplify builds │    │ GitHub webhooks    │    │ Cost Explorer / cost │
 │ (us-east-2)        │    │ push · PR · run    │    │ + TF-failure alerts  │
 └─────────┬──────────┘    └─────────┬──────────┘    └──────────┬───────────┘
           │ EventBridge rule         │                          │
           │ (forward, us-east-2)     │                          │
           ▼                          ▼                          ▼
 ┌────────────────────┐    ┌──────────────────────────────────────────────┐
 │ EventBridge default│    │ API Gateway HTTP API  <project>-chatops-api   │
 │ bus (us-east-1)    │    │ POST /webhook/github · POST /webhook/finops   │
 │ amplify_build_status│   └─────────┬──────────────────────────┬─────────┘
 └─────────┬──────────┘              │                          │
           ▼                          ▼                          ▼
 ┌────────────────────┐    ┌────────────────────┐    ┌──────────────────────┐
 │ Lambda  Module 1   │    │ Lambda  Module 2   │    │ Lambda  Module 3     │
 │ Auto-Remediator    │    │ Git Radar          │    │ FinOps Sentinel      │
 │ Python 3.11        │    │ + agentic loop     │    │ + agentic loop       │
 └─────────┬──────────┘    └──┬──────────┬──────┘    └──────┬────────▲──────┘
           │                  │          ▼                  │        │
           │                  │  ┌───────────────┐          │   EventBridge
           │                  │  │ DynamoDB      │          │   cron daily 01:00 UTC
           │                  │  │ *_radar_state │          │   cron MON   01:00 UTC
           │                  │  └───────────────┘          │
           │                  ▲ agent_scan webhook          │
           │        ┌─────────┴──────────┐                  │
           │        │ Module 4 PR Guardian│  (GitHub Actions, OpenAI GPT-4)
           │        └────────────────────┘                  │
           ▼                  ▼                              ▼
 ┌──────────────────────────────────────────────────────────────────────────┐
 │ Telegram group (forum topics)  ·  GitHub PR comments / issues / fix PRs    │
 └──────────────────────────────────────────────────────────────────────────┘
   CloudWatch Logs (14-day retention) on every Lambda and the API stage
```

## Technology Stack

| Layer | Technology | Purpose |
|---|---|---|
| **Compute** | AWS Lambda (Python 3.11; approval handler on 3.12) | 1024 MB / 300 s functions for Modules 1–3 plus a Telegram approval handler |
| **API ingress** | Amazon API Gateway HTTP API (`$default` stage) | `POST /webhook/github` → Git Radar, `POST /webhook/finops` → FinOps Sentinel |
| **Event routing** | Amazon EventBridge | Amplify build-status pattern, cross-region forwarder (`us-east-2` → `us-east-1`), daily/weekly cron schedules |
| **State** | Amazon DynamoDB (on-demand, PITR) | `*_radar_state` table tracking the Telegram dashboard message ID |
| **Cost data** | AWS Cost Explorer API | Yesterday / month-to-date spend and top-service ranking for digests |
| **Secrets** | AWS Secrets Manager (3 entries under `/cortex-infra/`) | Telegram bot token, bot secret token, GitHub App token for the approval handler |
| **AI** | GitHub Copilot Chat Completions (`gpt-4o`) via GitHub App JWT; OpenAI GPT-4 | Agentic tool-calling loops (15 tool schemas) and PR security scanning |
| **Notifications** | Telegram Bot API | Markdown messages routed to per-module forum topics, with plain-text fallback |
| **CI/CD** | GitHub Actions (10 workflow files) | Backend/frontend CI, CORTEX Guardian PR scanner, infra and "smart" pipelines |
| **IaC** | Terraform `>= 1.5.0`, AWS provider `~> 5.0` | S3 remote state + DynamoDB lock table `cortex-terraform-locks`; `default_tags` incl. `System = CORTEX-ChatOps` |
| **Tooling** | PowerShell, Python, Bash, Make | `Build-LambdaPackages.ps1`, `Test-AllPipelines.ps1`, `monitor_logs.py`, `Makefile` targets |

## Key Achievements

- **Four-module event-driven ChatOps platform**: Amplify, GitHub, and cost events each land on their own Lambda and fan out to Telegram and GitHub, with 56+ functions/methods across 10 Python files.
- **Agentic remediation loops**: a shared `CopilotAgent` library (GitHub App RS256 JWT → installation token → chat completions) drives tool-calling loops. Git Radar has 7 tools and up to 6 iterations; FinOps Sentinel has 8 tools and up to 8 iterations. The agents can read files, fetch diffs and workflow logs, re-run workflows, open issues, and open timestamped fix or cost-optimisation PRs.
- **Automated FinOps reporting in production**: a daily digest at 09:00 SGT (`cron(0 1 * * ? *)`) and a Monday deep dive (`cron(0 1 ? * MON *)`) give the infra team yesterday's spend, MTD totals, and the top four services by cost.
- **Cross-region event bridging**: Amplify emits build events in `us-east-2`, so an EventBridge rule there forwards them (with a dedicated IAM role) to the `us-east-1` default bus, where the Auto-Remediator rule fires. This is implemented with an aliased `amplify_region` provider.
- **Caught a real cost spike**: the June 8–9 data showed EC2 +237%, S3 +3566%, and new RDS/ELB/VPC charges. The project documents this as surfaced and investigated through the FinOps pipeline.
- **Merge-aware CI path detection**: fixed workflows that skipped CI on merge commits by moving to `fetch-depth: 0` and `dorny/paths-filter@v3` with full frontend and backend glob coverage.
- **Automated test harness**: `Test-AllPipelines.ps1` covers prerequisites, infrastructure, all three Lambda modules, CloudWatch logs, and DynamoDB, driven by 6 realistic JSON test payloads.
- **Repository reorganisation**: the root directory went from 45+ files to a handful, with docs grouped under `docs/` (architecture, setup, integration, implementation, deployment, testing) and all Terraform, scripts, and monitoring under `infrastructure/`.

## Infrastructure Components

Counts below combine the live audit (2026-06-09) and the Terraform in `infrastructure/terraform/` (42 authored resource blocks across 6 `.tf` resource files).

| Component | Count | Details |
|---|---|---|
| **Lambda functions (live)** | 5 | `cortex_finops_sentinel`, `cortex_auto_remediator`, `cortex_git_radar`, `cortex_copilot_guardian` (Python 3.11), `cortex-telegram-approval-handler` (Python 3.12); all 1024 MB / 300 s |
| **Lambda functions (Terraform)** | 3 | `${project}_auto_remediator`, `${project}_git_radar`, `${project}_finops_sentinel` + 5 `aws_lambda_permission` |
| **API Gateway** | 7 blocks | HTTP API `${project}-chatops-api`, `$default` stage, access log group, 2 integrations, 2 routes |
| **EventBridge** | 11 blocks | Cross-region role + policy, forward rule/target (`us-east-2`), Amplify rule/target + permission, daily and weekly FinOps rules/targets |
| **DynamoDB** | 2 | `cortex_radar_state` (on-demand, PITR on); `cortex-terraform-locks` (state locking) |
| **IAM** | 9 blocks | 3 Lambda execution roles, each with a logs attachment and a scoped inline policy (Amplify / DynamoDB / Cost Explorer) |
| **Secrets Manager** | 3 | `/cortex-infra/telegram-bot-token`, `/cortex-infra/telegram-bot-secret-token`, `/cortex-infra/github-app-token` (values set out of band) |
| **CloudWatch Log Groups** | 4 + API | `/aws/lambda/cortex_*` at 14-day retention; API Gateway access logs at 14 days |
| **Remote state** | 1 bucket + 1 table | S3 `dnd-terraform-state-staging-022499047467` (key `cortex/terraform.tfstate`, encrypted) + DynamoDB lock table |
| **GitHub Actions workflows** | 10 | `backend-ci`, `frontend-ci`, `full-ci`, `cortex-guardian` (×2), `cortex-infra-pipeline`, `cortex-smart-pipeline`, `dnd-deploy`, `dnd-platform-ci`, `dnd-pr-review` |
| **Audit completeness** | 21 / 27 | Deployed vs expected resources at audit time (77.8%); missing items were 3 EventBridge rules and 3 permissions |

## Deployment Issues Diagnosed & Resolved

| Issue | Root cause | Fix |
|---|---|---|
| API Gateway returned 500; `Runtime.ImportModuleError: No module named 'jwt'` | Module 2/3 Lambda zips were deployed without `PyJWT` and `cryptography` | Wrote `Build-LambdaPackages.ps1` to vendor dependencies per module (Module 1 package built at 18.06 MB). Modules 2 and 3 were recorded as pending rebuild at the time of the test report |
| CI skipped on merge/push even when relevant files changed | `fetch-depth: 2` plus `git diff HEAD~1 HEAD` only sees the first parent of a merge commit, and the path globs were incomplete | `fetch-depth: 0`, replaced the bash diff with merge-aware `dorny/paths-filter@v3`, expanded globs (`app/**`, `public/**`, `infrastructure/**`, `src/module*/**`), added a step-summary debug and a manual-trigger override |
| `terraform show` / `output` failed with a state checksum mismatch | The S3 state object was updated but the DynamoDB lock table's `Digest` wasn't synced | Updated the `Digest` item in `cortex-terraform-locks` to match the S3 checksum. Resolved |
| EventBridge schedule rules not found (`list-rules --name-prefix cortex` returned `[]`) | Rules defined in `eventbridge.tf` were never created because of the state corruption above | Remediation documented as targeted applies of the 3 rules, 3 targets, and the Lambda permission. The README's 2026-06-10 live verification lists the daily and weekly FinOps rules as `ENABLED` |
| Copilot API `400: Personal Access Tokens are not supported` | The Copilot chat completions endpoint needs an OAuth token with `copilot` scope or a GitHub App token, not a PAT | Added explicit PAT-error detection and messaging in all three `copilot_agent.py` copies, moved auth to GitHub App JWT → installation token, and documented an OpenAI fallback |
| Telegram Markdown messages rejected (HTTP 400 "can't parse") | Dynamic content (commit messages, branch names) broke Telegram Markdown parsing | On a 400 parse error, the send helpers retry the same payload as plain text |
| Amplify events not matching | Amplify emits `SUCCEED`, not `SUCCEEDED`, and publishes in the app's region (`us-east-2`) | Event pattern uses `["SUCCEED","FAILED","STARTED"]`; added a cross-region forwarder rule + IAM role to the `us-east-1` bus |
| GitHub App private key in the Lambda env var failed to parse | RSA key stored with escaped/literal newline characters | Diagnosed with `fix_key_format.py` and re-set the env var with proper newlines; `fix_lambda_creds.py` / `revert_lambda.py` synced credentials and code between function generations |

## Test Results

From `TEST_SUMMARY.md` (2026-02-10, `Test-AllPipelines.ps1`, direct Lambda invocation against the `cloud-tibot_*` generation of the functions):

| Module | Test | Result |
|---|---|---|
| Module 1 – Auto-Remediator | Amplify build-failure detection | PASS |
| Module 2 – Git Radar | GitHub push event handling | PASS |
| Module 2 – Git Radar | Pull request analysis | PASS |
| Module 2 – Git Radar | GitHub Actions failure detection | PASS |
| Module 2 – Git Radar | API Gateway integration | SKIP (500, missing `PyJWT`) |
| Module 3 – FinOps Sentinel | Cost anomaly detection | PASS |
| Module 3 – FinOps Sentinel | Terraform failure remediation | PASS |
| Infrastructure | CloudWatch log groups active with streams; DynamoDB table `ACTIVE` with 1 item | PASS |
| **Total (module tests)** | | **6 / 6 PASS** (API Gateway path skipped) |

> Test suite runtime ~45 s; cold start < 1 s, warm execution < 500 ms, no timeouts. Direct invocations passed, but the end-to-end webhook path through API Gateway was not verified in this run.

## Quick Start

```bash
# 1. Prepare variables (Telegram token + chat ID; GitHub App values for modules 2 & 3)
cd Cloud-Tibot/infrastructure
cp terraform.tfvars.example terraform.tfvars.dev

# 2. Build Lambda packages with vendored dependencies (PyJWT, cryptography)
pwsh ./scripts/Build-LambdaPackages.ps1 -CleanBuild

# 3. Initialise against the S3 backend, validate, plan, apply
cd terraform
terraform init
terraform validate
terraform plan  -var-file=../terraform.tfvars.dev -out=plan.dev
terraform apply plan.dev

# 4. Verify the scheduled rules exist and exercise the pipelines
aws events list-rules --name-prefix cortex --region us-east-1
aws lambda invoke --function-name cortex_finops_sentinel \
  --payload '{"report_type": "daily"}' response.json && cat response.json
pwsh ../scripts/Test-AllPipelines.ps1
```

> Apply takes ~1–2 minutes. Point the GitHub repository webhook at `<api-endpoint>/webhook/github` (events: `push`, `pull_request`, `workflow_run`).

## Cost Estimate

Project-level estimate from the README (serverless, pay-per-use):

| Resource | Quantity | Monthly (USD) |
|---|---|---|
| AWS Lambda | Low invocation volume | ~$0.50 |
| DynamoDB (on-demand) | < 1 GB | ~$0.30 |
| CloudWatch Logs | 14-day retention | ~$0.50 |
| EventBridge | Scheduled + AWS service events | Free |
| **Total** | | **~$1.30 / month** |

> The README also records whole-account spend observed through the FinOps pipeline (June 1–10, 2026: ~$1.20/day average, ~$36/month projected). That figure is the account being monitored, not this project's footprint. Secrets Manager entries and API Gateway requests aren't itemised in the source estimate.

## Security Posture

| Topic | Posture |
|---|---|
| Lambda secrets | Telegram token, chat ID, and GitHub App credentials passed as Lambda environment variables; the audit rates this HIGH risk |
| Secrets Manager | 3 `/cortex-infra/*` secrets created by Terraform with values populated out of band (approval-handler path); migrating the main Lambdas is Priority 2 in the audit |
| IAM | Per-function execution roles with scoped inline policies (Amplify read, DynamoDB table, Cost Explorer); the audit still flags some roles as broad |
| Webhook auth | GitHub App JWT (RS256) exchanged for short-lived (10 min) installation tokens; no PAT for Copilot calls |
| DynamoDB | Encrypted at rest (AWS-managed); point-in-time recovery enabled on the radar state table |
| Logging | CloudWatch Logs at 14-day retention on all Lambdas and the API Gateway stage |
| Remote state | S3 backend with `encrypt = true` + DynamoDB locking (audit recommends moving to `use_lockfile`) |
| PR gating | PR Guardian exits non-zero on CRITICAL findings, so it can block merges |
| Repo hygiene | `.gitignore` excludes `*.tfstate`, `*.tfvars`, `*.tfplan`, zips, and build output; Terraform plans called out as sensitive |

## Project Structure

Summarised top-level tree (the repository holds ~2,600 files; ~2,465 of them are vendored Python dependencies under `infrastructure/lambda_src/telegram_approval_handler/`).

```
Cloud-Tibot/
├── README.md                     # FinOps Sentinel overview, live config, runbook
├── AUDIT_RESULT.md               # Live AWS audit (2026-06-09)
├── TEST_SUMMARY.md / TESTING_GUIDE.md
├── CICD_PATH_DETECTION_FIX.md    # Merge-aware CI path detection fix
├── LAMBDA_FUNCTIONS_SUMMARY.md   # Function-by-function reference (56+ functions)
├── MODULE1_UPGRADE_SUMMARY.md    # Auto-Remediator rich status messages
├── ACTION_PLAN.md · MONITOR_SETUP.md · TERRAFORM_DEPLOYMENT_GUIDE.md
├── REORGANIZATION_SUMMARY.md · GITIGNORE_CLEANUP_SUMMARY.md · DOCUMENTATION_REVIEW.md
├── Makefile                      # init / validate / plan / apply / destroy targets
├── Build-LambdaPackages.ps1 · Test-AllPipelines.ps1 · setup-github-actions.ps1
├── monitor_logs.py · parse_logs.py · build_linux_package.py · deploy_lambda.py
├── fix_key_format.py · fix_lambda_creds.py · revert_lambda.py · test_lambda_fix.py
├── .github/workflows/            # 10 workflows (CI, Guardian, infra/smart pipelines, DND)
├── src/
│   ├── module1/                  # Auto-Remediator (lambda_function.py, copilot_agent.py)
│   ├── module2/                  # Git Radar
│   ├── module3/                  # FinOps Sentinel
│   └── module4_agent/            # PR Guardian (pr_guardian.py, GitHub Actions)
├── infrastructure/
│   ├── terraform/                # api_gateway, dynamodb, eventbridge, iam, lambda,
│   │                             #   secrets, backend, provider, variables, outputs
│   ├── lambda_src/               # telegram_approval_handler (vendored deps)
│   ├── scripts/                  # build, test, validate, migration, cleanup, diagnostics
│   ├── monitoring/               # monitor_logs.py
│   └── terraform.tfvars.example  # (+ dev / staging variants)
├── scripts/                      # Telegram bot, cost reports, webhook/Lambda test utilities
└── docs/                         # architecture/ setup/ integration/ implementation/
                                  #   deployment/ testing/ + INDEX.md
```

## Key Learnings & Technical Decisions

**Remote state is only as healthy as its lock table.** A mismatch between the S3 state checksum and the DynamoDB `Digest` blocked `terraform show` and `output`. It also meant resources defined in code, such as the EventBridge schedules, were never created, so the platform silently lost its automation. Checking a live `list-rules` against the code, rather than trusting `apply` history, is what exposed the gap.

**EventBridge is regional, and event-driven designs need to follow the source.** Amplify emits build events only in the app's own region. Instead of relocating the Lambdas, a forwarder rule in `us-east-2` puts events onto the `us-east-1` default bus through a dedicated IAM role, implemented with a second aliased Terraform provider.

**Package the runtime, not just the handler.** Direct invocations passed while real webhooks failed, because the zipped handlers lacked `PyJWT` and `cryptography`. Testing only by direct invocation hid a production path failure. A reproducible build script and an API-level test are needed together.

**Agent loops need bounded iterations and narrow tools.** Each agent gets an explicit tool schema (7 for Git Radar, 8 for FinOps Sentinel), a task-specific system prompt, and a hard iteration cap. Actions are limited to reviewable artefacts: comments, issues, and PRs on timestamped `cortex/*` branches, never direct commits to `main`.

**Change detection in CI must be merge-aware.** `HEAD~1` on a merge commit sees only the first parent. Full history plus a purpose-built paths filter fixed the silent CI skips.

## What I'd Do Differently

- **Keep secrets out of Lambda env vars and docs from the start.** Move every token and key into Secrets Manager, fetch them at runtime, and scrub and rotate any credential that has appeared in committed files.
- **Codify every live resource in Terraform.** The audit found Lambdas (`cortex_copilot_guardian`, the approval handler) and naming generations (`cloud-tibot_*` vs `cortex_*`) that diverge from `lambda.tf`. A single source of truth would have prevented the credential-copy and revert scripts.
- **Add CloudWatch alarms and the `finops-cost-history` table.** Both are flagged as missing in the README and audit. Lambda error, API 5xx, and cost-threshold alarms should ship with the stack.
- **Test through API Gateway, not only direct invocation**, so dependency and routing failures surface before real webhooks hit them.
- **Consolidate the duplicate workflows** (`cortex-guardian.yml` / `cortex_guardian.yml`) and resolve the unmerged conflict markers left in `README.md`.
- **Migrate the backend to S3-native locking** (`use_lockfile`) as the audit recommends, removing the DynamoDB digest failure mode.

## Summary

Cloud-Tibot (Project CORTEX) is a serverless ChatOps and FinOps platform: four modules turn Amplify builds, GitHub activity, and AWS cost data into Telegram notifications and AI-assisted remediation through Lambda, API Gateway, EventBridge (including a cross-region forwarder), DynamoDB, and bounded agentic tool-calling loops, provisioned with Terraform on an S3 + DynamoDB backend. It runs in `us-east-1`, where the 2026-06-09 audit confirmed **5/5 Lambda functions active** and **21 of 27 expected resources deployed**. The module test suite passed **6/6** direct-invocation tests, and daily and weekly FinOps digests are documented as active. Eight real issues were diagnosed and fixed, including missing Lambda dependencies, merge-blind CI path detection, a state checksum mismatch, and Copilot PAT rejection. Secrets management and alarm coverage are the main open hardening items.
