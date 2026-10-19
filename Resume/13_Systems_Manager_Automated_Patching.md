# Systems Manager Automated Patching — Resume Summary

> Status: Terraform authored and `validate`-clean; not yet applied to AWS. Figures below describe the authored footprint and design intent, not a live deployment.

## Project Overview

An automated OS-patching control plane for a mixed Amazon Linux 2023 / Ubuntu 22.04 fleet, built entirely on AWS Systems Manager and provisioned with Terraform. The stack stands up a self-contained VPC, SSM-managed demo EC2 targets, per-OS **Patch Baselines**, staggered weekly **Maintenance Windows**, and `AWS-RunPatchBaseline` Run Command tasks that install approved patches unattended. Instances are grouped by the reserved `Patch Group` tag, patched in bounded waves governed by `max_concurrency` / `max_errors`, and any failed or timed-out task publishes to an SNS topic for on-call alerting. The design targets a healthcare revenue-cycle workload (Meridian Health Partners) where a Critical CVE must be remediated within a 7-day VM-SLA under SOC 2 / HIPAA / PCI-DSS 6.3.3 controls — expressed here as a 7-day patch auto-approval delay plus HIGH-compliance baselines.

## Architecture

```
                        ┌─────────────────────────────┐
                        │   SSM scheduler (cron, UTC)  │
                        └───────────────┬─────────────┘
                                        │ triggers
          ┌─────────────────────────────┴─────────────────────────────┐
          ▼                                                             ▼
┌──────────────────────┐  02:00 SUN                          ┌──────────────────────┐  03:00 SUN
│  Maintenance Window  │                                     │  Maintenance Window  │
│  prod-al2023-mw      │                                     │  prod-ubuntu-mw      │
│  AWS-RunPatchBaseline│                                     │  AWS-RunPatchBaseline│
│  Operation = Install │                                     │  Operation = Install │
└──────────┬───────────┘                                     └──────────┬───────────┘
           │ SendCommand (MW service role)                              │
           ▼                                                            ▼
┌──────────────────────┐                                    ┌──────────────────────┐
│  Patch Baseline      │◄─ bind by Patch Group ─►           │  Patch Baseline      │
│  AMAZON_LINUX_2023   │                                    │  UBUNTU              │
│  Security Crit/Imp   │                                    │  Required/Important  │
│  approve_after 7d    │                                    │  approve_after 7d    │
└──────────┬───────────┘                                    └──────────┬───────────┘
           │ tag Patch Group=prod-al2023                                │ tag Patch Group=prod-ubuntu
           ▼                                                            ▼
   ┌───────────────┐   IMDSv2 · gp3 encrypted · egress-only SG   ┌───────────────┐
   │  EC2 (AL2023) │──────────────┐                 ┌────────────│  EC2 (Ubuntu) │
   │  SSM Agent    │              ▼                 ▼            │  SSM Agent    │
   └───────────────┘   ┌────────────────────────────────┐        └───────────────┘
                       │ Public Subnet → IGW → Internet  │  (SSM public endpoints,
                       │ outbound HTTPS 443 only         │   OS package repos)
                       └────────────────────────────────┘
                                        │ Failed / TimedOut
                                        ▼
                              ┌────────────────────┐
                              │  SNS patch-alerts   │──► email (optional)
                              └────────────────────┘
```

## Technology Stack

| Layer | Technology | Purpose |
|---|---|---|
| **Patch orchestration** | AWS Systems Manager Patch Manager | Per-OS Patch Baselines, Patch Groups, compliance reporting |
| **Scheduling** | SSM Maintenance Windows (6-field cron, UTC) | Staggered weekly patch windows with duration + cutoff |
| **Execution** | SSM Run Command — `AWS-RunPatchBaseline` | `Operation = Install`, bounded by `max_concurrency` / `max_errors` |
| **Compute (targets)** | Amazon EC2 (`t3.micro`, AL2023 + Ubuntu 22.04) | Demo patch targets; AMIs resolved from SSM public parameters (no hard-coded IDs) |
| **Networking** | Self-contained VPC + public subnet + IGW | Egress-only path so the SSM Agent reaches public SSM endpoints |
| **Identity** | IAM — EC2 instance role + MW service role | `AmazonSSMManagedInstanceCore`, `AmazonSSMMaintenanceWindowRole` |
| **Alerting** | Amazon SNS (+ optional email subscription) | `Failed` / `TimedOut` task notifications |
| **IaC** | Terraform >= 1.5 (AWS provider ~> 5.0) | ~24 managed resources; `default_tags`; `for_each` instance expansion |

## Key Achievements

- **Multi-OS patch policy from one config** — AL2023 approves `CLASSIFICATION = Security` + `SEVERITY = Critical/Important`, while Ubuntu (which exposes no `CLASSIFICATION` key) uses `PRIORITY = Required/Important/Standard` + `SECTION` — each expressed through the correct per-OS API surface.
- **7-day VM-SLA encoded as policy** — `approve_after_days = 7` gives a soak window between patch release and automatic install, aligning with the Critical-CVE ≤ 7d SLA while avoiding day-zero regressions.
- **Bounded blast radius** — `AWS-RunPatchBaseline` runs at `max_concurrency = 25%` with a 2-error budget, so a bad patch is caught on the first wave before it reaches the rest of a group.
- **Staggered windows isolate OS failures** — AL2023 patches at 02:00 UTC and completes before Ubuntu starts at 03:00 UTC.
- **Patch exceptions as change control** — `ansible` is `BLOCK`-rejected on AL2023 (never auto-installed, even as a dependency); `openssl` is pre-approved on Ubuntu so a fresh OpenSSL CVE fix installs on the next window without waiting out the delay.
- **No inbound attack surface** — SSM is pull-based, so the security group is egress-only with zero ingress rules; shell access, if needed, is via Session Manager (keyless, audited).
- **Hardened instances by default** — IMDSv2 required (`http_tokens = required`), encrypted `gp3` root volumes, AMIs pinned to latest via SSM public parameters rather than region-specific IDs.

## Infrastructure Components

| Component | Count | Details |
|---|---|---|
| **VPC + Subnet + IGW + Route table** | 4 | Self-contained `10.20.0.0/16`; public subnet `10.20.1.0/24`; default route to IGW |
| **EC2 patch targets** | 2 (default) | `t3.micro`; round-robin across patch groups; `Patch Group` tag; IMDSv2; encrypted gp3 |
| **IAM roles** | 2 | EC2 instance role (`AmazonSSMManagedInstanceCore`) + MW service role (`AmazonSSMMaintenanceWindowRole`) |
| **IAM instance profile** | 1 | Binds the SSM instance role to the EC2 targets |
| **Security group** | 1 | Egress-only, `create_before_destroy`, zero ingress |
| **Patch Baselines** | 2 | `AMAZON_LINUX_2023` + `UBUNTU`; HIGH compliance; 7-day auto-approval; per-OS exceptions |
| **Patch Groups** | 2 | Bind each baseline to its `prod-al2023` / `prod-ubuntu` tag value |
| **Maintenance Windows** | 2 | `cron(0 2 ? * SUN *)` / `cron(0 3 ? * SUN *)`; 2h duration; 1h cutoff |
| **MW Targets** | 2 | Register instances by `tag:Patch Group` |
| **MW Tasks** | 2 | `AWS-RunPatchBaseline`, `Operation = Install`, 25% concurrency, 2-error budget, SNS notify |
| **SNS topic (+ optional sub)** | 1 (+0/1) | `patch-alerts`; email subscription created only when `alert_email` is set |

## Design Decisions & Issues Resolved

| Topic | Consideration | Resolution |
|---|---|---|
| Ubuntu has no `CLASSIFICATION` filter | Copying the AL2023 "Security" filter to the `UBUNTU` baseline is rejected by the API | Express the same intent via Ubuntu's `PRODUCT` / `PRIORITY` / `SECTION` keys — the correct surface for `UBUNTU` |
| Reserved `Patch Group` tag | The join key between instance, baseline, and window is a tag key containing a **space** | Use `"Patch Group"` verbatim as the tag and window-target filter; drive both from one variable so they never drift |
| 30-minute cutoff requested | The Maintenance Window `cutoff` API accepts whole hours only | Express the intended sub-hour cutoff as the minimum representable value of 1 hour and document the constraint |
| Region-specific AMI IDs rot | Hard-coded AMI IDs break across regions and over time | Resolve AL2023 and Ubuntu 22.04 AMIs from SSM public parameters at plan time |
| SSM connectivity without endpoints | Private subnets would need three interface VPC endpoints (`ssm`, `ssmmessages`, `ec2messages`) | For the demo footprint, use a public subnet + IGW (egress-only SG); document the endpoint path as the production hardening step |
| Real alert email in state | A hard-coded subscriber would sit in Terraform state | Make `alert_email` an optional variable; create the subscription only when non-empty (subscriber confirms out-of-band) |

## Validation Status

> Not deployed — the following reflects static validation, not a live patch run.

| Check | Scope | Status |
|---|---|---|
| `terraform fmt -check` | All `.tf` files | Clean |
| `terraform validate` | Provider + resource schema | Clean |
| Variable validation rules | `instance_count >= 1`; `os_family` ∈ {amazon-linux-2023, ubuntu-22.04} | Enforced |
| Cross-reference integrity | `Patch Group` tag ↔ window target filter share one variable | Consistent |
| **Live patch install** | Requires `terraform apply` + a Sunday window | Not yet run |

## Quick Start

```bash
cd "Systems Manager Automated Patching (SSM+EC2+SNS)"
cp terraform.tfvars.example terraform.tfvars   # optionally set alert_email
terraform init
terraform plan
terraform apply

# Confirm instances registered with SSM (~3-5 min for the agent)
aws ssm describe-instance-information --region us-east-1 \
  --query "InstanceInformationList[].{Id:InstanceId,Ping:PingStatus,Platform:PlatformName}"

# Force an on-demand scan without waiting for the window
aws ssm send-command --document-name AWS-RunPatchBaseline \
  --parameters Operation=Scan \
  --targets "Key=tag:Patch Group,Values=prod-al2023" --region us-east-1

# Check live compliance (also emitted as the compliance_query_hint output)
terraform output -raw compliance_query_hint | bash
```

## Cost Estimate

Region `us-east-1`, default `instance_count = 2`, running 24/7. SSM Patch Manager, Maintenance Windows, Run Command, VPC, subnet, IGW, and route tables are free on EC2-based managed instances.

| Resource | Quantity | Monthly Cost (USD) |
|---|---|---|
| EC2 `t3.micro` on-demand | 2 × 730 h × $0.0104 | ~$15.18 |
| EBS `gp3` root volume (8 GB) | 2 × 8 GB × $0.08 | ~$1.28 |
| Public IPv4 address (in-use) | 2 × 730 h × $0.005 | ~$7.30 |
| SNS notifications | Low volume | ~$0.00 |
| SSM Patch Manager / Maintenance Windows | — | $0.00 |
| VPC / Subnet / IGW / Route tables | — | $0.00 |
| **Total** | | **~$23.76 / month** |

> Estimate excludes data transfer and taxes. Stopping the instances between patch windows drops EC2, EBS, and public-IP charges to near zero.

## Security Posture

| Topic | Posture |
|---|---|
| Inbound access | None — egress-only security group, zero ingress rules; no SSH/RDP listener |
| Shell access | Session Manager only (keyless, audited) — no key pairs provisioned |
| Instance metadata | IMDSv2 required (`http_tokens = required`) |
| Encryption | Root EBS volumes encrypted (`gp3`); all SSM traffic over HTTPS |
| IAM | AWS-managed `AmazonSSMManagedInstanceCore` + `AmazonSSMMaintenanceWindowRole`; scope to customer-managed policies for tighter least-privilege |
| Network egress | Open `0.0.0.0/0` outbound via IGW; production path is private subnets + SSM interface VPC endpoints + NAT for repos |
| Patch exceptions | `ansible` blocked, `openssl` fast-tracked — reviewable per change-control policy |
| Compliance evidence | HIGH compliance level recorded per instance; aggregate via SSM Compliance / AWS Config for SOC 2 / HIPAA audit trails |

## Project Structure

```
Systems Manager Automated Patching (SSM+EC2+SNS)/
├── main.tf                    # VPC, IAM, SG, EC2 targets, baselines, windows, tasks, SNS
├── variables.tf               # Inputs with validation (instance_count, patch_groups, schedules)
├── outputs.tf                 # VPC/instance IDs, role ARNs, baseline & window IDs, compliance hint
├── versions.tf                # Terraform >= 1.5, AWS ~> 5.0, default_tags, (commented) S3 backend
├── terraform.tfvars.example   # Copy to terraform.tfvars and adjust
├── .terraform.lock.hcl        # Provider dependency lock
├── .gitignore                 # Excludes state, .terraform/, *.tfvars (keeps .example)
└── README.md                  # Full documentation (14 sections)
```

## Key Learnings & Technical Decisions

**Per-OS baselines, not one baseline:** Amazon Linux and Ubuntu expose fundamentally different patch-metadata surfaces. AL2023 supports `CLASSIFICATION` + `SEVERITY`; Ubuntu supports `PRODUCT` + `PRIORITY` + `SECTION`. Rather than force a lowest-common-denominator filter, each OS gets a baseline expressed in its own native keys — which is what Patch Manager actually validates against.

**The `Patch Group` tag is the entire binding mechanism.** A single tag value (`prod-al2023`) simultaneously associates an instance with its baseline (via the Patch Group resource) and makes it a maintenance-window target (via the target filter). Driving both from one Terraform variable guarantees the two references can never silently diverge — the most common cause of "my instances aren't getting patched."

**Concurrency and error budgets are the safety rail.** Patching is a fleet-wide mutation; `max_concurrency = 25%` plus `max_errors = 2` means a regression surfaces on the first wave and halts the run before it can take down every host, with SNS firing on the failure.

**Pull-based means no inbound.** Because the SSM Agent initiates all connections outbound over 443, the instances need zero ingress. The security group is egress-only, which removes SSH/RDP as an attack surface entirely and pushes interactive access onto the audited Session Manager path.

## What I'd Do Differently

- Move targets to private subnets behind three SSM interface VPC endpoints (`ssm`, `ssmmessages`, `ec2messages`) + a NAT/S3 gateway for repos, removing public IPs and the open egress path.
- Add a pre-Install `Scan` task and stream patch compliance into AWS Config / a QuickSight dashboard for continuous SOC 2 / HIPAA evidence.
- Replace the AWS-managed IAM policies with customer-managed policies scoped to the specific baselines and windows.
- Enable SSE-KMS on the SNS topic and add a topic policy restricting `sns:Publish` to the maintenance-window role.
- Wire the SNS topic to PagerDuty/Opsgenie (HTTPS or Lambda subscription) instead of plain email for real on-call routing.

## Summary

This project demonstrates a production-shaped, multi-OS automated patching control plane built entirely on AWS Systems Manager and Terraform: per-OS Patch Baselines expressed in each OS's native filter surface, a reserved-tag binding model that keeps baselines and maintenance-window targets in lockstep, staggered windows with bounded concurrency and an error budget, patch-exception change control, and SNS alerting on failure — all on hardened, egress-only, IMDSv2 instances. Authored footprint: ~24 Terraform-managed resources on the default 2-instance configuration. Status: `terraform validate`-clean and ready to apply; not yet deployed, so compliance and patch-install results are pending a live window.
