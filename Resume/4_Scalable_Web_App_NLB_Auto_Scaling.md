# Scalable Web App with NLB & Auto Scaling — Resume Summary

## Project Overview

A horizontally scalable, multi-AZ web tier on AWS provisioned end-to-end with Terraform. An internet-facing **Network Load Balancer** (Layer 4, TCP:80, optional TLS:443) distributes connections across an **Auto Scaling Group** of `t3.medium` EC2 instances running Nginx (or Apache) in private subnets. Two **Simple Scaling** policies driven by CloudWatch CPU alarms add or remove one instance at a time between a floor of 2 and a ceiling of 6, with a 30–70% CPU dead band to prevent oscillation. The VPC spans `us-east-1a` and `us-east-1b` with one NAT Gateway per AZ, the EC2 security group accepts port 80 only from the NLB's security group, instances are reachable only through SSM Session Manager (no bastion), and five CloudWatch alarms fan out to an SNS email topic. A WAFv2 Web ACL with two AWS managed rule groups is provisioned but deliberately left unassociated, because WAFv2 cannot attach to a Layer 4 load balancer. The stack was deployed to account `022499047467` in `us-east-1` (`prod` environment) on 2026-06-08, audited live, and passed a 31-check health script with zero failures.

## Architecture

```
                    ┌──────────────────────────────────────┐
                    │               Internet               │
                    └───────────────────┬──────────────────┘
                                        │
                    ┌───────────────────▼──────────────────┐
                    │          Internet Gateway            │
                    │        igw-0d864a147907cc0bd         │
                    └───────────────────┬──────────────────┘
                                        │
                    ┌───────────────────▼──────────────────┐
                    │     Network Load Balancer (L4)       │
                    │  scalable-webapp-prod-nlb · TCP 80   │
                    │  SG sg-0df61ec01f424402e             │
                    │  cross-zone ON · deletion prot ON    │
                    └──────────┬────────────────┬──────────┘
                               │ TG: TCP/80     │ health: TCP/80
          ┌────────────────────▼──┐        ┌────▼──────────────────┐
          │      us-east-1a       │        │      us-east-1b       │
          │  Public  10.0.1.0/24  │        │  Public  10.0.2.0/24  │
          │  Private 10.0.3.0/24  │        │  Private 10.0.4.0/24  │
          │  ┌─────────────────┐  │        │  ┌─────────────────┐  │
          │  │ EC2 t3.medium   │  │        │  │ EC2 t3.medium   │  │
          │  │ Nginx :80       │  │        │  │ Nginx :80       │  │
          │  │ IMDSv2 · SSM    │  │        │  │ IMDSv2 · SSM    │  │
          │  └────────┬────────┘  │        │  └────────┬────────┘  │
          │           ▼ egress    │        │           ▼ egress    │
          │  ┌─────────────────┐  │        │  ┌─────────────────┐  │
          │  │  NAT GW (1a)    │  │        │  │  NAT GW (1b)    │  │
          │  └─────────────────┘  │        │  └─────────────────┘  │
          └───────────────────────┘        └───────────────────────┘
                 Auto Scaling Group scalable-webapp-prod-asg (min 2 / max 6)
                                        ▲
          ┌─────────────────────────────┴───────────────────────────────┐
          │  CloudWatch: cpu-high (>70%) ──► scale-out +1                │
          │              cpu-low  (<30%) ──► scale-in  −1                │
          │              unhealthy-hosts · healthy-hosts-low ·           │
          │              network-in-high ──► SNS scalable-webapp-prod-alarms │
          │  WAFv2 scalable-webapp-prod-waf (provisioned, not associated) │
          └─────────────────────────────────────────────────────────────┘
```

## Technology Stack

| Layer | Technology | Purpose |
|---|---|---|
| **Networking** | Amazon VPC `10.0.0.0/16` via `terraform-aws-modules/vpc/aws ~> 5.0` | 2 public + 2 private subnets across 2 AZs, IGW, one NAT Gateway per AZ |
| **Load balancing** | Network Load Balancer (internet-facing, cross-zone) | TCP:80 listener; TLS:443 listener created only when `acm_certificate_arn` is set (`ELBSecurityPolicy-TLS13-1-2-2021-06`) |
| **Compute** | Amazon EC2 `t3.medium` via Launch Template | Nginx or Apache installed by user data; IMDSv2 required; detailed monitoring on |
| **Scaling** | EC2 Auto Scaling Group + 2 Simple Scaling policies | `health_check_type = "ELB"`, 300 s grace, rolling instance refresh at 50% min healthy |
| **Monitoring** | Amazon CloudWatch (5 metric alarms) | CPU high/low drive scaling; host-count and `ProcessedBytes` alarms notify |
| **Alerting** | Amazon SNS (email subscription) | Alarm notifications to the operations mailbox |
| **Access** | IAM role + instance profile, `AmazonSSMManagedInstanceCore` | Session Manager access with no bastion or SSH ingress |
| **Edge security** | AWS WAFv2 Web ACL | `AWSManagedRulesCommonRuleSet` + `AWSManagedRulesKnownBadInputsRuleSet`, ready for a future ALB |
| **IaC** | Terraform `>= 1.5`, AWS provider `~> 5.0`, Random `~> 3.0` | `default_tags` on every resource; S3 backend block authored but commented out |
| **Automation** | Bash (`deploy.sh`, `health_check.sh`) | Equivalent AWS CLI deployment path and a 15-section live health check |

## Key Achievements

- **Deployed and verified a multi-AZ Layer 4 web tier**: 33 Terraform-managed resources (plus VPC module sub-resources) confirmed present in live AWS, with 2/2 targets healthy and one instance per AZ.
- **Security groups wired by identity, not CIDR**: the EC2 SG accepts TCP:80 only from `sg-0df61ec01f424402e` (the NLB SG), so instances in private subnets can't be reached from the internet.
- **Diagnosed a silent NLB health-check failure**: the NLB had no security group attached, so the EC2 SG rule that referenced it matched no traffic. Attaching `security_groups` to `aws_lb.web` brought both targets healthy within ~90 s.
- **Self-healing confirmed in live scaling history**: the ASG terminated and replaced instances that failed ELB health checks while user data was still installing Nginx, then settled at a stable 2 InService.
- **Oscillation-resistant scaling**: a 30–70% CPU dead band, 2 × 60 s evaluation periods, and a 300 s cooldown mean a sustained spike adds one instance roughly every 7 minutes up to `asg_max_size = 6`.
- **HA egress**: one NAT Gateway per AZ with AZ-local private route tables, so losing one AZ does not cut the other AZ's outbound path.
- **Hardened by default**: IMDSv2 enforced (`HttpTokens = required`), no public IPs on instances, NLB deletion protection on in `prod`, and SSM access instead of a bastion host.
- **Two deployment paths and automated verification**: Terraform plus an equivalent 9-section AWS CLI `deploy.sh`, and a `health_check.sh` that scored **31 PASS / 0 WARN / 0 FAIL** against the live stack.

## Infrastructure Components

| Component | Count | Details |
|---|---|---|
| **VPC + IGW** | 2 | `vpc-056ede48d2f4bc025` (`10.0.0.0/16`), `igw-0d864a147907cc0bd`; DNS hostnames and support enabled |
| **Subnets** | 4 | Public `10.0.1.0/24` / `10.0.2.0/24` (NLB); private `10.0.3.0/24` / `10.0.4.0/24` (EC2) |
| **NAT Gateways + EIPs** | 2 + 2 | `nat-07e9c73b459efdc49` (1a), `nat-07a86629dcf8ab8e9` (1b) |
| **Route tables** | 3 | 1 public (→ IGW) + 2 private, each routing `0.0.0.0/0` to its AZ-local NAT |
| **Security groups** | 2 | `scalable-webapp-prod-nlb-sg` (80/443 from `0.0.0.0/0`), `scalable-webapp-prod-ec2-sg` (80 from NLB SG only) |
| **Launch Template** | 1 | `lt-097e8ffc95815d2a6` (v2), `t3.medium`, IMDSv2, instance + volume tag specifications |
| **Network Load Balancer** | 1 | `scalable-webapp-prod-nlb`, TCP:80 listener (TLS:443 conditional) |
| **Target Group** | 1 | `scalable-webapp-prod-tg`, TCP/80, instance targets, 30 s interval, 3/3 thresholds |
| **Auto Scaling Group** | 1 | `scalable-webapp-prod-asg`, min 2 / desired 2 / max 6, ELB health checks |
| **Scaling policies** | 2 | `scale-out` (+1, 300 s cooldown), `scale-in` (−1, 300 s cooldown) |
| **CloudWatch alarms** | 5 | `cpu-high`, `cpu-low`, `unhealthy-hosts`, `healthy-hosts-low`, `network-in-high` |
| **SNS** | 2 | `scalable-webapp-prod-alarms` topic + confirmed email subscription |
| **IAM** | 3 | `scalable-webapp-prod-ec2-role`, instance profile, `AmazonSSMManagedInstanceCore` attachment |
| **WAFv2 Web ACL** | 1 | `scalable-webapp-prod-waf`, 2 managed rule groups, not associated (NLB is Layer 4) |
| **Total (audited)** | 33 | Terraform-managed resources confirmed live, plus VPC module sub-resources |

## Deployment Issues Diagnosed & Resolved

| Issue | Root cause | Fix |
|---|---|---|
| ASG creation failed with `Invalid id: "ami-00fa360e28f425da0 "` | Trailing space pasted into `ami_id` in `prod.tfvars`; Auto Scaling validates the AMI when the ASG is created | Removed the space; Terraform updated the Launch Template in place (v1 → v2) and created the ASG. Prevention: `grep ami_id prod.tfvars \| cat -A` |
| `ValidationException: Resource ARN must be for an Application Load Balancer` | `aws_wafv2_web_acl_association` targeted the NLB; WAFv2 only attaches to Layer 7 resources | Removed the association; kept the `aws_wafv2_web_acl` and exported its ARN for a future ALB |
| Both targets `Target.FailedHealthChecks` while Nginx was `active` | `aws_lb` had no `security_groups`, so the NLB's ENIs weren't members of the NLB SG and the EC2 SG rule referencing it matched nothing | Added `security_groups = [aws_security_group.nlb.id]`. This forces NLB replacement, so deletion protection was disabled first. Both targets went healthy within ~90 s |
| `health_check.sh` reported `[FAIL] No CloudWatch alarms found` | `--alarm-names` lookup failed on any unresolved name, and BSD `sed` on macOS didn't treat `\s` as whitespace, producing prefix `scalable-webapp- prod` | Switched to `--alarm-name-prefix`, replaced `\s` with `[[:space:]]` plus an explicit leading-space strip, and made `cpu-low` informational |
| Early instances terminated by the ASG on first boot | ELB health checks ran while user data was still installing Nginx | Expected behaviour. The ASG replaced them automatically and the replacements stayed healthy (300 s grace period) |

## Test Results

Live audit (`Result.md`, 2026-06-08) and `Automation/health_check.sh` run against the deployed stack:

| Check | Scope | Result |
|---|---|---|
| `health_check.sh` (sections 0–14) | Prerequisites → NLB → listeners → TG → ASG → LT → SG → IAM → EC2 → alarms → policies → NAT → VPC → SNS → HTTP endpoint | **31 PASS / 0 WARN / 0 FAIL** |
| Terraform-managed resources | All resources vs. live AWS | 33 confirmed present |
| NLB state | `scalable-webapp-prod-nlb` | `active`, cross-zone ON, deletion protection ON |
| Target health | `scalable-webapp-prod-tg` | 2 / 2 healthy on TCP:80 |
| ASG capacity / spread | `scalable-webapp-prod-asg` | 2 InService, 1 per AZ |
| HTTP endpoint | `http://<nlb_dns_name>` | HTTP 200 from Nginx (screenshot in `screenshots/webapp-live.png`) |
| SNS subscription | Email endpoint | Confirmed |
| SSM access | EC2 role policy | `AmazonSSMManagedInstanceCore` attached |
| Alarm `cpu-low` | CPU ~0.017% at idle | ALARM (expected; `MinSize = 2` blocks scale-in) |
| Alarm `network-in-high` | `ProcessedBytes` | INSUFFICIENT_DATA (normal for a new deployment) |

## Quick Start

```bash
# 1. Enter the project directory
cd "Scalable Web App with NLB & Auto Scaling"

# 2. Copy the example vars file and set ami_id, key_pair_name, alarm_email
cp prod.tfvars.example prod.tfvars

# 3. Initialise providers and the VPC module
terraform init

# 4. Preview, then deploy (approximately 5-7 minutes)
terraform plan  -var-file=prod.tfvars
terraform apply -var-file=prod.tfvars

# 5. Hit the NLB and run the live health check
curl http://$(terraform output -raw nlb_dns_name)
./Automation/health_check.sh
```

> Allow 3–5 minutes after `apply` for instances to pass NLB health checks. Alternative path: set `AMI_ID`, `KEY_PAIR_NAME`, `ALARM_EMAIL` at the top of `Automation/deploy.sh` and run it (9 sections).

## Cost Estimate

`us-east-1` on-demand pricing from the project README (approximate, baseline of 2 instances, no traffic data):

| Resource | Quantity | Monthly (USD) |
|---|---|---|
| EC2 `t3.medium` | 2 (desired) × $0.0416/hr | ~$61 |
| Network Load Balancer | 1 × $0.008/hr + LCU | ~$6 base |
| NAT Gateway | 2 (one per AZ) × $0.045/hr | ~$66 (idle) |
| WAFv2 Web ACL | 1 | ~$5 |
| CloudWatch alarms | 5 × $0.10 | ~$0.50 |
| SNS (email) | 1 topic | ~$0 |
| **Total (baseline)** | | **~$138 / month** |

> The two NAT Gateways cost more than the EC2 fleet at idle. At scale, NAT data processing ($0.045/GB) can exceed EC2 cost too. S3/SSM VPC endpoints are the main lever for cutting it. Cost grows with each instance the ASG adds (up to 6).

## Security Posture

| Topic | Posture |
|---|---|
| Instance exposure | Private subnets, no public IPs; TCP:80 inbound from the NLB SG only |
| NLB exposure | 80/443 open to `0.0.0.0/0`, which a public web tier needs |
| Shell access | SSM Session Manager via `AmazonSSMManagedInstanceCore`; no SSH ingress rule, no bastion |
| Key pair | Attached to the Launch Template for emergency use only; recommended to remove if SSM is the sole path |
| Instance metadata | IMDSv2 required (`HttpTokens = required`); user data fetches ID/AZ with IMDSv2 tokens |
| WAF | Web ACL provisioned but unassociated; attach to an ALB placed in front of the NLB for Layer 7 inspection |
| Transit encryption | HTTP by default; TLS:443 with `ELBSecurityPolicy-TLS13-1-2-2021-06` once an ACM cert is supplied |
| Deletion safety | NLB deletion protection enabled when `environment = "prod"` |
| State | Local backend by default; S3 + DynamoDB locking block authored in `provider.tf`, commented out |

## Project Structure

```
Scalable Web App with NLB & Auto Scaling/
├── main.tf                  # VPC module, SGs, IAM, launch template, NLB, TG, listeners,
│                            #   ASG, scaling policies, 5 alarms, SNS, WAFv2
├── variables.tf             # Input variables (web_server validated: nginx | apache)
├── outputs.tf               # NLB DNS/ARN, ASG, LT, VPC/subnets, SG, IAM, SNS, TG, WAF
├── provider.tf              # Terraform >= 1.5, AWS ~> 5.0, Random ~> 3.0, default_tags,
│                            #   commented-out S3 backend
├── prod.tfvars.example      # Copy to prod.tfvars and fill in required values
├── README.md                # Full documentation (14 sections + deployment issues)
├── Result.md                # Live audit results (2026-06-08)
├── Automation/
│   ├── .gitignore           # Excludes generated reports/logs
│   ├── deploy.sh            # Equivalent AWS CLI deployment (9 sections + cleanup)
│   └── health_check.sh      # 15-section live architecture health check
└── screenshots/
    ├── webapp-live.png              # HTTP 200 via the NLB
    ├── health-check-1.png           # Sections 0-7
    ├── health-check-2.png           # Sections 8-14
    └── health-check-summary.png     # PASS 31 / WARN 0 / FAIL 0
```

## Key Learnings & Technical Decisions

**NLB security groups are opt-in, and a missing one fails silently.** Security groups on Network Load Balancers are optional. If `aws_lb` doesn't set `security_groups`, the NLB SG still exists but isn't attached to the NLB's ENIs, so an EC2 rule that references it matches nothing, health-check packets included. Nginx was running, the SG rule looked correct, and both targets still failed. Adding the argument forces NLB replacement, which meant disabling deletion protection before the fix could apply.

**Layer 4 vs Layer 7 decides which features exist.** The NLB was chosen for TCP pass-through, native client source-IP preservation, and static per-AZ IPs. The trade-off is no path or host routing, no HTTP redirects, and no WAF, because WAFv2 only associates with Layer 7 resources. Rather than drop the WAF, the Web ACL stays provisioned and its ARN is exported, so it's ready if an ALB is ever placed in front.

**Simple Scaling with a dead band over Target Tracking.** Target Tracking converges on one CPU value and reacts in both directions to any deviation. Two Simple Scaling policies with a 30–70% dead band, 2 × 60 s evaluation, and a 300 s cooldown trade some spike responsiveness for stability. The floor of 2 guarantees multi-AZ coverage even though `cpu-low` sits in ALARM whenever the fleet is idle.

**`health_check_type = "ELB"` makes the ASG trust the load balancer.** With EC2 status checks, an instance counts as healthy as soon as it boots, even before the web server is up. ELB health checks plus a 300 s grace period caused the early replacements seen in the scaling history. They also mean a serving but broken instance gets replaced, which is the behaviour a web tier needs.

## What I'd Do Differently

- **Enable the S3 + DynamoDB remote backend from day one.** The block is authored but commented out. Local state is a risk for anything shared.
- **Put an ALB in front, or switch to one**, if Layer 7 protection matters, and associate the already-provisioned WAF ACL with it.
- **Add S3 and SSM VPC endpoints** to cut NAT Gateway data processing, the largest variable cost.
- **Drop the EC2 key pair** from the Launch Template, since SSM Session Manager is the only access path in use.
- **Validate `.tfvars` inputs** (e.g. a regex on `ami_id`) so a trailing space fails at `plan` rather than at ASG creation.
- **Add a load test to the automated checks.** The README documents Apache Bench as a prerequisite, but no scale-out run under load is recorded in the audit.

## Summary

This project delivers a production-shaped, multi-AZ web tier on AWS: an internet-facing Network Load Balancer in front of a self-healing Auto Scaling Group of Nginx instances in private subnets, AZ-local NAT Gateways, security-group-identity access control, IMDSv2, SSM-only administration, CPU-driven Simple Scaling with a dead band, and five CloudWatch alarms routed through SNS, all in Terraform with an equivalent AWS CLI path. It was deployed to `us-east-1` on 2026-06-08, where **33 Terraform-managed resources** were confirmed live, **2/2 targets were healthy across 2 AZs**, and the automated health check scored **31 PASS / 0 WARN / 0 FAIL**. Five deployment issues were diagnosed and fixed along the way, from a trailing-space AMI ID to a missing NLB security group that silently dropped every health check.
