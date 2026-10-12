# Multi-Tier Web App Deployment — Resume Summary

## Project Overview

A classic three-tier web application on AWS, provisioned with Terraform in `us-east-1` under the project prefix `multitier-webapp`. The stack builds its own 2-AZ VPC (`10.0.0.0/16`) with public and private subnets, one NAT Gateway per AZ, and per-AZ private route tables. An internet-facing Application Load Balancer in the public subnets forwards HTTP:80 to an EC2 Auto Scaling Group (`t3.medium`, Amazon Linux 2, Apache + PHP) in the private subnets. The ASG scales between 1 and 4 instances on CloudWatch CPU alarms (scale out above 60%, scale in below 40%). The web tier reads from a private, encrypted, Multi-AZ **RDS MySQL 8.0** instance (`multitier-webapp-mysql`, `db.t3.medium`) that accepts `3306` only from the web-tier security group. A `t3.micro` bastion host in a public subnet provides SSH into the private tier. Each web instance renders a PHP page that connects to RDS and lists rows from an `appdb.users` table. The stack was deployed and audited on **9 June 2026**: `RESULT.md` records the ALB returning HTTP 200 with 1/1 healthy targets and RDS `available` with Multi-AZ, encryption, and deletion protection enabled. An AWS CLI script (`deploy.sh`) and a folder of Bash operations scripts (`Automation/`) sit alongside the Terraform.

## Architecture

```
                                   Internet
                                      │ HTTP :80              SSH :22
                                      ▼                          │
                        Internet Gateway  igw-0ad77c9c663c0c376  │
 ┌────────────────────────────────────┼──────────────────────────┼─────────────┐
 │  VPC  vpc-0b4866766bf728184   10.0.0.0/16   (us-east-1a / us-east-1b)       │
 │                                    │                          │             │
 │  ┌──── Public subnets ─────────────▼──────────────────────────▼──────────┐  │
 │  │  ALB multitier-webapp-alb (ALB-SG: 80/443 from 0.0.0.0/0)            │  │
 │  │  NAT GW A (1a) + EIP     NAT GW B (1b) + EIP     Bastion t3.micro    │  │
 │  │                                     22 from var.allowed_ssh_cidr     │  │
 │  └───────┬──────────────────────────┬───────────────────────┬───────────┘  │
 │          │ TG HTTP:80  GET /health   │ 0.0.0.0/0 egress      │ SSH 22       │
 │          ▼                           ▼  (per-AZ private RT)  ▼              │
 │  ┌──── Private subnets ──────────────────────────────────────────────────┐  │
 │  │  Auto Scaling Group  min 1 / desired 1 (deployed) / max 4            │  │
 │  │  Launch template: Amazon Linux 2 · t3.medium · httpd + PHP           │  │
 │  │  WebApp-SG: 80 from ALB-SG · 22 from Bastion-SG                       │  │
 │  │  IAM profile: AmazonSSMManagedInstanceCore · detailed monitoring     │  │
 │  └──────────────────────────────────┬────────────────────────────────────┘  │
 │                                     │ tcp/3306                             │
 │  ┌──────────────────────────────────▼────────────────────────────────────┐  │
 │  │  RDS MySQL 8.0.45  multitier-webapp-mysql  db.t3.medium  20 GB gp2    │  │
 │  │  Multi-AZ · encrypted · private · RDS-SG: 3306 from WebApp-SG only   │  │
 │  │  7-day backups · deletion protection · error/general/slowquery logs  │  │
 │  └───────────────────────────────────────────────────────────────────────┘  │
 └──────────────────────────────────────────────────────────────────────────────┘
          ▲
          │  CPUUtilization (AWS/EC2, per ASG)
 ┌────────┴───────────────────────────────────────────────────────────────────┐
 │ CloudWatch  cpu-high > 60% (2×60 s)  ──► scale-out +1                       │
 │             cpu-low  < 40% (2×300 s) ──► scale-in  −1                       │
 │             log group /aws/ec2/multitier-webapp (7-day retention)          │
 └────────────────────────────────────────────────────────────────────────────┘
```

## Technology Stack

| Layer | Technology | Purpose |
|---|---|---|
| **Networking** | Amazon VPC (`10.0.0.0/16`), IGW, 2 NAT Gateways + 2 EIPs | 2 public + 2 private subnets across 2 AZs; per-AZ private route tables for NAT redundancy |
| **Load balancing** | Application Load Balancer + target group (`app-` prefix) | HTTP:80 listener; `GET /health` probe every 30 s, 2/3 thresholds, matcher `200` |
| **Compute** | Amazon EC2 Auto Scaling + launch template | `t3.medium` Amazon Linux 2 web tier in private subnets; ELB health checks with a 300 s grace period |
| **Web app** | Apache `httpd` + PHP (`mysqli`) via `user_data.sh` | `index.php` queries `appdb.users`; static `/health` file answers the ALB probe |
| **Database** | Amazon RDS MySQL 8.0 (`db.t3.medium`, Multi-AZ, 20 GB gp2) | Private, encrypted, 7-day backups, CloudWatch log exports |
| **Access** | Bastion host (`t3.micro`) + SSM instance profile | SSH jump into the private tier; `AmazonSSMManagedInstanceCore` on web instances |
| **Scaling / monitoring** | CloudWatch metric alarms + simple scaling policies; log group | ±1 instance per event, 300 s cooldown; `/aws/ec2/multitier-webapp` (7-day retention) |
| **IaC** | Terraform `>= 1.0` (aws `~> 5.0`), `default_tags` | 37 managed resources; S3 backend stub provided but commented out |
| **Alternative deploy** | AWS CLI (`deploy.sh`) | Imperative equivalent of the Terraform stack |
| **Operations** | Bash (`Automation/`) + AWS CLI + `jq` | Health check, quick status, connectivity, scaling report, and cost analysis scripts |

## Key Achievements

- **Complete 2-AZ, three-tier network from scratch** — VPC, 4 subnets, IGW, and **one NAT Gateway per AZ** with separate private route tables, so losing one AZ does not cut the other AZ's egress.
- **Security-group chaining between tiers** — `ALB-SG → WebApp-SG (80) → RDS-SG (3306)` and `Bastion-SG → WebApp-SG (22)` are all expressed as SG references, not CIDRs.
- **Encrypted Multi-AZ database with safe-delete defaults** — `multi_az = true`, `storage_encrypted = true`, `publicly_accessible = false`, `deletion_protection = true`, 7-day backups, `copy_tags_to_snapshot`, and error/general/slowquery log exports. `RESULT.md` records all of these live.
- **CPU-driven elasticity with a dead band** — scale-out at >60% (2×60 s) and scale-in at <40% (2×300 s), each ±1 instance with a 300 s cooldown, to avoid flapping.
- **App tier talks to the data tier end-to-end** — the launch template renders `user_data.sh` with the live RDS endpoint, so each instance serves a PHP page that connects to MySQL and lists `users` rows.
- **Verified live** — 10-point verification on 2026-06-09: ALB HTTP 200, 1/1 healthy targets, ASG in both AZs, RDS Multi-AZ and encrypted, web page served through the ALB.
- **Operational tooling beyond IaC** — five Bash automation scripts (full health check, quick status, connectivity, scaling report, cost analysis) plus a full AWS CLI deployment path.

## Infrastructure Components

Counts are Terraform resource blocks after `count` expansion (37 managed resources). With the 2 data sources (`aws_ami`, `aws_availability_zones`) this gives 39 state entries, which matches the "39 managed resources" the health check reported. The headline in `RESULT.md` says 42.

| Component | Count | Details |
|---|---|---|
| **VPC + IGW** | 2 | `vpc-0b4866766bf728184` (DNS hostnames + support on), `igw-0ad77c9c663c0c376` |
| **Subnets** | 4 | 2 public (`map_public_ip_on_launch`) + 2 private, one of each per AZ |
| **NAT Gateways + EIPs** | 4 | `nat-0b1b9884040ef525f` (1a), `nat-0356ae06f8c341844` (1b), each with an EIP |
| **Route tables + associations** | 7 | 1 public RT (→ IGW) + 2 private RTs (→ per-AZ NAT) + 4 associations |
| **Security groups** | 4 | ALB (`sg-038f779205f269ae9`), web (`sg-0bd01cf8d4a7175dc`), RDS (`sg-08c07dc0ea119991b`), bastion (`sg-0ae819e6a9840a033`) |
| **IAM** | 3 | `multitier-webapp-ec2-role` + `AmazonSSMManagedInstanceCore` attachment + `multitier-webapp-ec2-profile` |
| **Bastion host** | 1 | `i-0e2318d36aa053bfc`, `t3.micro`, public subnet 1a |
| **Launch template** | 1 | `lt-0f9a84a6a2145ac59`; Amazon Linux 2, `t3.medium`, detailed monitoring, `create_before_destroy` |
| **ALB + target group + listener** | 3 | `multitier-webapp-alb`, target group `app-20260609083540939900000002`, HTTP:80 forward |
| **Auto Scaling Group** | 1 | `multitier-webapp-asg-20260609085459110200000003`, ELB health checks, 300 s grace |
| **Scaling policies + alarms** | 4 | `multitier-webapp-scale-out` / `-scale-in` (±1, 300 s cooldown) + `cpu-high` / `cpu-low` alarms |
| **RDS** | 2 | `aws_db_subnet_group` + `aws_db_instance` (`multitier-webapp-mysql`, db `appdb`, MySQL 8.0.45 live) |
| **CloudWatch log group** | 1 | `/aws/ec2/multitier-webapp`, 7-day retention |

> Subnet CIDRs come from `cidrsubnet(var.vpc_cidr, 2, n)`, which gives **/18** blocks (public `10.0.0.0/18`, `10.0.64.0/18`; private `10.0.128.0/18`, `10.0.192.0/18`). The live web instance's private IP `10.0.207.40` confirms this. The README and `RESULT.md` list them as `/24`.

## Deployment Issues Diagnosed & Resolved

Sourced from `Automation/AWS_RESOURCE_INVENTORY.md` (mid-deployment snapshot), `RESULT.md`, and `DATABASE_GUIDE.md`.

| Issue | Root cause | Fix |
|---|---|---|
| Inventory snapshot showed the web tier missing: no launch template, ASG, instances, or CloudWatch alarms. The target group had 0 targets, so the ALB would return 502/503 | The launch template's `templatefile()` consumes `aws_db_instance.main.endpoint`, so the whole web tier (LT → ASG → policies → alarms) waits on RDS. RDS was still `modifying` (pending `MultiAZ: true`) when the snapshot was taken | Let RDS finish Multi-AZ provisioning (15 min 26 s recorded) and complete the apply. `RESULT.md` then shows the LT, ASG, both policies, both alarms, and 1/1 healthy targets |
| RDS reported `modifying` during deployment | Multi-AZ standby still being created (pending change `MultiAZ: true`) | Waited for `available` before testing DB connectivity. The final audit shows Multi-AZ enabled |
| `health_check.sh` overall status came back **FAIL** | The `multitier-webapp-cpu-low` alarm was in `ALARM` because idle CPU (~0.006%) is below the 40% scale-in threshold, and the script counts any alarm in `ALARM` as a failure | Diagnosed as expected idle behaviour, not a fault. Recorded as a WARNING in the verification summary |
| Web page needed live database content, not static HTML | The original user data served only a static page and had no DB credentials | Reworked `user_data.sh` to install PHP + `mysqli` and render `index.php` with the RDS endpoint and password via `templatefile()`, then redeployed the launch template (`DATABASE_GUIDE.md`) |

## Test Results

From the 2026-06-09 audit in `RESULT.md`, produced by `Automation/health_check.sh` plus browser verification.

| Check | Result | Evidence |
|---|---|---|
| AWS credentials | PASS | Account `022499047467` authenticated |
| Terraform state | PASS | 39 state entries |
| VPC & networking | PASS | 4 active subnets across 2 AZs, 2 NAT Gateways available |
| Security groups | PASS | ALB → web (80), bastion → web (22), web → RDS (3306) |
| ALB health | PASS | HTTP 200; target group 1/1 healthy |
| ASG capacity | PASS | Min 1 / desired 1 / max 4, spans `us-east-1a` + `us-east-1b` |
| EC2 instances | PASS | Bastion `i-0e2318d36aa053bfc` running; web `i-0cc30b0b6de73b745` InService (`us-east-1b`) |
| RDS database | PASS | MySQL 8.0.45, `available`, Multi-AZ, encrypted, backups on, deletion protection on |
| Web application | PASS | Page served via ALB DNS showing instance, AZ, and RDS endpoint |
| CloudWatch | WARNING | `cpu-high` OK; `cpu-low` in ALARM at idle (expected) |
| **Overall** | **9 PASS / 1 WARNING** | Stack operational |

> No automated test suite (quick/comprehensive/critical scripts) exists in this project folder. The checks above are the recorded verification.

## Quick Start

```bash
# 1. Enter the project directory
cd "Multi-Tier Web App Deployment"

# 2. Create terraform.tfvars (git-ignored) with at least:
#    key_pair_name    = "<existing-key-pair>"
#    db_password      = "<strong-password>"
#    allowed_ssh_cidr = "<your-ip>/32"

# 3. Initialise, review, and apply
terraform init
terraform plan
terraform apply

# 4. Read the entry points
terraform output alb_dns_name
terraform output bastion_public_ip
terraform output rds_endpoint

# 5. Verify the stack
bash Automation/quick_status.sh
bash Automation/health_check.sh
```

> Allow ~22 minutes for a full deploy (RDS Multi-AZ alone took 15 min 26 s), then 5-10 minutes for instances to register and pass `/health` checks.

## Cost Estimate

From `RESULT.md` (`us-east-1`, on-demand, web tier averaged at 2.5 instances).

| Resource | Quantity | Monthly (USD) |
|---|---|---|
| EC2 `t3.micro` (bastion) | 1 | $5.83 |
| EC2 `t3.medium` (web tier) | 2-4 (avg 2.5) | $87.50 |
| Application Load Balancer (+ data processing) | 1 | $20.00 |
| NAT Gateway | 2 | $32.00 |
| RDS `db.t3.medium` Multi-AZ | 1 | $70.00 |
| RDS storage (gp2) | 20 GB | $2.30 |
| CloudWatch | logs + 2 alarms | $5.00 |
| **Total** | | **~$222.63 / month** |

> The README's own table gives ~$165-200/month, and the root portfolio README lists ~$280/month. The two NAT Gateways and Multi-AZ RDS are the fixed-cost drivers. See the [AWS Pricing Calculator](https://calculator.aws/).

## Security Posture

| Topic | Posture |
|---|---|
| Tier isolation | Web and DB tiers in private subnets; SG-reference chain ALB → web (80) → RDS (3306) |
| Database exposure | `publicly_accessible = false`; `3306` only from `WebApp-SG` |
| Encryption at rest | RDS `storage_encrypted = true` (AWS-managed KMS key) |
| Encryption in transit | Not enforced. The ALB listens on HTTP:80 only; `443` is open on ALB-SG but has no HTTPS listener or certificate |
| SSH | Bastion ingress `22` from `allowed_ssh_cidr`, default `0.0.0.0/0`; web tier accepts `22` only from `Bastion-SG` |
| DB credentials | `db_password` is a `sensitive` variable but is rendered into the launch template user data (`index.php`) and stored in local state. `DATABASE_GUIDE.md` flags this and recommends Secrets Manager or IAM DB auth |
| IAM | EC2 role with `AmazonSSMManagedInstanceCore` only, which enables Session Manager as an alternative to SSH |
| Data safety | 7-day automated backups, `deletion_protection = true`, final snapshot on destroy |
| State | Local backend by default; S3 + DynamoDB backend block provided but commented out |
| Not configured | WAF, VPC Flow Logs, HTTPS redirect, IMDSv2 enforcement |

## Project Structure

```
Multi-Tier Web App Deployment/
├── README.md                     # Full documentation (14 sections)
├── RESULT.md                     # Live deployment audit (2026-06-09) + verification summary
├── DATABASE_GUIDE.md             # PHP/RDS integration, schema, troubleshooting, security notes
├── provider.tf                   # Terraform/AWS provider, default_tags, commented S3 backend
├── variables.tf                  # 17 inputs (key_pair_name validated, db_password sensitive)
├── main.tf                       # VPC, subnets, NAT, SGs, IAM, bastion, LT, ALB, ASG, alarms, RDS, logs
├── outputs.tf                    # VPC/ALB/bastion/ASG/RDS/TG/subnet/log-group outputs + summary
├── user_data.sh                  # httpd + PHP install, /health file, index.php querying RDS
├── deploy.sh                     # AWS CLI equivalent deployment script
├── .gitignore                    # State, tfvars, keys, reports excluded
└── Automation/
    ├── Automation_README.md      # Script guide
    ├── AWS_RESOURCE_INVENTORY.md # Mid-deployment inventory (web tier missing, RDS modifying)
    ├── health_check.sh           # Full health check across all tiers
    ├── quick_status.sh           # Fast ALB / ASG / RDS status
    ├── test_connectivity.sh      # HTTP status, latency, DNS, /health checks
    ├── scaling_report.sh         # Scaling activity + CPU trend analysis
    ├── cost_analysis.sh          # Monthly cost estimate from live config
    └── .gitignore                # Excludes generated reports/
```

## Key Learnings & Technical Decisions

**Resource references create deployment ordering, sometimes on purpose.** Passing `aws_db_instance.main.endpoint` into the launch template's user data made the web tier depend on the database. Terraform correctly held back the launch template, ASG, scaling policies, and alarms until RDS existed, which is why a mid-deploy inventory showed an ALB with no targets. The practical lesson is to expect the slowest resource (Multi-AZ RDS, ~15 min) to gate everything downstream, and to read a partial inventory in that light.

**One NAT Gateway per AZ is the price of real multi-AZ.** A single shared NAT is cheaper but makes one AZ a dependency of the other's egress. Two NAT Gateways with per-AZ private route tables cost about $32/month more and keep each AZ independent for package installs and outbound calls.

**A dead band beats a single target for simple CPU scaling.** Separate scale-out (>60%, 2×60 s) and scale-in (<40%, 2×300 s) alarms with ±1 steps and 300 s cooldowns give fast growth and slow shrinkage. The side effect is that `cpu-low` sits in `ALARM` whenever the fleet is idle. That is expected, but monitoring scripts need to treat it as a warning rather than a failure.

**Chain security groups, don't enumerate CIDRs.** Each tier trusts only the SG of the tier in front of it. This documents the intended traffic path and keeps working as instances scale in and out.

## What I'd Do Differently

- **Stop passing the DB password through user data.** Put it in Secrets Manager (or use IAM DB auth) and have instances fetch it at boot with a scoped role.
- **Terminate TLS at the ALB.** Add an ACM certificate, an HTTPS:443 listener, and an HTTP→HTTPS redirect. The `443` ingress rule is already there but nothing uses it.
- **Remove the bastion.** The instance profile already grants SSM, so Session Manager can replace SSH and the open `22/0.0.0.0/0` default.
- **Fix the final-snapshot name.** `formatdate(..., timestamp())` in `final_snapshot_identifier` changes on every plan and causes a perpetual diff. A static or `random_id` suffix would avoid this.
- **Enable the remote backend** (S3 + DynamoDB) and keep docs in sync with code (the `/18` vs `/24` subnet mismatch; 39 vs 42 resource counts).
- **Add a repeatable test suite** (quick/critical scripts or a load test) so results are captured on every deploy, not just in one audit.

## Summary

This project builds a complete, highly available three-tier web application in 37 Terraform resources: a 2-AZ VPC with per-AZ NAT Gateways, an internet-facing ALB, a CPU-scaled EC2 Auto Scaling Group running Apache + PHP in private subnets, a bastion host, and an encrypted, deletion-protected Multi-AZ RDS MySQL 8.0 database reachable only from the web tier's security group. It was deployed to `us-east-1` on 9 June 2026. The recorded verification shows 9 PASS and 1 expected WARNING: HTTP 200 through the ALB, 1/1 healthy targets, and RDS Multi-AZ with encryption and backups. The mid-deployment "missing web tier" snapshot was traced to the launch template's intentional dependency on the RDS endpoint. Clear next steps are to move the DB password out of user data, add HTTPS, and replace the bastion with Session Manager.
