# AWS Project — Claude Instructions

## Agent Team

Work on this repository is executed by a team of specialized subagents launched via the Agent tool.
Every role below is a **hired agent** with a definition file in `.claude/agents/` — they are real,
invocable agents, not prose personas. The Main Agent orchestrates and reports to the Boss (the
user); it does **not** perform the hands-on IaC, application, documentation, or Git work itself.

The team covers **AWS and Azure**. Both accounts are live and verified.

### Roster

| Role | Agent file | Owns | Key tools / skills |
|---|---|---|---|
| **Main Agent** | — (top-level session) | Talks to the Boss, delegates, reviews, reports. Writes no deliverables directly. | Agent (to spawn), read-only inspection |
| **Orchestrator** | `orchestrator.md` | Breaks a request into a sequenced delivery plan, hands it to HR, reviews each output against the New Project Checklist, enforces the approval gates. | Agent, TodoWrite, read-only inspection |
| **HR** | `hr.md` | Staffing & coordination. Spawns engineers with scoped briefs, tracks status, enforces the handoff order, verifies the checklist. No hands-on technical work. | Agent, TodoWrite |
| **Cloud Architect** | `cloud-architect.md` | Scenario framing. Runs first. Drafts the **enterprise scenario** — business context, personas, scale, SLAs/SLOs, compliance and security drivers — and the AWS or Azure architecture those imply. Presents to the Boss for approval. Produces no IaC. | `aws-docs` MCP, `aws-pricing` MCP, `context7`, WebSearch |
| **Cloud Engineer** | `cloud-engineer.md` | Infrastructure-as-Code authoring and deployment on **AWS and Azure** — writes Terraform, runs `plan` / `apply`, verifies live resources. | Terraform, `aws-api` MCP, `aws-iac` MCP, `aws-pricing` MCP, `az` CLI |
| **DevOps Engineer** | `devops-engineer.md` | Audit, CI/CD, and observability. Runs `/audit` and writes `Result.md` from live data, builds GitHub Actions pipelines with OIDC, wires alarms and dashboards, troubleshoots failures. | `/audit`, `/troubleshoot`, `aws-api` MCP, `aws-cloudwatch` MCP |
| **Full Stack Engineer** | `fullstack-engineer.md` | Application code — backend APIs, frontend UIs, schemas and migrations, Dockerfiles, and application tests. Laravel, Node, Python, React. | Bash, Read/Write/Edit, `context7`, `playwright` MCP |
| **Documentation Engineer** | `documentation-engineer.md` | Creates the project folder, writes the project `README.md` per the **README Template**, updates the root navigation `README.md` per checklist §3, writes the `Resume/` entry. | Read/Write/Edit, README Template rules |
| **GitHub Engineer** | `github-engineer.md` | Final handoff — feature branch, commits (excluding state/secrets/`node_modules`), push, and a PR against `main` for the Boss. Never merges. | Bash (`git`, `gh`) |
| **Codex Auditor** | `codex-auditor.md` | Independent second-opinion review of Terraform and CI/CD via the Codex CLI (GPT-5.x). Read-only. Optional, on request. | Codex CLI, Bash, Read/Write |

> The former **DevOps Engineer (Audit)** role has been merged into the **DevOps Engineer**, which
> now owns the `/audit` skill alongside CI/CD and observability.

### Org chart

```
                          ┌─────────┐
                          │  Boss   │  (the user — reviews the PR)
                          └────┬────┘
                               │ request
                               ▼
                        ┌──────────────┐
                        │  Main Agent  │  delegates, reports back
                        └──────┬───────┘
                               │ context
                               ▼
                        ┌──────────────┐
                        │ Orchestrator │  plans & sequences
                        └──────┬───────┘
                               │
                               ▼
                    ┌────────────────────┐
                    │  Cloud Architect   │  drafts enterprise
                    │  (scenario framing)│  scenario
                    └─────────┬──────────┘
                              │ scenario ◄──── Boss reviews & approves
                              ▼
                       ┌──────────────┐
                       │      HR      │  staffs & coordinates
                       └──────┬───────┘
        ┌──────────────┬──────┴───────┬──────────────────┐
        ▼              ▼              ▼                  ▼
┌───────────────┐ ┌──────────┐ ┌─────────────┐ ┌──────────────────┐
│ Cloud         │ │ Full     │ │ DevOps      │ │ Documentation    │
│ Engineer      │ │ Stack    │ │ Engineer    │ │ Engineer         │
│ (IaC+deploy)  │ │ Engineer │ │ (audit/CI)  │ │ (folder+READMEs) │
└───────┬───────┘ └────┬─────┘ └──────┬──────┘ └────────┬─────────┘
        └──────────────┴──────────────┴─────────────────┘
                              │
                              ▼
                       ┌──────────────┐
                       │ GitHub       │  branch + push + PR
                       │ Engineer     │
                       └──────┬───────┘
                              │ PR
                              ▼
                          ┌─────────┐
                          │  Boss   │  reviews & merges
                          └─────────┘
```

### Handoff order

1. **Boss → Main Agent** — the Boss states the goal and provides project context.
2. **Main Agent → Orchestrator** — the Orchestrator breaks the request into a sequenced plan.
3. **Orchestrator → Cloud Architect** — the Architect drafts the enterprise scenario.
4. **Cloud Architect → Boss** — the Architect presents the scenario for review; the Boss approves or
   requests changes, iterating until approved. **No downstream work starts until the Boss approves
   the scenario.**
5. **Orchestrator → HR** — the plan plus the approved scenario go to HR for staffing. HR includes
   the approved scenario **verbatim** in every engineer's brief.
6. **HR → Cloud Engineer** — provisions and deploys the infrastructure with Terraform, then verifies
   live resources via the `aws-api` MCP server or the `az` CLI.
7. **HR → Full Stack Engineer** — builds and ships application code, if the project has any. May run
   in parallel with the Cloud Engineer once the network and data layers exist.
8. **HR → DevOps Engineer + Documentation Engineer** — run once deployment is confirmed. DevOps
   produces `Result.md` and wires CI/CD and alarms; Documentation creates the folder and writes all
   READMEs and the `Resume/` entry. These two may run in parallel.
9. **HR → GitHub Engineer** — after all outputs are in place and the checklist is satisfied, creates
   the branch, pushes, and opens the PR.
10. **GitHub Engineer → Boss** — the Boss reviews the PR. No merge happens without Boss approval.

### Shared rules for all engineers

- **Terraform is mandatory** for all Infrastructure-as-Code, on both clouds. Do not use raw
  CLI/console mutations or CloudFormation for provisioning.
- **`terraform apply` requires explicit Boss approval.** `plan` freely; `apply` on the word only.
- Use the **`aws-api` MCP server** and the **`az` CLI** to verify and test deployed resources
  against the live accounts (read-only checks, smoke tests).
- The `aws-iac`, `aws-pricing`, and `aws-cloudwatch` MCP servers are available for validation, cost
  estimation, and observability.
- **Never commit** state files, `.terraform/`, `.env`, credentials, or vendored dependencies.
- Follow the project **Style Rules** (below) for any file produced.

### Cloud accounts

| Cloud | Identifier | Default region |
|---|---|---|
| AWS | account `022499047467` | `ap-southeast-1` |
| Azure | subscription `Artherise.cloud` / `27952e89-6e15-41ff-8dda-fe4917979697`, tenant Aterpise MY / `9d1d0a5b-214e-4c08-ae0c-3b50b7badce7` | `southeastasia` |

> Azure re-authentication: `az login --tenant 9d1d0a5b-214e-4c08-ae0c-3b50b7badce7`. Always name the
> tenant — the untargeted form has failed on this account. The `azurerm` provider requires
> `subscription_id` in the provider block; v4 removed the silent CLI fallback.

> HR must not staff any engineer until the Boss has approved the enterprise scenario from the Cloud Architect.

> HR must not hand off to the GitHub Engineer until the deploy is verified, `Result.md` exists, and every README/Resume section required by the New Project Checklist is complete.

---

## Obsidian Knowledge Vault

All troubleshooting sessions, architecture decisions, and post-mortems must be written to the Obsidian vault at:

```
/Users/brendonang/Documents/Obsidian/AWS KB/
```

Folder structure inside the vault:

| Folder | What goes in it |
|--------|----------------|
| `Troubleshooting/` | One note per issue, named `YYYY-MM-DD_slug.md` |
| `Architecture/` | Design decisions, trade-off notes, diagrams |
| `Post-Mortems/` | Root cause analysis after incidents |
| `Runbooks/` | Step-by-step operational procedures |

Use the `/troubleshoot` command whenever diagnosing an AWS issue — it handles diagnosis AND writes the vault note automatically.

---

## README Template

Every time a new project README.md is created, it must follow this structure exactly, in this section order. Adapt the content to the specific project (ALB vs NLB, Terraform vs CDK, etc.) but keep all sections present.

---

### Required Section Order

1. **Title + one-paragraph description** — what the project deploys and how traffic/scaling works
2. **Table of Contents** — numbered, links to all sections below
3. **Architecture Overview** — ASCII diagram showing the full traffic path (Internet → IGW → LB → EC2/ECS, plus CloudWatch), followed by a plain-English "Traffic flow:" line
4. **Networking & Routing** — tables for VPC, Subnets, Route Tables, and a "Traffic Flow" ASCII sub-diagram
5. **Component Details** — one numbered sub-section per major resource (Security Group, Launch Template / Task Definition, Load Balancer, Target Group, Auto Scaling Group, Scaling Policies & CloudWatch Alarms). Each sub-section uses a Markdown table for attributes.
6. **Directory Structure** — fenced code block showing every file in the project folder with one-line descriptions
7. **Prerequisites** — table of Tool / Minimum Version / Install link, plus any account-level requirements
8. **Quick Start** — fenced bash block with numbered steps; end with "Allow N minutes for health checks"
9. **Input Variables** — table: Variable | Type | Default | Description; note any cross-variable validation rules
10. **Outputs** — table: Output | Description; include a `terraform output` usage example
11. **Scaling Behaviour** — ASCII chart of CPU % vs time with dead-band explanation, evaluation-period note, and step-size rationale
12. **Tagging Strategy** — table of Tag Key | Value; note any resource-specific tag propagation quirks
13. **Security Considerations** — table of Topic | Current posture | Recommended hardening
14. **Cost Estimate** — table of Resource | Quantity | Monthly cost (USD) with a total row and a link to AWS Pricing Calculator
15. **Destroying the Stack** — `terraform destroy` command plus any manual pre-steps (e.g., disabling deletion protection); note which resources are NOT managed by Terraform and will survive
16. **Frequently Asked Questions** — at least 4 Q&A pairs covering: 502 errors, single-AZ concentration, adding HTTPS, updating app code, remote state, and scaling policy rationale

---

---

## New Project Checklist

When a new AWS project is **created and fully deployed**, complete all of the following before closing the session:

### 1. Audit (`/audit`)
Run the `/audit` skill to collect live AWS resource data and write `Result.md` inside the project folder.

### 2. Resume entry
Create a new numbered file in `Resume/` (e.g. `6_App_Runner_Deployment.md`) following the format of existing entries:
- Project Overview paragraph
- Architecture ASCII diagram
- Technology Stack table
- Key Achievements bullets
- Infrastructure Components table
- Deployment Issues Diagnosed & Resolved table (all issues with root cause + fix)
- Test results table
- Quick Start bash block
- Cost Estimate table
- Security Posture table
- Project Structure code block
- Key Learnings & Technical Decisions
- What I'd Do Differently
- Summary closing paragraph

### 3. Root README.md updates
Edit `/Users/brendonang/Code/AWS Project/README.md` and update **every** section that references project count or lists:

| Section | What to update |
|---|---|
| **Project Overview** | Increment project count ("5 complete" → "6 complete") |
| **Quick Navigation** table | Add new row with project name, type, deploy time, cost |
| **Projects** section | Add new numbered `###` entry with description, architecture, features, stack, cost, links |
| **Technology Stack → AWS Services** table | Add any new services used (e.g. App Runner, ECR, Docker) |
| **Key Achievements** | Update total test count if new tests added |
| **Cost Summary** table | Add new project row; update total estimate |
| **Testing & Validation** table | Add new project row with test counts |
| **Performance Benchmarks** table | Add new project column |
| **Repository Structure** code block | Add new project folder tree |
| **Quick Links** table | Update Current Branch and Latest PR number |
| **Last Updated** line | Set to today's date |

### 4. CLAUDE.md (this file)
No update needed after adding a project — the checklist above is the standing instruction.

### 5. Git
Create a feature branch (`feat/<project-slug>`), commit all project files (excluding state, secrets, node_modules), push, and open a PR against `main`.

---

### Style Rules

- ASCII diagrams use box-drawing characters (`┌ ─ ┐ │ └ ┘ ▼ ├ ┤ ▲`), not plain dashes
- Every Markdown table has a header row + separator row
- Inline code for all resource IDs, ARNs, CLI commands, and file names
- Blockquotes (`>`) for production notes and caveats inside component sections
- No emoji
- Section headers are `##` (h2) for top-level, `###` (h3) for sub-sections
