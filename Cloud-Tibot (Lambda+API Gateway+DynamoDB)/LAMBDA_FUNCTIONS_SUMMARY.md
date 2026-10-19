# Cloud-Tibot — Complete Function Reference

> **Generated:** February 17, 2026 | **Project:** Cloud-Tibot (Project CORTEX) | **Version:** 2.0

---

## One-Paragraph Description

**Cloud-Tibot (Project CORTEX)** is a serverless ChatOps system on AWS consisting of **4 modules (10 Python files, 56+ functions/methods)** that work together as an intelligent DevOps automation pipeline. **Module 1 (Auto-Remediator)** listens to EventBridge for Amplify build status changes and sends real-time Telegram notifications; **Module 2 (Git Radar)** receives GitHub webhooks via API Gateway and uses a Copilot AI agent to auto-review PRs, diagnose failed CI/CD workflows, generate intelligent commit summaries, and maintain a stateful Telegram dashboard with DynamoDB; **Module 3 (FinOps Sentinel)** processes cost alerts and Terraform deployment failures via webhooks, using an AI agent to analyze cost anomalies, generate Terraform optimization PRs, and auto-fix broken infrastructure; **Module 4 (PR Guardian)** runs inside GitHub Actions on every pull request, using OpenAI to scan code diffs for security vulnerabilities, bugs, and performance issues, then reports findings back to Module 2 via webhook. All modules share a common **Copilot Agent** library that provides GitHub App JWT authentication, GitHub Copilot chat completions, an agentic tool-calling loop, and a full GitHub REST API helper class. A standalone **Telegram Bot** utility in `scripts/` provides rich notification formatting with interactive buttons for CI/CD events.

---

## Module-by-Module Function Listing

---

## 📦 MODULE 1 — Auto-Remediator (Amplify Build Notifier)

**Source:** `src/module1/` | **Trigger:** EventBridge (Amplify build status) | **Runtime:** Python 3.11  
**Dependencies:** `urllib3`, `boto3` (Lambda built-in)

### `src/module1/lambda_function.py` (2 functions)

| # | Function | Description |
|---|----------|-------------|
| 1 | `lambda_handler(event, context)` | **Main entry point.** Receives EventBridge Amplify build status change events (STARTED, SUCCEED, FAILED, CANCELLING, CANCELLED) for **all** Amplify apps in the account. Extracts `appId`, `branchName`, `jobId`, `jobStatus`, `commitId` from the event detail. Calls Amplify API via boto3 to resolve the human-readable app name. Builds a formatted Telegram message with status emojis, build metadata, and a direct AWS Console link, then calls `send_telegram_message()`. Returns HTTP 200 with a JSON summary. |
| 2 | `send_telegram_message(token, chat_id, message)` | Sends a Markdown-formatted message to the Telegram Bot API using `urllib3`. Truncates messages to the Telegram 4096-character limit. Logs success/failure to CloudWatch. |

### `src/module1/copilot_agent.py` — *See Shared Copilot Agent (below)*

---

## 📦 MODULE 2 — Git Radar (GitHub Event Intelligence Agent)

**Source:** `src/module2/` | **Trigger:** API Gateway HTTP API (`/webhook/github`) | **Runtime:** Python 3.11  
**Dependencies:** `urllib3`, `boto3`, `PyJWT`, `cryptography`

### `src/module2/lambda_function.py` (14 functions)

| # | Function | Type | Description |
|---|----------|------|-------------|
| 1 | `lambda_handler(event, context)` | Handler | **Main entry point.** Parses API Gateway event, performs case-insensitive header lookup for `x-github-event`, parses the JSON body, and routes to the correct handler: `agent_scan` → `handle_agent_scan_event()`, `ping` → returns pong, `pull_request` → `handle_pull_request()`, `workflow_run` → `handle_workflow_run()`, `push` → `handle_push_event()`. After processing, sends a dashboard-style Telegram message via `update_telegram_dashboard()`. |
| 2 | `handle_agent_scan_event(body)` | Handler | Processes custom `agent_scan` events sent by Module 4 (PR Guardian). Extracts PR number, risk level, status, and summary. Formats a Telegram notification with Guardian analysis results and optionally logs the event to DynamoDB. |
| 3 | `handle_pull_request(payload, github, ...)` | Handler | **AI-powered PR review.** Initializes a `CopilotAgent` with a code-review system prompt targeting security vulnerabilities, bugs, Terraform drift, and best practices. Runs an agentic loop (up to 6 iterations) that can fetch diffs, read files, and post review comments on the PR. |
| 4 | `handle_workflow_run(payload, github, ...)` | Handler | **AI-powered CI/CD failure diagnosis.** Triggers on `conclusion: failure` only. Initializes a `CopilotAgent` with a CI diagnostics system prompt. Runs an agentic loop that fetches workflow logs, identifies failed steps, and either reruns the workflow (for transient errors) or creates a GitHub issue with diagnosis. |
| 5 | `handle_push_event(payload, github, ...)` | Handler | **Intelligent commit summary.** Extracts branch, pusher, and up to 5 commit details (SHA, message, added/modified/removed counts). Optionally calls the Copilot agent for a 1–2 sentence AI summary highlighting infrastructure or security changes. Falls back gracefully to a plain commit list if AI is unavailable. |
| 6 | `_get_file_content(github, owner, repo, args)` | Tool Impl | Reads a file from the GitHub repo via API, base64-decodes the content, and returns up to 10,000 characters. |
| 7 | `_get_pr_diff(github, owner, repo, args)` | Tool Impl | Fetches changed files for a PR via GitHub API. Returns up to 15 files with filename, status, additions/deletions, and the first 2,000 characters of each patch in diff format. |
| 8 | `_post_pr_review_comment(github, owner, repo, args)` | Tool Impl | Posts a Markdown review comment on a PR via the GitHub Issues Comments API. |
| 9 | `_get_failed_workflows(github, owner, repo)` | Tool Impl | Lists the 5 most recent failed GitHub Actions workflow runs with run ID, name, and conclusion. |
| 10 | `_get_workflow_job_logs(github, owner, repo, args)` | Tool Impl | Fetches all jobs and steps for a specific workflow run ID, showing ✅/❌ status for each step. |
| 11 | `_create_remediation_issue(github, owner, repo, args)` | Tool Impl | Creates a GitHub issue with title, body, and labels (`bug`, `ci-failure`, `auto-detected`). |
| 12 | `_rerun_workflow(github, owner, repo, args)` | Tool Impl | Re-triggers a failed GitHub Actions workflow run by run ID. |
| 13 | `update_telegram_dashboard(token, chat_id, message)` | Telegram | Sends a Telegram message and tracks the message ID in DynamoDB (key: `telegram_dashboard`) for future dashboard updates. |
| 14 | `send_telegram_message(token, chat_id, message)` | Telegram | Sends a Markdown message to Telegram. On Markdown parse failure (HTTP 400), automatically retries as plain text. Returns the Telegram `message_id` for state tracking. |

### 7 Copilot Agent Tool Definitions (JSON Schema)

| Tool Name | Description |
|-----------|-------------|
| `get_file_content` | Read a file from the GitHub repository |
| `get_pr_diff` | Get the diff/changed files for a pull request |
| `post_pr_review_comment` | Post a review comment on a PR |
| `get_failed_workflows` | List recent failed workflow runs |
| `get_workflow_job_logs` | Get job details and failed steps for a workflow run |
| `create_remediation_issue` | Create a GitHub issue with analysis and fix recommendations |
| `rerun_workflow` | Re-trigger a failed workflow run |

---

## 📦 MODULE 3 — FinOps Sentinel (Cost Optimization & Terraform Fix Agent)

**Source:** `src/module3/` | **Trigger:** API Gateway HTTP API (`/webhook/finops`) | **Runtime:** Python 3.11  
**Dependencies:** `urllib3`, `boto3`, `PyJWT`, `cryptography`

### `src/module3/lambda_function.py` (12 functions)

| # | Function | Type | Description |
|---|----------|------|-------------|
| 1 | `lambda_handler(event, context)` | Handler | **Main entry point.** Parses webhook body, initializes GitHub API with an installation token, determines `alert_type` (`terraform_failure` or `cost_alert`), routes to the appropriate handler, then sends a Telegram notification with the AI analysis result. |
| 2 | `handle_cost_alert(body, github, ...)` | Handler | **AI-powered cost analysis.** Extracts service, cost_amount, period, threshold, and resource_details. Calculates severity (CRITICAL/WARNING/INFO). Initializes a `CopilotAgent` with a cost optimization system prompt. Runs an agentic loop (up to 8 iterations) that lists repo files, reads Terraform configs, identifies right-sizing/cleanup opportunities, and creates a PR with estimated savings. |
| 3 | `handle_terraform_failure(body, github, ...)` | Handler | **AI-powered Terraform auto-fix.** Extracts run_id, error_message, and workspace. Initializes a `CopilotAgent` with a Terraform remediation prompt covering resource conflicts, quota issues, syntax errors, state drift, and provider incompatibilities. Runs an agentic loop (up to 8 iterations) to diagnose and fix the failure, creating a fix PR, rerunning the workflow, or creating an issue. |
| 4 | `_get_terraform_file(github, owner, repo, args)` | Tool Impl | Reads a `.tf` file from the repo, base64-decodes, returns up to 15,000 characters. |
| 5 | `_list_repo_files(github, owner, repo, args)` | Tool Impl | Lists files/directories in a repo path with 📁/📄 icons and file sizes. |
| 6 | `_create_optimization_pr(github, owner, repo, args)` | Tool Impl | Creates a timestamped branch (`cortex/cost-optimize-YYYYMMDD-HHMMSS`), commits updated Terraform content, and opens a PR with optimization summary and estimated monthly savings. |
| 7 | `_create_fix_pr(github, owner, repo, args)` | Tool Impl | Creates a timestamped branch (`cortex/tf-fix-YYYYMMDD-HHMMSS`), commits corrected Terraform content, and opens a fix PR with a diagnosis description. |
| 8 | `_get_failed_terraform_runs(github, owner, repo)` | Tool Impl | Lists the 5 most recent failed workflow runs. |
| 9 | `_get_workflow_logs(github, owner, repo, args)` | Tool Impl | Fetches job/step details for a workflow run ID with ✅/❌ markers. |
| 10 | `_create_issue(github, owner, repo, args)` | Tool Impl | Creates a GitHub issue with labels (`finops`, `infrastructure`, `auto-detected`). |
| 11 | `_rerun_terraform_workflow(github, owner, repo, args)` | Tool Impl | Re-triggers a failed Terraform workflow run. |
| 12 | `send_telegram_message(token, chat_id, message)` | Telegram | Sends Markdown-formatted message to Telegram via `urllib3`. |

### 8 Copilot Agent Tool Definitions (JSON Schema)

| Tool Name | Description |
|-----------|-------------|
| `get_terraform_file` | Read a Terraform `.tf` file from the repo |
| `list_repo_files` | List files in a directory to discover Terraform configs |
| `create_optimization_pr` | Create a PR with cost optimization Terraform changes |
| `get_failed_terraform_runs` | Check for failed Terraform workflow runs |
| `get_workflow_logs` | Get detailed job logs for a specific workflow run |
| `create_fix_pr` | Create a PR to fix a failed Terraform deployment |
| `create_issue` | Create a GitHub issue for manual review |
| `rerun_terraform_workflow` | Re-trigger a failed Terraform workflow |

---

## 📦 MODULE 4 — PR Guardian (GitHub Actions Security Scanner)

**Source:** `src/module4_agent/` | **Runs in:** GitHub Actions (not Lambda) | **Runtime:** Python 3.11  
**Dependencies:** `requests`, `PyGithub`, `openai`

### `src/module4_agent/pr_guardian.py` (7 functions/methods + main)

| # | Function | Type | Description |
|---|----------|------|-------------|
| 1 | `CortexGuardian.__init__(github_token, openai_api_key, webhook_url)` | Constructor | Initializes the Guardian with PyGithub client, OpenAI client, and the Module 2 webhook URL. |
| 2 | `CortexGuardian.get_pr_diff(repo_name, pr_number)` | Method | Fetches the complete PR diff via PyGithub: title, branch info, additions/deletions, and the full patch for each changed file. |
| 3 | `CortexGuardian.analyze_with_llm(pr_diff)` | Method | Sends the diff (truncated to 8,000 chars) to OpenAI GPT-4 with a security-focused system prompt. Parses the response to determine risk level (🔴 CRITICAL / 🟡 MEDIUM / 🟢 LOW / ✅ CLEAN). Returns analysis text, model name, and token usage. |
| 4 | `CortexGuardian.post_pr_comment(repo_name, pr_number, analysis)` | Method | Posts the formatted analysis as a PR comment via PyGithub with a CORTEX-Guardian header. |
| 5 | `CortexGuardian.send_to_cortex_radar(pr_number, risk_level, summary, repo_name)` | Method | Sends a JSON webhook (`event: agent_scan`) to Module 2's API Gateway endpoint with PR number, status, risk level, summary, and timestamp. Module 2 then forwards this to Telegram. |
| 6 | `CortexGuardian._get_timestamp()` | Static | Returns current UTC timestamp in ISO format. |
| 7 | `main()` | Entry | **GitHub Actions entry point.** Loads env vars (`GITHUB_TOKEN`, `OPENAI_API_KEY`, `CORTEX_RADAR_WEBHOOK`, `GITHUB_REPOSITORY`, `GITHUB_EVENT_PATH`), reads the PR event JSON, then orchestrates: fetch diff → analyze with LLM → post PR comment → send to CORTEX Radar. Exits with code 1 if critical issues are found (can block merge). |

---

## 🔧 SHARED — Copilot Agent Library (used by Modules 1, 2, 3)

**Source:** `src/module{1,2,3}/copilot_agent.py` (identical in all three) | **Dependencies:** `urllib3`, `PyJWT`

### Top-Level Functions (2)

| # | Function | Description |
|---|----------|-------------|
| 1 | `get_installation_token(app_id, installation_id, private_key)` | Generates a GitHub App JWT signed with RS256, exchanges it for an installation access token via `POST /app/installations/{id}/access_tokens`. Token expires in 10 minutes. |

### Class: `CopilotAgent` (6 methods)

| # | Method | Description |
|---|--------|-------------|
| 2 | `__init__(app_id, installation_id, private_key)` | Initializes the agent with GitHub App credentials, HTTP pool, empty conversation history, and empty system prompt. |
| 3 | `set_system_prompt(prompt)` | Sets the system prompt that guides the agent's behavior for a specific task. |
| 4 | `chat(user_message, tools=None)` | Generates a fresh installation token, appends the user message to conversation history, calls the GitHub Copilot Chat Completions API (`https://api.githubcopilot.com/chat/completions`) with model `gpt-4o`, temperature 0.1, max 4096 tokens. Handles 401 (auth error) and 403 (permission error) with helpful messages. |
| 5 | `add_tool_result(tool_call_id, result)` | Appends a `role: tool` message to conversation history so the agent can process tool execution results. |
| 6 | `run_agent_loop(user_message, tools, tool_executor, max_iterations=5)` | **Core agentic loop.** Sends initial message, checks for tool calls in the response, executes them via the provided `tool_executor` callable, feeds results back, and repeats until the model returns a final text response or hits `max_iterations`. |
| 7 | `reset()` | Clears conversation history for a new task. |

### Class: `GitHubAPI` (11 methods)

| # | Method | Description |
|---|--------|-------------|
| 8 | `__init__(pat)` | Initializes with a GitHub personal/installation access token and `urllib3` HTTP pool. |
| 9 | `_request(method, path, body=None)` | Core HTTP request method to GitHub REST API with proper headers (`Accept`, `Authorization`, `X-GitHub-Api-Version`, `User-Agent`). |
| 10 | `get_repo_content(owner, repo, path, ref="main")` | Reads file/directory content from a repository. |
| 11 | `create_branch(owner, repo, branch_name, from_sha)` | Creates a new git branch from a specific SHA. |
| 12 | `get_default_branch_sha(owner, repo)` | Gets the latest SHA of `main` (falls back to `master`). |
| 13 | `update_file(owner, repo, path, content_b64, message, branch, sha=None)` | Creates or updates a file in the repo via the Contents API. |
| 14 | `create_pull_request(owner, repo, title, body, head, base="main")` | Opens a new pull request. |
| 15 | `add_pr_comment(owner, repo, pr_number, comment)` | Posts a comment on a PR/issue. |
| 16 | `get_workflow_runs(owner, repo, status="failure")` | Lists recent workflow runs filtered by status. |
| 17 | `get_workflow_run_logs(owner, repo, run_id)` | Gets job details for a specific workflow run. |
| 18 | `rerun_workflow(owner, repo, run_id)` | Re-triggers a workflow run. |
| 19 | `create_issue(owner, repo, title, body, labels=None)` | Creates a new GitHub issue. |

---

## 🤖 UTILITY — Telegram Bot (Standalone Script)

**Source:** `scripts/telegram_bot.py` | **Runs:** Locally or in CI/CD | **Dependencies:** `requests`

### Class: `TelegramBot` (2 methods)

| # | Method | Description |
|---|--------|-------------|
| 1 | `send_message(text, parse_mode="Markdown", disable_preview=True)` | Sends a text message to Telegram using the `requests` library with a 10-second timeout. |
| 2 | `send_buttons(text, buttons)` | Sends a message with inline keyboard buttons (interactive UI elements). |

### Class: `DndPlatformNotifier` (partial listing from visible code)

| # | Method | Description |
|---|--------|-------------|
| 3 | `notify_pr_opened(pr_data)` | Formats and sends a rich Telegram notification when a new PR is opened, including title, author, change stats, and interactive buttons (View PR, Approve, Comment). |

---

## 📊 Complete Statistics

| Metric | Count |
|--------|-------|
| **Total Modules** | 4 |
| **Python Files** | 10 |
| **Lambda Functions (AWS)** | 3 |
| **GitHub Actions Scripts** | 1 |
| **Utility Scripts** | 1 |
| **Total Functions/Methods** | **56+** |
| **AI Agent Tool Schemas** | 15 (7 in Module 2, 8 in Module 3) |
| **Copilot Agent Shared Methods** | 19 (1 top-level + 6 CopilotAgent + 11 GitHubAPI + 1 duplicate) |

---

## 🏗️ Architecture Flow

```
┌──────────────────────────────────────────────────────────────────────┐
│                        AWS AMPLIFY (All Apps)                        │
└─────────────────────────────┬────────────────────────────────────────┘
                              │ EventBridge: STARTED/SUCCEED/FAILED
                              ▼
                    ┌──────────────────┐
                    │ MODULE 1: Auto   │──────────► 📱 Telegram
                    │ Remediator       │           (Build Notifications)
                    │ (2 functions)    │
                    └──────────────────┘

┌──────────────────────────────────────────────────────────────────────┐
│             GITHUB (Push / PR / Workflow / Ping Events)              │
└─────────────────────────────┬────────────────────────────────────────┘
                              │ API Gateway: /webhook/github
                              ▼
                    ┌──────────────────┐        ┌──────────────┐
                    │ MODULE 2: Git    │◄──────►│  DynamoDB    │
                    │ Radar            │        │  (State)     │
                    │ (14 functions)   │        └──────────────┘
                    │  + Copilot AI    │
                    └────────┬─────────┘
                             │
                             ├──────────► 📱 Telegram (Dashboard)
                             ├──────────► GitHub (PR Comments, Issues)
                             │
                             ▲ Webhook: agent_scan
                             │
                    ┌──────────────────┐
                    │ MODULE 4: PR     │──────────► GitHub (PR Comments)
                    │ Guardian         │
                    │ (7 functions)    │           Uses OpenAI GPT-4
                    │ [GitHub Actions] │
                    └──────────────────┘

┌──────────────────────────────────────────────────────────────────────┐
│               Cost Alerts / Terraform Failure Webhooks               │
└─────────────────────────────┬────────────────────────────────────────┘
                              │ API Gateway: /webhook/finops
                              ▼
                    ┌──────────────────┐
                    │ MODULE 3: FinOps │──────────► 📱 Telegram (Alerts)
                    │ Sentinel         │──────────► GitHub (PRs, Issues)
                    │ (12 functions)   │
                    │  + Copilot AI    │           Creates Terraform
                    └──────────────────┘           optimization PRs
```

---

## 🔑 Environment Variables Summary

| Variable | Module 1 | Module 2 | Module 3 | Module 4 |
|----------|:--------:|:--------:|:--------:|:--------:|
| `TELEGRAM_TOKEN` | ✅ | ✅ | ✅ | — |
| `TELEGRAM_CHAT_ID` | ✅ | ✅ | ✅ | — |
| `PROJECT_NAME` | ✅ | ✅ | ✅ | — |
| `GITHUB_APP_ID` | — | ✅ | ✅ | — |
| `GITHUB_APP_INSTALLATION_ID` | — | ✅ | ✅ | — |
| `GITHUB_APP_PRIVATE_KEY` | — | ✅ | ✅ | — |
| `GITHUB_REPO_OWNER` | — | ✅ | ✅ | — |
| `GITHUB_REPO_NAME` | — | ✅ | ✅ | — |
| `DYNAMODB_TABLE` | — | ✅ | — | — |
| `GITHUB_TOKEN` | — | — | — | ✅ |
| `OPENAI_API_KEY` | — | — | — | ✅ |
| `CORTEX_RADAR_WEBHOOK` | — | — | — | ✅ |
| `GITHUB_REPOSITORY` | — | — | — | ✅ (auto) |
| `GITHUB_EVENT_PATH` | — | — | — | ✅ (auto) |

---

## Related Documentation

- 📚 [Complete System Architecture](docs/architecture/COMPLETE_SYSTEM_SUMMARY.md)
- 🚀 [Quick Start Guide](docs/setup/QUICK_START_30MIN.md)
- 🔧 [GitHub Actions Integration](docs/integration/GITHUB_ACTIONS_TELEGRAM_GUIDE.md)
- 📊 [Deployment Checklist](docs/deployment/DEPLOYMENT_CHECKLIST.md)
- 🧪 [Testing Guide](docs/testing/TESTING_GUIDE.md)
- 🛡️ [CORTEX Guardian Implementation](docs/implementation/CORTEX_GUARDIAN_IMPLEMENTATION.md)

---

**Generated:** February 17, 2026  
**Version:** 2.0  
**Project:** Cloud-Tibot (Project CORTEX)
