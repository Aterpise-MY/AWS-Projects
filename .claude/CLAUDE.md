# AWS Project — Claude Instructions

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
