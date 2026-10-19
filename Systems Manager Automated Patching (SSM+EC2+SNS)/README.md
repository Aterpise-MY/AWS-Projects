# Systems Manager Automated Patching (SSM+EC2+SNS)

Automate OS patching across a mixed Amazon Linux 2023 / Ubuntu 22.04 fleet with AWS Systems Manager. This Terraform configuration provisions a self-contained VPC, SSM-managed demo EC2 targets, per-OS **Patch Baselines**, staggered weekly **Maintenance Windows**, and `AWS-RunPatchBaseline` Run Command tasks that install approved patches unattended. Instances are grouped by the reserved `Patch Group` tag, patched in controlled waves (`max_concurrency` / `max_errors`), and task failures are pushed to an SNS topic for on-call alerting. The design targets a healthcare revenue-cycle workload (Meridian Health Partners) where a Critical CVE must be remediated within a 7-day VM-SLA under SOC 2 / HIPAA / PCI-DSS 6.3.3 controls.

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Networking & Routing](#networking--routing)
3. [Component Details](#component-details)
4. [Directory Structure](#directory-structure)
5. [Prerequisites](#prerequisites)
6. [Quick Start](#quick-start)
7. [Input Variables](#input-variables)
8. [Outputs](#outputs)
9. [Patch Rollout Behaviour](#patch-rollout-behaviour)
10. [Tagging Strategy](#tagging-strategy)
11. [Security Considerations](#security-considerations)
12. [Cost Estimate](#cost-estimate)
13. [Destroying the Stack](#destroying-the-stack)
14. [Frequently Asked Questions](#frequently-asked-questions)

## Architecture Overview

```
┌──────────────────────────────────────────────────────────────────────────┐
│                     AWS Systems Manager — Patch Manager                    │
│              Patch Baselines · Maintenance Windows · Run Command           │
└──────────────────────────────────────────────────────────────────────────┘

                        ┌─────────────────────────────┐
                        │   EventBridge (SSM-internal) │
                        │   cron schedules (UTC)       │
                        └───────────────┬─────────────┘
                                        │ triggers
          ┌─────────────────────────────┴─────────────────────────────┐
          ▼                                                             ▼
┌──────────────────────┐                                    ┌──────────────────────┐
│  Maintenance Window  │  02:00 SUN                          │  Maintenance Window  │  03:00 SUN
│  prod-al2023-mw      │                                     │  prod-ubuntu-mw      │
│  Task: RunPatch...   │                                     │  Task: RunPatch...   │
│  Operation = Install │                                     │  Operation = Install │
└──────────┬───────────┘                                     └──────────┬───────────┘
           │ SendCommand (via MW service role)                          │
           ▼                                                            ▼
┌──────────────────────┐                                    ┌──────────────────────┐
│  Patch Baseline      │◄── binds via Patch Group ──►        │  Patch Baseline      │
│  AMAZON_LINUX_2023   │                                     │  UBUNTU              │
│  Security Crit/Imp   │                                     │  Required/Important  │
│  approve_after 7d    │                                     │  approve_after 7d    │
└──────────┬───────────┘                                     └──────────┬───────────┘
           │ target: tag Patch Group=prod-al2023                        │ tag Patch Group=prod-ubuntu
           ▼                                                            ▼
   ┌───────────────┐                                            ┌───────────────┐
   │  EC2 (AL2023) │   IMDSv2 · gp3 encrypted · egress-only SG  │  EC2 (Ubuntu) │
   │  SSM Agent    │───────────┐                    ┌───────────│  SSM Agent    │
   └───────────────┘           │                    │           └───────────────┘
                               ▼                    ▼
                        ┌────────────────────────────────┐
                        │  Public Subnet → IGW → Internet │  (SSM public endpoints,
                        │  outbound HTTPS 443 only        │   OS package repos)
                        └────────────────────────────────┘
                                        │ Failed / TimedOut
                                        ▼
                              ┌────────────────────┐
                              │  SNS patch-alerts   │──► email (optional)
                              └────────────────────┘
```

Traffic flow: SSM's internal scheduler fires each Maintenance Window on its UTC cron → the window's `AWS-RunPatchBaseline` task assumes the MW service role and issues a Run Command `SendCommand` to every instance matching the window's `Patch Group` tag → the SSM Agent on each instance evaluates the OS-specific Patch Baseline, downloads approved packages over outbound HTTPS through the IGW, installs them (`Operation = Install`), and reports compliance back to SSM → any `Failed` or `TimedOut` invocation publishes to the `patch-alerts` SNS topic.

## Networking & Routing

The stack builds its own minimal VPC rather than depending on a default VPC. Because SSM is pull-based over outbound HTTPS, the instances need only egress; the design uses a public subnet + IGW so the SSM Agent reaches the public SSM endpoints without paying for interface VPC endpoints (a production hardening path is noted below).

### VPC

| Attribute | Value |
|-----------|-------|
| CIDR block | `10.20.0.0/16` (`var.vpc_cidr`) |
| DNS support | Enabled |
| DNS hostnames | Enabled |
| Name tag | `ssm-patching-prod-vpc` |

### Subnets

| Subnet | CIDR | AZ | Public IP on launch | Purpose |
|--------|------|----|--------------------|---------|
| `ssm-patching-prod-public-subnet` | `10.20.1.0/24` (`var.public_subnet_cidr`) | First available AZ | Yes | Hosts all demo patch targets |

### Route Tables

| Route Table | Destination | Target | Associated Subnet |
|-------------|-------------|--------|-------------------|
| `ssm-patching-prod-public-rt` | `10.20.0.0/16` | `local` | — |
| `ssm-patching-prod-public-rt` | `0.0.0.0/0` | `ssm-patching-prod-igw` | `ssm-patching-prod-public-subnet` |

### Traffic Flow

```
┌──────────────────────────────────────────────────────────────┐
│  SSM Agent on EC2 initiates OUTBOUND connection (pull model)  │
│  → ssm.<region>.amazonaws.com                                 │
│  → ssmmessages.<region>.amazonaws.com                         │
│  → ec2messages.<region>.amazonaws.com                         │
│  → OS package mirrors (amazonlinux / ubuntu archives)         │
└─────────────────────────────┬────────────────────────────────┘
                              │  HTTPS 443, egress-only SG
                              ▼
                    ┌───────────────────┐
                    │  Public Subnet    │
                    │  10.20.1.0/24     │
                    └─────────┬─────────┘
                              │  default route 0.0.0.0/0
                              ▼
                    ┌───────────────────┐
                    │  Internet Gateway │
                    └─────────┬─────────┘
                              ▼
                         Internet
                    (no inbound path — SG has zero ingress rules)
```

## Component Details

### 1. Security Group (`aws_security_group.ssm_egress`)

SSM is pull-based, so no inbound access is required. The security group is created egress-only with `create_before_destroy` to avoid interruption on replacement.

| Attribute | Value |
|-----------|-------|
| Name prefix | `ssm-patching-prod-ssm-egress-` |
| Ingress rules | **None** (zero inbound) |
| Egress | All protocols / all ports to `0.0.0.0/0` |
| Lifecycle | `create_before_destroy = true` |

> No inbound rule means no SSH, no RDP, and no listener is exposed. Session access, if needed, is via SSM Session Manager — auditable and keyless.

### 2. IAM — EC2 Instance Role & Profile

Attached to every demo instance so the SSM Agent can register with Fleet Manager, Run Command, Patch Manager, and Session Manager.

| Attribute | Value |
|-----------|-------|
| Role | `ssm-patching-prod-ssm-instance-role` |
| Trust | `ec2.amazonaws.com` (`sts:AssumeRole`) |
| Managed policy | `arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore` |
| Instance profile | `ssm-patching-prod-ssm-instance-profile` |

### 3. IAM — Maintenance Window Service Role

Assumed by SSM to run the patch task and publish task-lifecycle notifications to SNS.

| Attribute | Value |
|-----------|-------|
| Role | `ssm-patching-prod-mw-role` |
| Trust | `ssm.amazonaws.com` (`sts:AssumeRole`) |
| Managed policy | `arn:aws:iam::aws:policy/service-role/AmazonSSMMaintenanceWindowRole` |
| Grants | `ssm:SendCommand`, `sns:Publish` (for notification config) |

### 4. EC2 Patch Targets (`aws_instance.demo`)

`var.instance_count` instances are distributed round-robin across the patch groups (keys sorted). The default of `2` yields one AL2023 target and one Ubuntu target. AMIs resolve from SSM public parameters — no hard-coded, region-specific AMI IDs.

| Attribute | Value |
|-----------|-------|
| Count | `var.instance_count` (default `2`) |
| Instance type | `t3.micro` (per patch group) |
| AMI (AL2023) | `/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64` |
| AMI (Ubuntu) | `/aws/service/canonical/ubuntu/server/22.04/stable/current/amd64/hvm/ebs-gp2/ami-id` |
| Public IP | Enabled (reaches public SSM endpoints via IGW) |
| Metadata | IMDSv2 required (`http_tokens = "required"`) |
| Root volume | 8 GB `gp3`, encrypted |
| Key tag | `Patch Group` (note the space — reserved SSM key) |

### 5. Patch Baselines

Two custom baselines, one per OS family. Both auto-approve matching patches after `var.approve_after_days` (7) and stamp `HIGH` compliance.

| Attribute | Amazon Linux 2023 | Ubuntu 22.04 |
|-----------|-------------------|--------------|
| Resource | `aws_ssm_patch_baseline.al2023` | `aws_ssm_patch_baseline.ubuntu` |
| `operating_system` | `AMAZON_LINUX_2023` | `UBUNTU` |
| Approval filter | `CLASSIFICATION = Security` + `SEVERITY = Critical, Important` | `PRODUCT = Ubuntu22.04` + `PRIORITY = Required, Important, Standard` + `SECTION = *` |
| `approve_after_days` | 7 | 7 |
| Compliance level | `HIGH` | `HIGH` |
| Exception | `rejected_patches = ["ansible"]`, action `BLOCK` | `approved_patches = ["openssl"]` (fast-track CVE fixes) |

> Ubuntu does not expose a `CLASSIFICATION` filter key. The "security + bugfix" intent is expressed through Ubuntu's `PRIORITY` levels and `SECTION`, which is the correct API surface for the `UBUNTU` operating system.

### 6. Patch Groups (`aws_ssm_patch_group`)

Bind each baseline to a `Patch Group` tag value so Patch Manager knows which baseline governs an instance.

| Patch Group value | Baseline |
|-------------------|----------|
| `prod-al2023` | `ssm-patching-prod-al2023-baseline` |
| `prod-ubuntu` | `ssm-patching-prod-ubuntu-baseline` |

### 7. Maintenance Windows

Staggered one hour apart so the two OS waves never contend, and so an early failure in the AL2023 wave is visible before Ubuntu begins.

| Attribute | AL2023 | Ubuntu |
|-----------|--------|--------|
| Schedule (UTC) | `cron(0 2 ? * SUN *)` | `cron(0 3 ? * SUN *)` |
| Duration | 2 h (`var.window_duration_hours`) | 2 h |
| Cutoff | 1 h (`var.window_cutoff_hours`) | 1 h |
| `allow_unassociated_targets` | `false` | `false` |

> `window_cutoff_hours` accepts whole hours only, so the requested 30-minute cutoff is expressed as the minimum representable value of 1 hour.

### 8. Maintenance Window Targets & Tasks

Targets register instances by the `Patch Group` tag; tasks run `AWS-RunPatchBaseline` with `Operation = Install`.

| Attribute | Value |
|-----------|-------|
| Target key | `tag:Patch Group` → `prod-al2023` / `prod-ubuntu` |
| Task document | `AWS-RunPatchBaseline` (`RUN_COMMAND`) |
| Operation | `Install` |
| Priority | `1` |
| `max_concurrency` | `25%` (`var.max_concurrency`) |
| `max_errors` | `2` (`var.max_errors`) |
| Task timeout | 3600 s |
| Notifications | `Failed`, `TimedOut` → SNS (`Command` level) |

### 9. SNS Alerting (`aws_sns_topic.patch_alerts`)

| Attribute | Value |
|-----------|-------|
| Topic | `ssm-patching-prod-patch-alerts` |
| Subscription | Email (created only if `var.alert_email` is non-empty; subscriber must confirm) |
| Events published | Run Command `Failed` and `TimedOut` |

## Directory Structure

```
Systems Manager Automated Patching (SSM+EC2+SNS)/
├── main.tf                    # VPC, IAM, SG, EC2 targets, baselines, windows, tasks, SNS
├── variables.tf               # Input variables with validation (instance_count, patch_groups, schedules)
├── outputs.tf                 # VPC/instance IDs, role ARNs, baseline & window IDs, compliance query hint
├── versions.tf                # Terraform >= 1.5, AWS provider ~> 5.0, default_tags, (commented) S3 backend
├── terraform.tfvars.example   # Copy to terraform.tfvars and adjust
├── .terraform.lock.hcl        # Provider dependency lock
├── .gitignore                 # Excludes state, .terraform/, *.tfvars (keeps .example)
└── README.md                  # This file
```

## Prerequisites

| Tool | Minimum Version | Install |
|------|-----------------|---------|
| Terraform | 1.5 | https://developer.hashicorp.com/terraform/install |
| AWS CLI | 2.x | https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html |
| AWS credentials | — | `aws configure` or an assumed role/SSO profile |

Account-level requirements:

- IAM permissions to create VPC, EC2, IAM roles/policies, SSM patch resources, and SNS topics.
- Service-linked prerequisites for SSM are automatic once `AmazonSSMManagedInstanceCore` is attached and the instance has outbound HTTPS.
- To receive alerts, a reachable mailbox for `var.alert_email` (the subscription must be confirmed from the email link).

## Quick Start

```bash
# 1. Enter the project directory
cd "Systems Manager Automated Patching (SSM+EC2+SNS)"

# 2. Copy and (optionally) edit the variables file
cp terraform.tfvars.example terraform.tfvars
#   e.g. set alert_email = "patch-ops@meridianhealth.example"

# 3. Initialize providers
terraform init

# 4. Review the plan (deploy only after the footprint is approved)
terraform plan

# 5. Apply
terraform apply

# 6. Confirm the instances registered with SSM (wait ~3-5 minutes for the agent)
aws ssm describe-instance-information --region us-east-1 \
  --query "InstanceInformationList[].{Id:InstanceId,Ping:PingStatus,Platform:PlatformName}"

# 7. (Optional) Force an on-demand patch scan without waiting for the window
aws ssm send-command --document-name AWS-RunPatchBaseline \
  --parameters Operation=Scan \
  --targets Key=tag:Patch Group,Values=prod-al2023 --region us-east-1
```

Allow 3-5 minutes after apply for the SSM Agent to report `Online` before running scans or compliance checks. Scheduled installs occur only during the Sunday maintenance windows.

## Input Variables

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `region` | `string` | `us-east-1` | AWS region to deploy into. |
| `project_name` | `string` | `ssm-patching` | Base name for resources (kept short; some SSM names are length-limited). |
| `environment` | `string` | `prod` | Deployment environment; also applied as a default tag. |
| `application` | `string` | `revenue-cycle-platform` | `Application` tag on every demo instance. |
| `vpc_cidr` | `string` | `10.20.0.0/16` | CIDR for the project VPC. |
| `public_subnet_cidr` | `string` | `10.20.1.0/24` | CIDR for the public subnet hosting the targets. |
| `instance_count` | `number` | `2` | Total demo instances, distributed round-robin across `patch_groups`. Validated `>= 1`. |
| `patch_groups` | `map(object)` | AL2023 + Ubuntu | Per-OS definition: `patch_group` tag value, `os_family`, `instance_type`. `os_family` validated to `amazon-linux-2023` or `ubuntu-22.04`. |
| `approve_after_days` | `number` | `7` | Auto-approval delay for matching patches (aligns with the Critical-CVE ≤ 7d VM-SLA). |
| `al2023_schedule` | `string` | `cron(0 2 ? * SUN *)` | 6-field UTC cron for the AL2023 window. |
| `ubuntu_schedule` | `string` | `cron(0 3 ? * SUN *)` | 6-field UTC cron for the Ubuntu window (one hour after AL2023). |
| `window_duration_hours` | `number` | `2` | Maintenance window duration (hours). |
| `window_cutoff_hours` | `number` | `1` | Hours before window end when SSM stops starting new tasks (whole hours only). |
| `max_concurrency` | `string` | `25%` | Max % (or count) of targets patched simultaneously. |
| `max_errors` | `string` | `2` | Max errors (or %) tolerated before the task stops. |
| `alert_email` | `string` | `""` | Optional email subscribed to `patch-alerts`. Empty creates the topic with no subscription. |

> Cross-variable rule: each `patch_groups` `patch_group` value is written verbatim to the reserved `Patch Group` instance tag **and** used as the maintenance-window target filter — the two must stay in sync, which Terraform guarantees by referencing the same variable.

## Outputs

| Output | Description |
|--------|-------------|
| `vpc_id` | ID of the project VPC. |
| `subnet_id` | ID of the public subnet. |
| `instance_ids` | Map of instance logical key → EC2 instance ID. |
| `instance_patch_groups` | Map of instance logical key → its `Patch Group` tag value. |
| `instance_count_effective` | Total demo instances created. |
| `ssm_instance_role_arn` | ARN of the EC2 SSM instance role. |
| `maintenance_window_role_arn` | ARN of the MW service role. |
| `patch_baseline_ids` | Baseline IDs per OS (`al2023`, `ubuntu`). |
| `maintenance_window_ids` | Maintenance window IDs per patch group. |
| `sns_topic_arn` | ARN of the `patch-alerts` topic. |
| `compliance_query_hint` | Ready-to-run CLI to check live patch compliance. |

```bash
# Example: read the compliance query hint and check patch state
terraform output -raw compliance_query_hint | bash
```

## Patch Rollout Behaviour

Patch waves are governed by `max_concurrency` and `max_errors` on the Run Command task, not by CPU autoscaling. The window opens on its cron schedule, patches roll out in bounded batches, and the run aborts if the error budget is exceeded — protecting the fleet from a bad patch taking down every host at once.

```
Targets patched over the maintenance window (max_concurrency = 25%, max_errors = 2)

100% ┤                                         ┌────────────  window closes
 nodes│                                    ┌────┘   (all compliant)
      │                              ┌─────┘
  75% ┤                        ┌─────┘   batch 4 (25%)
      │                  ┌─────┘         batch 3 (25%)
  50% ┤            ┌─────┘               batch 2 (25%)
      │      ┌─────┘                     batch 1 (25%)
  25% ┤ ─────┘
      │
   0% ┼──┬────┬────┬────┬────┬────┬────┬────┬──►  time
     02:00                                    04:00
      │◄──── cutoff: no NEW tasks start after 03:00 ────►│

  Error budget: if > 2 invocations return Failed/TimedOut, the task STOPS
  and remaining batches are skipped → SNS patch-alerts fires.
```

- **Bounded blast radius**: only 25% of a group is in-flight at once; a regression is caught on the first batch before it reaches the rest.
- **Cutoff**: SSM stops *starting* new invocations one hour before the window ends, so in-progress patches have time to finish and reboot inside the window.
- **Auto-approval delay**: `approve_after_days = 7` gives a 7-day soak between a patch's release and its automatic installation — matching the Critical-CVE VM-SLA while avoiding day-zero regressions.
- **Staggered windows**: AL2023 (02:00) completes before Ubuntu (03:00) begins, isolating OS-specific failures.

## Tagging Strategy

| Tag Key | Value | Applied to |
|---------|-------|------------|
| `Project` | `SSM-Automated-Patching` | All resources (provider `default_tags`) |
| `Environment` | `prod` (`var.environment`) | All resources (default) + instances |
| `ManagedBy` | `Terraform` | All resources (default) |
| `Name` | `ssm-patching-prod-<resource>` | Each named resource |
| `Patch Group` | `prod-al2023` / `prod-ubuntu` | EC2 instances only |
| `Application` | `revenue-cycle-platform` (`var.application`) | EC2 instances |
| `PatchGroup` / `OSFamily` | per-OS | Baselines, windows |

> The `Patch Group` key contains a **space** and is reserved by SSM — it is the join key between an instance, its baseline, and its maintenance-window target. Do not rename it. Note it is distinct from the space-free `PatchGroup` label used for human-readable grouping on baselines/windows.

## Security Considerations

| Topic | Current posture | Recommended hardening |
|-------|-----------------|----------------------|
| Inbound access | None — egress-only SG, no SSH/RDP | Keep closed; use Session Manager for shell access |
| Instance metadata | IMDSv2 required (`http_tokens = required`) | Already enforced |
| EBS encryption | Root volume encrypted (`gp3`) | Use a customer-managed KMS key for key rotation control |
| IAM least privilege | AWS-managed `AmazonSSMManagedInstanceCore` + `AmazonSSMMaintenanceWindowRole` | Scope to a customer-managed policy limited to the specific baselines/windows |
| Network egress | Open `0.0.0.0/0` outbound via IGW | Replace public IPs with SSM interface VPC endpoints (`ssm`, `ssmmessages`, `ec2messages`) + private subnet + NAT for repos |
| Public IP exposure | Instances have public IPv4 | Move to private subnets once VPC endpoints are in place; removes the public attack surface entirely |
| SNS topic | Unencrypted | Enable SSE-KMS on the topic; restrict `sns:Publish` to the MW role via topic policy |
| Patch exceptions | `ansible` blocked, `openssl` fast-tracked | Review the reject/approve lists per change-control policy |
| Compliance evidence | `HIGH` compliance level recorded per instance | Aggregate via SSM Compliance / AWS Config for SOC 2 / HIPAA audit trails |

## Cost Estimate

Region `us-east-1`, default `instance_count = 2` (one AL2023 + one Ubuntu), running 24/7. SSM Patch Manager, Maintenance Windows, Run Command, VPC, subnet, IGW, and route tables incur **no** charge on EC2-based managed instances.

| Resource | Quantity | Monthly cost (USD) |
|----------|----------|--------------------|
| EC2 `t3.micro` on-demand | 2 × 730 h × $0.0104 | $15.18 |
| EBS `gp3` root volume (8 GB) | 2 × 8 GB × $0.08 | $1.28 |
| Public IPv4 address (in-use) | 2 × 730 h × $0.005 | $7.30 |
| SNS (notifications) | Low volume | ~$0.00 |
| SSM Patch Manager / Maintenance Windows | — | $0.00 |
| VPC / Subnet / IGW / Route tables | — | $0.00 |
| **Total** | | **≈ $23.76 / month** |

> Figures are estimates and exclude data transfer and taxes. Stopping the instances between windows, or running them only during patch cycles, reduces EC2, EBS, and public-IP charges to near zero. Verify against the [AWS Pricing Calculator](https://calculator.aws/).

## Destroying the Stack

```bash
terraform destroy
```

No manual pre-steps are required — there is no deletion protection, no load balancer, and no S3/state resources created by this stack. Points to note:

- If `alert_email` was set, the SNS email subscription is removed with the topic; no manual unsubscribe is needed.
- Patch **compliance history** recorded in SSM for the (now-deleted) instance IDs is retained by SSM independently of Terraform and ages out on AWS's schedule — it is not managed by this configuration.
- Any patches already installed on the instances are, of course, discarded along with the instances themselves.

## Frequently Asked Questions

**1. My instances don't show up as patch targets — why?**
The most common cause is the SSM Agent not being `Online`. Confirm with `aws ssm describe-instance-information`. The instance needs the `AmazonSSMManagedInstanceCore` profile (attached here), outbound HTTPS to the SSM endpoints (provided via the IGW), and 3-5 minutes after launch. The second cause is a `Patch Group` tag mismatch — the tag value must exactly match the maintenance-window target filter (Terraform keeps them in sync via `var.patch_groups`).

**2. Patches aren't installing even though the window ran.**
`AWS-RunPatchBaseline` only installs patches that the baseline has **approved**. With `approve_after_days = 7`, a patch is approved 7 days after its release. Run an on-demand `Operation=Scan` and inspect `aws ssm describe-instance-patch-states` — patches in `InstalledPendingReboot` or `Missing` but not yet past the 7-day delay are expected to wait.

**3. Why a public subnet with public IPs instead of private subnets?**
This is a cost-optimized demo footprint: the SSM Agent needs to reach public SSM endpoints, and a public subnet + IGW does that for free. The production pattern is private subnets with three SSM **interface VPC endpoints** (`ssm`, `ssmmessages`, `ec2messages`) plus a NAT gateway (or an S3 gateway endpoint) for OS package repos — see [Security Considerations](#security-considerations).

**4. Ubuntu's baseline looks different from Amazon Linux — is that a bug?**
No. Ubuntu does not expose a `CLASSIFICATION` patch filter, so "install security and important updates" is expressed through Ubuntu's `PRIORITY` (`Required`/`Important`/`Standard`) and `SECTION` keys with `PRODUCT = Ubuntu22.04`. That is the correct API surface for the `UBUNTU` operating system; Amazon Linux 2023 uses `CLASSIFICATION` + `SEVERITY`.

**5. How do I get paged when a patch run fails?**
Set `alert_email` in `terraform.tfvars` and confirm the SNS subscription from the email AWS sends. The maintenance-window task publishes `Failed` and `TimedOut` events at the `Command` level to the `patch-alerts` topic. Point the topic at PagerDuty/Opsgenie in production by adding an HTTPS or Lambda subscription.

**6. Can I patch more than two instances, or add another OS?**
Increase `instance_count` (instances spread round-robin across the groups), or add an entry to `patch_groups` with its own `patch_group`, `os_family`, and `instance_type`. To support a new OS family you must also add a matching `aws_ssm_patch_baseline`, `aws_ssm_patch_group`, maintenance window, target, and task — the two existing OS families are the working template.

**7. Should I enable remote state?**
For a solo demo, local state is fine. For team use, uncomment the `backend "s3"` block in `versions.tf`, pre-create the S3 bucket and a DynamoDB lock table (partition key `LockID`, type String), then re-run `terraform init` to migrate state.

**8. Why are the maintenance windows staggered an hour apart?**
Staggering isolates OS-specific failures and avoids resource contention: the AL2023 wave (02:00 UTC) finishes and its results are visible before the Ubuntu wave (03:00 UTC) starts. If a common change breaks AL2023, you find out before Ubuntu begins patching.
