# Scalable Web App (NLB+ASG+RDS)

An infrastructure-as-code project that defines a horizontally scalable web
application on AWS using Terraform. A Network Load Balancer (NLB) accepts HTTPS
on port 443 only, ends TLS with an ACM certificate for a hostname held in
Cloudflare DNS, and forwards the traffic at Layer 4 to EC2 instances running
Nginx or Apache on Amazon Linux 2023; the Auto Scaling Group automatically adds
or removes instances in response to CPU load. Port 80 is closed. A Multi-AZ RDS
for PostgreSQL instance (a primary plus a synchronous standby) sits in dedicated
database subnets, and each instance checks once at boot that it can reach it.
All instances live in private subnets — reachable only through the NLB and via
SSM Session Manager. A WAFv2 web ACL is provisioned but not associated, because
WAFv2 cannot attach to an NLB.

> **Status (2026-10-07): authored and validate-clean, not deployed.** This
> README describes the HTTPS and RDS revision of the stack. `terraform apply`
> has not been run for it. `Result.md` and the files in `screenshots/` record
> the June 2026 deployment of the previous architecture (HTTP only on TCP 80,
> no database tier).
>
> Checks run on this revision: `terraform fmt -check -recursive`,
> `terraform init` and `terraform validate` pass, and `terraform plan` against
> an empty state with a placeholder Cloudflare token reports
> `Plan: 57 to add, 0 to change, 0 to destroy.` The user data script passes
> `bash -n` and `shellcheck` and was exercised against stub commands on a
> workstation only.
>
> Not run: `terraform apply`, the user data on a real instance, the database
> check against a real database, certificate issuance, the Cloudflare records,
> a plan with a real Cloudflare token, and a check in the account that the TLS
> policy name exists (it was confirmed in AWS documentation only).

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Networking & Routing](#networking--routing)
3. [Component Details](#component-details)
4. [Directory Structure](#directory-structure)
5. [Prerequisites](#prerequisites)
6. [Quick Start](#quick-start)
7. [Input Variables](#input-variables)
8. [Outputs](#outputs)
9. [Scaling Behaviour](#scaling-behaviour)
10. [Tagging Strategy](#tagging-strategy)
11. [Security Considerations](#security-considerations)
12. [Cost Estimate](#cost-estimate)
13. [Destroying the Stack](#destroying-the-stack)
14. [Frequently Asked Questions](#frequently-asked-questions)
15. [Deployment Issues Encountered (June 2026)](#deployment-issues-encountered-june-2026)

---

## Architecture Overview

```
                    ┌─────────────────────────────────────┐
                    │    Browser: https://<domain_name>   │
                    └──────────────────┬──────────────────┘
                                       │  Cloudflare DNS (DNS only):
                                       │  CNAME <domain_name> → NLB DNS name
                    ┌──────────────────▼──────────────────┐
                    │           Internet Gateway          │
                    └──────────────────┬──────────────────┘
                                       │  TLS 443 (port 80 closed)
                    ┌──────────────────▼──────────────────┐
                    │     Network Load Balancer (NLB)     │
                    │   TLS 443 only  •  ACM certificate  │
                    │  internet-facing  •  cross-zone LB  │
                    └──────────┬────────────────┬─────────┘
                               │                │  TCP 80 (HTTP inside VPC)
          ┌────────────────────▼──┐        ┌────▼──────────────────┐
          │       us-east-1a      │        │       us-east-1b      │
          │  Public 10.0.1.0/24   │        │  Public 10.0.2.0/24   │
          │  NLB node + NAT GW    │        │  NLB node + NAT GW    │
          │                       │        │                       │
          │  Private 10.0.3.0/24  │        │  Private 10.0.4.0/24  │
          │  ┌─────────────────┐  │        │  ┌─────────────────┐  │
          │  │  EC2  t3.medium │  │        │  │  EC2  t3.medium │  │
          │  │  Nginx / Apache │  │        │  │  Nginx / Apache │  │
          │  └─────────────────┘  │        │  └─────────────────┘  │
          └───────────┬───────────┘        └───────────┬───────────┘
                      │                                │
                      └────────────────┬───────────────┘
                                       │  TCP 5432 over TLS (boot-time check)
          ┌────────────────────────────▼───────────────────────────┐
          │  Database subnets 10.0.5.0/24 and 10.0.6.0/24          │
          │  RDS for PostgreSQL 18  •  Multi-AZ DB instance        │
          │  ┌────────────────────┐        ┌────────────────────┐  │
          │  │ Primary            ├─ sync ─┤ Standby, other AZ  │  │
          │  │ one endpoint       │        │ not readable       │  │
          │  └────────────────────┘        └────────────────────┘  │
          └────────────────────────────────────────────────────────┘

                    Auto Scaling Group (2 – 6 instances)
                    Scale out: CPU > 70%  •  Scale in: CPU < 30%
                    Outbound: instance → NAT Gateway (same AZ) → IGW

   ┌─────────────────────────────────────────────────────────────────┐
   │  CloudWatch                                                     │
   │   • CPUUtilization HIGH alarm  ──►  scale-out policy (+1)       │
   │   • CPUUtilization LOW  alarm  ──►  scale-in  policy (−1)       │
   │   • UnHealthyHostCount  alarm  ──►  SNS email notification      │
   │   • HealthyHostCount    alarm  ──►  SNS email notification      │
   └─────────────────────────────────────────────────────────────────┘
```

**Traffic flow:**
`User → https://<domain_name> (Cloudflare DNS, DNS only) → Internet Gateway → NLB (TLS 443, ACM certificate) → Target Group (TCP 80) → EC2 instance (port 80, Nginx/Apache)`

**Database path (once per instance, at boot):**
`EC2 instance → RDS endpoint (TCP 5432, TLS required) → writes "Database: connected" or "Database: unreachable" on the page`

> TLS ends at the NLB. From the NLB to the instances the traffic is plain HTTP
> on port 80 inside the VPC. Port 80 on the NLB is closed: there is no listener
> and no security group rule for it, so `http://` requests fail to connect and
> are not redirected.

> WAFv2 cannot be associated with an NLB (Layer 4). The WAF ACL is provisioned
> and ready; associate it with an ALB ARN if you place an ALB in front of the NLB.

---

## Networking & Routing

### VPC

| Field | Value |
|---|---|
| **CIDR Block** | `10.0.0.0/16` |
| **DNS Hostnames** | Enabled |
| **DNS Support** | Enabled |
| **Managed by** | `terraform-aws-modules/vpc/aws ~> 5.0` |

### Subnets

| Name | AZ | CIDR | Tier | Purpose |
|---|---|---|---|---|
| `scalable-webapp-prod-vpc-public-us-east-1a` | `us-east-1a` | `10.0.1.0/24` | Public | NLB node, NAT Gateway; `map_public_ip_on_launch = false` |
| `scalable-webapp-prod-vpc-public-us-east-1b` | `us-east-1b` | `10.0.2.0/24` | Public | NLB node, NAT Gateway; `map_public_ip_on_launch = false` |
| `scalable-webapp-prod-vpc-private-us-east-1a` | `us-east-1a` | `10.0.3.0/24` | Private | EC2 instances; no public IPs |
| `scalable-webapp-prod-vpc-private-us-east-1b` | `us-east-1b` | `10.0.4.0/24` | Private | EC2 instances; no public IPs |
| `scalable-webapp-prod-vpc-db-us-east-1a` | `us-east-1a` | `10.0.5.0/24` | Database | RDS; no route out of the VPC |
| `scalable-webapp-prod-vpc-db-us-east-1b` | `us-east-1b` | `10.0.6.0/24` | Database | RDS; no route out of the VPC |

Subnet names are generated by the VPC module as
`<project_name>-<environment>-vpc-<tier>-<az>`. The database subnets are set
through `var.database_subnet_cidrs`. The module also creates the DB subnet
group, which is named after the VPC: `scalable-webapp-prod-vpc`.

### Route Tables

| Route Table | Subnets | Destination | Target |
|---|---|---|---|
| Public RT | public-1a, public-1b | `10.0.0.0/16` | local |
| Public RT | public-1a, public-1b | `0.0.0.0/0` | Internet Gateway |
| Private RT (AZ-1) | private-1a | `10.0.0.0/16` | local |
| Private RT (AZ-1) | private-1a | `0.0.0.0/0` | NAT Gateway (us-east-1a) |
| Private RT (AZ-2) | private-1b | `10.0.0.0/16` | local |
| Private RT (AZ-2) | private-1b | `0.0.0.0/0` | NAT Gateway (us-east-1b) |
| Database RT (AZ-1) | db-1a | `10.0.0.0/16` | local |
| Database RT (AZ-2) | db-1b | `10.0.0.0/16` | local |

> Each private subnet routes through its own AZ-local NAT Gateway. This
> prevents cross-AZ NAT traffic and keeps the stack operational when one AZ
> is impaired.

> The VPC module creates **two** database route tables, one per database
> subnet. Each holds the local VPC route only: no NAT Gateway route and no
> Internet Gateway route (`create_database_subnet_route_table = true`,
> `create_database_nat_gateway_route = false`,
> `create_database_internet_gateway_route = false` in `main.tf`). Without the
> first flag the module would attach the database subnets to the private,
> NAT-routed route tables.

### Traffic Flow

```
Browser: https://<domain_name>
    │
    ▼  Cloudflare DNS (DNS only): CNAME <domain_name> → NLB DNS name
Internet
    │
    ▼  0.0.0.0/0 → Internet Gateway
Network Load Balancer  (TLS:443 listener; no port 80 listener)
    ├── public subnet us-east-1a (10.0.1.0/24)
    └── public subnet us-east-1b (10.0.2.0/24)
    │
    ▼  TCP:80 → Target Group (plain HTTP inside the VPC)
EC2 Instances (Auto Scaling Group)
    ├── private subnet us-east-1a (10.0.3.0/24)
    └── private subnet us-east-1b (10.0.4.0/24)
    │
    ├── 0.0.0.0/0 → NAT Gateway → Internet Gateway
    │   Outbound (package installs, SSM, Secrets Manager, other AWS APIs)
    │
    ▼  TCP:5432 over TLS → RDS endpoint (local route, at boot only)
RDS for PostgreSQL (Multi-AZ DB instance)
    ├── database subnet us-east-1a (10.0.5.0/24)
    └── database subnet us-east-1b (10.0.6.0/24)
        (local route only: no NAT Gateway, no Internet Gateway)
```

---

## Component Details

### 1. Security Groups

#### NLB Security Group (`scalable-webapp-prod-nlb-sg`)

| Direction | Protocol | Port | Source / Destination | Purpose |
|---|---|---|---|---|
| Inbound | TCP | 443 | `0.0.0.0/0` | HTTPS from internet |
| Outbound | All | All | `0.0.0.0/0` | Forward traffic to instances |

> Port 80 is closed on the NLB: there is no inbound rule for it and no
> listener. Port 443 is the only way in from the internet.

#### EC2 Security Group (`scalable-webapp-prod-ec2-sg`)

| Direction | Protocol | Port | Source / Destination | Purpose |
|---|---|---|---|---|
| Inbound | TCP | 80 | NLB security group ID | HTTP from NLB only — not the open internet |
| Outbound | All | All | `0.0.0.0/0` | Package installs, SSM agent, AWS APIs, PostgreSQL to the database |

> **Production note:** EC2 instances are not reachable from the internet. The
> inbound rule references the NLB security group ID, not a CIDR, so only the
> NLB's network interfaces can open connections to instances on port 80.

#### DB Security Group (`scalable-webapp-prod-db-sg`)

| Direction | Protocol | Port | Source / Destination | Purpose |
|---|---|---|---|---|
| Inbound | TCP | 5432 | EC2 security group ID | PostgreSQL from EC2 instances only |
| Outbound | — | — | none (`egress = []`) | The database opens no outbound connections |

> The single inbound rule references the EC2 security group ID, not a CIDR.
> There is no other inbound rule and no outbound rule; replies to the
> instances are allowed because security groups are stateful.

---

### 2. Launch Template (`scalable-webapp-prod-lt-*`)

| Attribute | Value |
|---|---|
| AMI | Latest Amazon Linux 2023 x86_64, resolved from the public SSM parameter `/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64` when `var.ami_id` is empty (the default). `var.ami_id` is an optional override and must be Amazon Linux 2023 (x86_64) |
| Instance Type | `t3.medium` (2 vCPU, 4 GB RAM) — override via `var.instance_type` |
| Key Pair | Supplied via `var.key_pair_name` (emergency SSH only) |
| IAM Instance Profile | `scalable-webapp-prod-ec2-profile`, role `scalable-webapp-prod-ec2-role`: `AmazonSSMManagedInstanceCore` (SSM access) plus the inline policy `scalable-webapp-prod-db-secret-read` (`secretsmanager:GetSecretValue` on the one database secret ARN) |
| Public IP | Disabled — instances are in private subnets |
| Detailed Monitoring | Enabled (1-minute CloudWatch metrics) |
| IMDSv2 | `HttpTokens = required`, hop limit 1 — token-based metadata only |
| Web Server | Nginx (default) or Apache — set via `var.web_server` |
| User Data | Amazon Linux 2023 only (`dnf`). Installs and starts the web server, installs a PostgreSQL client, runs the boot-time database check, then writes `index.html` showing instance ID and AZ (pulled via IMDSv2), the web server, and one database status line |

One user data script serves both `var.web_server` values; only the package,
service name and document root differ. The index page is written per
instance, making it easy to observe load balancing by refreshing the browser.

#### Boot-Time Database Check

| Property | Value |
|---|---|
| What runs | `psql` runs `SELECT 1` against the RDS endpoint (database `postgres`) |
| Client package | Tried in the order `postgresql18`, `postgresql17`, `postgresql16`, `postgresql15`; a failed install is not fatal, the check then reports `unreachable` |
| Credential | The master user name and password, read at boot from the RDS-managed Secrets Manager secret with the instance role, and passed to `psql` only through its process environment |
| TLS | `sslmode=require`: the connection is encrypted, but the server certificate is not verified |
| Retry | Bounded: 5 attempts, 5 seconds apart |
| Page line | Exactly `<p>Database: connected</p>` or `<p>Database: unreachable</p>` |
| When it runs | Once, at boot. The line is a snapshot: it does not change if the database becomes unreachable later, or reachable later |
| Before it finishes | The web server starts before the check, so the server's default page is served until the custom page is written. Worst-case check time is about 95 seconds (calculated, not measured) |
| In the user data text | The database address, port and secret ARN. None is a credential; the user name and password are never in user data |

> The web server is installed and started before the check and the page is
> written whatever the check returns, so NLB health checks never depend on
> the database.

> The script is written so that nothing but the word `connected` or
> `unreachable` reaches the page: not the version string, the endpoint, the
> user name or anything from the secret. The output of the check is captured
> or discarded and there is no `set -x`.

> **Production note:** the boot-time check uses the master credential. That
> is acceptable for a connectivity proof and not for a real application,
> which should have its own least-privilege database user.

> The user data has been exercised against stub commands on a workstation
> only. It has not been run on an instance, and the check has not been run
> against a database. That an Amazon Linux 2023 PostgreSQL client package
> connects cleanly to a PostgreSQL 18 server is unproven until a deploy.

---

### 3. Network Load Balancer (`scalable-webapp-prod-nlb`)

| Attribute | Value |
|---|---|
| Type | Network (Layer 4 TCP/TLS) |
| Scheme | Internet-facing |
| Subnets | `scalable-webapp-prod-vpc-public-us-east-1a`, `scalable-webapp-prod-vpc-public-us-east-1b` |
| Security Group | `scalable-webapp-prod-nlb-sg` |
| Cross-Zone Load Balancing | Enabled |
| Deletion Protection | Enabled when `var.environment = "prod"` |
| Listener | `TLS:443` → forward to target group. It is the only listener and is always created |
| Certificate | The ACM certificate for `var.domain_name` (see sub-section 8). The listener takes the ARN from the validation resource, so it is created only after ACM has issued the certificate |
| TLS Policy | `var.ssl_policy`, default `ELBSecurityPolicy-TLS13-1-2-Res-PQ-2025-09` |
| Port 80 | No listener and no security group rule |

> Unlike an ALB, an NLB operates at Layer 4. It ends TLS on the listener but
> does not parse HTTP; it forwards the decrypted connection to instances as
> plain TCP on port 80. This means no HTTP-level features (path routing,
> header inspection, redirects) — use an ALB if those are required.

> Because an NLB can only forward, there is no HTTP-to-HTTPS redirect. With
> port 80 closed, `http://` requests to the hostname fail to connect. This is
> a behaviour change from the previous architecture, which served HTTP on
> TCP 80.

> The default TLS policy name was confirmed in AWS documentation only, not in
> the account. Confirm it before a deploy with the read-only call in
> [Prerequisites](#prerequisites). If the policy is not offered for Network
> Load Balancers, set `ssl_policy = "ELBSecurityPolicy-TLS13-1-2-2021-06"`.

---

### 4. Target Group (`scalable-webapp-prod-tg`)

| Attribute | Value |
|---|---|
| Protocol / Port | TCP / 80 |
| Target Type | Instance |
| Health Check Protocol | TCP |
| Health Check Port | 80 |
| Health Check Interval | 30 seconds |
| Healthy Threshold | 3 consecutive successes |
| Unhealthy Threshold | 3 consecutive failures |

Health checks open a TCP connection on port 80. An instance must accept three
consecutive connections before traffic is routed to it, and must fail three
consecutive checks before being marked unhealthy and removed from rotation
(~90 seconds to drain).

---

### 5. Auto Scaling Group (`scalable-webapp-prod-asg`)

| Attribute | Value |
|---|---|
| Desired Capacity | 2 (configurable via `var.asg_desired_capacity`) |
| Minimum Capacity | 2 (configurable via `var.asg_min_size`) |
| Maximum Capacity | 6 (configurable via `var.asg_max_size`) |
| Subnets | `scalable-webapp-prod-vpc-private-us-east-1a`, `scalable-webapp-prod-vpc-private-us-east-1b` |
| Health Check Type | `ELB` — uses NLB health checks, not just EC2 instance status |
| Health Check Grace Period | 300 seconds (allows web server to start before first check) |
| Launch Template Version | `$Latest` — always uses the newest launch template version |
| Instance Refresh | Rolling, `MinHealthyPercentage = 50` |
| Creation Order | `depends_on` the DB instance and the IAM policy that lets the instance role read the database secret, so both exist before the first instance boots and runs its database check |

> `health_check_type = "ELB"` means the ASG considers an instance healthy only
> when the NLB target group marks it healthy. This is stricter than `EC2`,
> which considers an instance healthy as soon as it is running, even if the
> web server has not started.

---

### 6. Scaling Policies & CloudWatch Alarms

Two **Simple Scaling** policies control instance count — one per direction.

#### Scale-Out Policy

| Trigger | Action | Cooldown |
|---|---|---|
| CPU > `var.cpu_scale_out_threshold` (default 70%) for 2 × 60 s | Add **1** instance | 300 seconds |

#### Scale-In Policy

| Trigger | Action | Cooldown |
|---|---|---|
| CPU < `var.cpu_scale_in_threshold` (default 30%) for 2 × 60 s | Remove **1** instance | 300 seconds |

#### CloudWatch Alarms

| Alarm | Metric | Threshold | Action |
|---|---|---|---|
| `cpu-high` | `CPUUtilization` (ASG avg) | > 70% for 2 periods | Scale-out policy |
| `cpu-low` | `CPUUtilization` (ASG avg) | < 30% for 2 periods | Scale-in policy |
| `unhealthy-hosts` | `UnHealthyHostCount` (NLB) | ≥ 1 for 2 periods | SNS notification |
| `healthy-hosts-low` | `HealthyHostCount` (NLB) | < `asg_min_size` for 2 periods | SNS notification |
| `network-in-high` | `ProcessedBytes` (NLB) | > 1 GB per 5 min | SNS notification |

---

### 7. RDS for PostgreSQL (`scalable-webapp-prod-db`)

| Attribute | Value |
|---|---|
| Identifier | `scalable-webapp-prod-db` (`<project_name>-<environment>-db`) |
| Engine | RDS for PostgreSQL, `engine_version = "18"` (major version only) with `auto_minor_version_upgrade = true`, so RDS picks the minor version |
| Deployment | Multi-AZ DB instance (`multi_az = true`): a primary plus a synchronous standby in a second AZ, behind one endpoint. The standby cannot be queried |
| Instance Class | `var.db_instance_class`, default `db.t3.micro` |
| Storage | 20 GB gp3, encrypted with the AWS-managed `aws/rds` key; storage autoscaling is off |
| Master User | `var.db_master_username`, default `dbadmin` |
| Master Password | `manage_master_user_password = true`: RDS generates the password, stores it in Secrets Manager and rotates it. There is no password argument and no password variable; the configuration refers only to the secret's ARN |
| Subnet Group | `scalable-webapp-prod-vpc`, created by the VPC module over the two database subnets |
| Security Group | `scalable-webapp-prod-db-sg` only |
| Public Access | `publicly_accessible = false` |
| Backups | `var.db_backup_retention_period`, default 7 days of automated backups |
| Deletion Protection | `var.db_deletion_protection`, default `false` |
| Final Snapshot | `var.db_skip_final_snapshot`, default `true` (no snapshot). When `false`, the snapshot is named `scalable-webapp-prod-db-final` |
| Not Configured | Performance Insights, enhanced monitoring, database alarms, a custom parameter group, a customer-managed KMS key |

> **Production note:** a production stack would turn deletion protection on
> and keep a final snapshot (`db_deletion_protection = true`,
> `db_skip_final_snapshot = false`). The defaults suit a stack that is
> routinely destroyed and holds no real data.

> The final snapshot name is fixed (`<project_name>-<environment>-db-final`).
> A second destroy that keeps a snapshot would collide with the snapshot left
> by the first, so remove or copy the earlier snapshot before destroying
> again.

> "Two instances" here means one DB identifier marked Multi-AZ in the RDS
> console, not two rows. The second instance is the standby: it exists for
> availability, has no endpoint of its own and serves no reads.

---

### 8. TLS Certificate & DNS Records (ACM + Cloudflare)

| Resource | Terraform Address | Detail |
|---|---|---|
| ACM certificate | `aws_acm_certificate.web` | Public certificate for `var.domain_name`, DNS-validated, `create_before_destroy`, tagged `Name = scalable-webapp-prod-cert`. Requested in `var.region`, the same region as the NLB |
| Validation record | `cloudflare_dns_record.acm_validation` | CNAME taken from the certificate's validation options, TTL 300, `proxied = false`; the trailing dot ACM returns is trimmed from name and value |
| Validation wait | `aws_acm_certificate_validation.web` | Waits until ACM reports the certificate as issued. The `TLS:443` listener uses this resource's certificate ARN |
| Hostname record | `cloudflare_dns_record.web` | CNAME from `var.domain_name` to the NLB DNS name, TTL 60, `proxied = false` |

| Provider Setting | Value |
|---|---|
| Provider | `cloudflare/cloudflare ~> 5.0`, declared as `provider "cloudflare" {}` with no arguments |
| API token | Read only from the `CLOUDFLARE_API_TOKEN` environment variable. It is never a Terraform variable and never in `prod.tfvars` |
| Zone | `var.cloudflare_zone_id`, the zone that holds `var.domain_name` |

> Both Cloudflare records are DNS-only (not proxied), so browsers negotiate
> TLS with the NLB listener, not with Cloudflare.

> The ACM validation record must stay in place for as long as the
> certificate is in use, because ACM renews the certificate through it.

> The NLB DNS name changes every time the stack is destroyed and re-created.
> Terraform re-points the hostname record on each apply, which is why the
> record has a short TTL.

> No certificate has been issued and no DNS record has been created for this
> revision; both happen on the first `terraform apply`.

---

## Directory Structure

```
.
├── main.tf                  # VPC module (public, private, database subnets), SGs,
│                            #   RDS, IAM, launch template, NLB + TLS listener,
│                            #   ACM certificate, Cloudflare DNS records, ASG,
│                            #   scaling policies, CloudWatch alarms, SNS, WAFv2
├── variables.tf             # All input variable declarations with validation
├── outputs.tf               # Exported values after apply (HTTPS URL, NLB DNS,
│                            #   DB endpoint, secret ARN, etc.)
├── provider.tf              # AWS, Random and Cloudflare provider requirements;
│                            #   commented-out S3 remote state
├── prod.tfvars.example      # Copy to prod.tfvars and fill in required values
├── README.md                # This file
├── Result.md                # Audit of the June 2026 deployment of the previous
│                            #   architecture (HTTP only, no database tier)
├── Automation/
│   ├── .gitignore           # Ignores generated reports and temporary files
│   ├── deploy.sh            # Legacy reference: AWS CLI build of the pre-change
│   │                        #   architecture (HTTP only, no database)
│   └── health_check.sh      # Read-only check script for the stack
└── screenshots/             # From the June 2026 deployment of the previous
    │                        #   architecture
    ├── health-check-1.png        # Check script output, first part
    ├── health-check-2.png        # Check script output, second part
    ├── health-check-summary.png  # Check script summary
    └── webapp-live.png           # The page served over HTTP in June 2026
```

Not shown because they are git-ignored and local to each checkout:
`prod.tfvars`, `.terraform/`, `.terraform.lock.hcl` and any state or plan
file.

---

## Prerequisites

| Tool | Minimum Version | Install |
|---|---|---|
| Terraform | 1.5.0 | https://developer.hashicorp.com/terraform/install |
| AWS CLI | 2.x | https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html |
| AWS credentials | — | `aws configure` or environment variables |
| `jq` | any | `brew install jq` (macOS) / `apt install jq` (Linux) — for `Automation/health_check.sh` only |
| `curl` | any | Preinstalled on macOS and most Linux distributions — for `Automation/health_check.sh` and the Quick Start check |
| Apache Bench (`ab`) | any | `brew install httpd` (macOS) / `apt install apache2-utils` (Linux) — for load testing only |

**Account-level requirements:**

- An existing EC2 key pair in the target region (`var.key_pair_name`)
- A hostname under a DNS zone hosted in Cloudflare (`var.domain_name`; the example file uses `webapp-nlb.aterpise.com`) and that zone's ID (`var.cloudflare_zone_id`)
- A Cloudflare API token with Zone / DNS / Edit permission on that zone, exported as `CLOUDFLARE_API_TOKEN` in the shell that runs Terraform. The token is required before `terraform plan` and `terraform apply`. It never goes in `prod.tfvars`, in a Terraform variable or in the repository
- No AMI ID is needed: the latest Amazon Linux 2023 x86_64 AMI is resolved automatically. `var.ami_id` is an optional override and must be Amazon Linux 2023
- No certificate is needed up front: the stack requests its own ACM certificate. The `acm_certificate_arn` variable no longer exists
- IAM permissions: EC2 full, ELB full, AutoScaling full, CloudWatch full, WAFv2 full, IAM role create/attach, SNS full, VPC full, and, new in this revision, RDS, ACM, Secrets Manager and read access to the public SSM parameter that holds the AMI ID

**Before the first deploy of this revision:**

1. Create the Cloudflare API token described above and export it:
   `export CLOUDFLARE_API_TOKEN="<your-cloudflare-api-token>"`. It never goes in a file.
2. Update the local `prod.tfvars`: add `domain_name` and `cloudflare_zone_id`; remove `acm_certificate_arn`; remove a pinned `ami_id`, or confirm that it is an Amazon Linux 2023 AMI.
3. Confirm with a read-only call that the TLS policy name exists for Network Load Balancers:

   ```bash
   aws elbv2 describe-ssl-policies \
     --names ELBSecurityPolicy-TLS13-1-2-Res-PQ-2025-09 \
     --load-balancer-type network \
     --region us-east-1
   ```

4. Get explicit approval for `terraform apply`. In this repository `plan` may be run freely; `apply` needs the repository owner's explicit approval.

> The region is `us-east-1` by default (`var.region`). This is a deliberate,
> approved exception to the repository default of `ap-southeast-1`.

---

## Quick Start

### Path A — Terraform

```bash
# 1. Enter the project directory
cd "Scalable Web App (NLB+ASG+RDS)"

# 2. Copy the example vars file and fill in the required values:
#    key_pair_name, alarm_email, domain_name, cloudflare_zone_id
cp prod.tfvars.example prod.tfvars
vim prod.tfvars

# 3. Export the Cloudflare API token (Zone / DNS / Edit on the zone).
#    Required before plan and apply. Never put it in prod.tfvars.
export CLOUDFLARE_API_TOKEN="<your-cloudflare-api-token>"

# 4. Initialise providers and the VPC module
terraform init

# 5. Preview all changes before creating anything
terraform plan -var-file=prod.tfvars

# 6. Deploy. Needs explicit approval in this repository. The duration has not
#    been measured for this revision: it adds a Multi-AZ RDS instance and ACM
#    certificate validation to the build.
terraform apply -var-file=prod.tfvars

# 7. Get the HTTPS URL from outputs
terraform output https_url

# 8. Check that the app is serving over HTTPS
curl "$(terraform output -raw https_url)"
```

> **Remote state:** Before team use, create an S3 bucket and a DynamoDB table
> (partition key `LockID`, type String), then uncomment the `backend "s3"`
> block in `provider.tf` and re-run `terraform init`.

> Use the `https_url` output, not `nlb_dns_name`. The certificate is issued
> for `var.domain_name` and does not cover the NLB DNS name, and there is no
> port 80 listener, so `http://` requests fail to connect.

Allow **3–5 minutes** after `apply` completes for instances to pass their
NLB health checks before traffic is forwarded. Until an instance finishes its
boot-time database check (worst case about 95 seconds, calculated, not
measured) it serves the web server's default page; after that the page shows
the instance ID, the AZ and a `Database: connected` or `Database: unreachable`
line.

### Checking the Stack After a Deploy (`Automation/health_check.sh`)

`Automation/health_check.sh` is a read-only check script to run after a
deploy. It walks the stack layer by layer (load balancer and listener, target
health, Auto Scaling Group, instances, alarms, networking, database) with
`describe`, `list` and `get` calls and changes nothing in AWS. For this
revision it requests `https://<hostname>` and checks the certificate, expects
port 80 to be closed, and looks for `Database: connected` on the page. For
the database it checks that the instance is available, Multi-AZ, not publicly
accessible and encrypted, and that the DB security group admits only the EC2
security group.

```bash
# 1. From the project directory. The script locates the project root (one
#    level above Automation/) by itself and reads prod.tfvars and the
#    Terraform state from there.
./Automation/health_check.sh

# 2. Optional flags. Each one overrides the value the script would otherwise
#    read from prod.tfvars or from the Terraform outputs.
./Automation/health_check.sh \
  --project-name scalable-webapp \
  --environment prod \
  --region us-east-1 \
  --domain-name "<your-hostname>"
```

| Input | Where the script gets it |
|---|---|
| Tools | Requires `aws` (CLI v2), `jq` and `curl`; `terraform` is optional |
| AWS credentials | The AWS CLI's usual configuration. The script stops if `aws sts get-caller-identity` fails |
| Project name, environment, region | `--project-name`, `--environment`, `--region`; otherwise `prod.tfvars` in the project root; otherwise `scalable-webapp`, `prod`, `us-east-1` |
| Resource ARNs and IDs | `terraform output -json` in the project root when Terraform and a state are present; otherwise lookups by naming pattern |
| Hostname for the HTTPS checks | `--domain-name`; otherwise the `https_url` output; otherwise `domain_name` in `prod.tfvars`. Without a hostname the HTTPS and page checks are skipped with a warning |
| Environment variables | None of its own; the script does not read `CLOUDFLARE_API_TOKEN` |
| Exit status | The number of failed checks, so `0` means nothing failed |

> The script has not been run against this revision, because nothing is
> deployed. The files in `screenshots/` show its June 2026 run against the
> previous architecture, before the HTTPS and database checks existed.

### Path B — AWS CLI (`Automation/deploy.sh`), Legacy Reference

> **Legacy reference for the pre-change architecture.**
> `Automation/deploy.sh` builds the previous architecture: HTTP only on
> TCP 80, no database tier, no certificate and no DNS records. It was left
> unchanged by the HTTPS and RDS revision and does not produce the stack this
> README describes. Use Path A for the current design.

```bash
# 1. Open Automation/deploy.sh and set the variables at the top:
#    AMI_ID, KEY_PAIR_NAME, ALARM_EMAIL, and optionally REGION / WEB_SERVER
vim Automation/deploy.sh

# 2. Run the script (it executes all 9 sections in order)
chmod +x Automation/deploy.sh
./Automation/deploy.sh

# 3. The script prints the NLB DNS name in the summary at the end
curl http://<nlb_dns_name printed by the script>
```

Allow **3–5 minutes** after the script completes for health checks to pass.

---

## Input Variables

| Variable | Type | Default | Description |
|---|---|---|---|
| `project_name` | `string` | `"scalable-webapp"` | Prefix applied to every resource name and tag |
| `environment` | `string` | `"prod"` | Deployment environment; controls NLB deletion protection |
| `region` | `string` | `"us-east-1"` | AWS region to deploy into |
| `vpc_cidr` | `string` | `"10.0.0.0/16"` | CIDR block for the VPC |
| `public_subnet_cidrs` | `list(string)` | `["10.0.1.0/24","10.0.2.0/24"]` | One public subnet CIDR per AZ (NLB placement) |
| `private_subnet_cidrs` | `list(string)` | `["10.0.3.0/24","10.0.4.0/24"]` | One private subnet CIDR per AZ (EC2 placement) |
| `database_subnet_cidrs` | `list(string)` | `["10.0.5.0/24","10.0.6.0/24"]` | One database subnet CIDR per AZ (RDS placement); at least two (validated) |
| `instance_type` | `string` | `"t3.medium"` | EC2 instance type |
| `ami_id` | `string` | `""` | Optional AMI override. Empty (the default) resolves the latest Amazon Linux 2023 x86_64 AMI; an override must be Amazon Linux 2023-compatible (validated) |
| `key_pair_name` | `string` | *(required)* | Name of an existing EC2 key pair |
| `asg_min_size` | `number` | `2` | Minimum instance count in the ASG |
| `asg_max_size` | `number` | `6` | Maximum instance count the ASG can scale to |
| `asg_desired_capacity` | `number` | `2` | Starting instance count |
| `cpu_scale_out_threshold` | `number` | `70` | CPU % that triggers a scale-out event (add 1 instance) |
| `cpu_scale_in_threshold` | `number` | `30` | CPU % that triggers a scale-in event (remove 1 instance) |
| `domain_name` | `string` | *(required)* | Fully qualified hostname served over HTTPS; the ACM certificate is issued for it and a Cloudflare CNAME points it at the NLB (validated) |
| `cloudflare_zone_id` | `string` | *(required)* | ID of the Cloudflare zone that holds `domain_name` (validated) |
| `ssl_policy` | `string` | `"ELBSecurityPolicy-TLS13-1-2-Res-PQ-2025-09"` | ELB security policy for the NLB `TLS:443` listener |
| `db_instance_class` | `string` | `"db.t3.micro"` | RDS instance class for the PostgreSQL Multi-AZ DB instance |
| `db_master_username` | `string` | `"dbadmin"` | Master user name for the RDS instance; must not be a PostgreSQL reserved word (format validated) |
| `db_backup_retention_period` | `number` | `7` | Days RDS keeps automated backups; `0` turns automated backups off (validated) |
| `db_deletion_protection` | `bool` | `false` | Turn on RDS deletion protection; a production stack would set it to `true` |
| `db_skip_final_snapshot` | `bool` | `true` | Skip the final DB snapshot on destroy; a production stack would set it to `false` |
| `alarm_email` | `string` | *(required)* | Email that receives CloudWatch alarm notifications |
| `web_server` | `string` | `"nginx"` | Web server to install — `"nginx"` or `"apache"` (validated) |

Four variables have no default and must be set: `key_pair_name`,
`alarm_email`, `domain_name` and `cloudflare_zone_id`.

**Validation:** each rule below refers only to its own variable; there are no
cross-variable rules. A value that breaks a rule stops Terraform with the
rule's error message.

| Variable | Rule |
|---|---|
| `database_subnet_cidrs` | At least two CIDR blocks, because an RDS DB subnet group must span two Availability Zones |
| `ami_id` | Empty, or an AMI ID of the form `ami-` plus 8 to 17 hexadecimal characters, with no surrounding whitespace |
| `domain_name` | A lowercase fully qualified hostname with no scheme, no wildcard and no trailing dot |
| `cloudflare_zone_id` | The 32-character hexadecimal zone ID |
| `db_master_username` | Starts with a letter; 1 to 63 letters, digits or underscores |
| `db_backup_retention_period` | Between 0 and 35 days |
| `web_server` | `"nginx"` or `"apache"` |

> There is no password variable and no token variable. RDS generates the
> database master password and keeps it in Secrets Manager, and the
> Cloudflare API token comes only from the `CLOUDFLARE_API_TOKEN` environment
> variable.

> `acm_certificate_arn` no longer exists. Remove it from any `prod.tfvars`
> written for the previous architecture.

---

## Outputs

| Output | Description |
|---|---|
| `https_url` | HTTPS URL of the application (`https://<domain_name>`) — use as the app entry point |
| `nlb_dns_name` | Public DNS name of the NLB, the target of the Cloudflare CNAME. Do not browse to it: the certificate does not cover this name and there is no port 80 listener |
| `certificate_arn` | ARN of the ACM certificate on the NLB `TLS:443` listener |
| `db_endpoint` | Connection endpoint of the RDS PostgreSQL instance, as `address:port`. Reachable only from the EC2 security group |
| `db_secret_arn` | ARN of the Secrets Manager secret that holds the RDS-managed master credential. The ARN only; the secret value is never an output |
| `db_instance_identifier` | Identifier of the RDS DB instance |
| `nlb_arn` | ARN of the NLB (used for CLI operations) |
| `asg_name` | Auto Scaling Group name |
| `asg_arn` | ARN of the Auto Scaling Group |
| `launch_template_id` | ID of the EC2 Launch Template |
| `vpc_id` | VPC ID |
| `public_subnet_ids` | List of public subnet IDs (NLB placement) |
| `private_subnet_ids` | List of private subnet IDs (EC2 placement) |
| `database_subnet_ids` | List of database subnet IDs (RDS placement) |
| `ec2_security_group_id` | Security group attached to EC2 instances |
| `db_security_group_id` | Security group attached to the RDS instance |
| `iam_role_arn` | IAM role ARN attached to instances (SSM access and read access to the one database secret) |
| `sns_topic_arn` | SNS topic ARN used for CloudWatch alarm notifications |
| `target_group_arn` | ARN of the NLB target group |
| `waf_web_acl_arn` | WAFv2 Web ACL ARN (not associated with the NLB) |

New in this revision: `https_url`, `certificate_arn`, `db_endpoint`,
`db_secret_arn`, `db_instance_identifier`, `database_subnet_ids` and
`db_security_group_id`.

Retrieve any output after `apply`:

```bash
# Single output
terraform output https_url

# All outputs as JSON
terraform output -json
```

---

## Scaling Behaviour

```
CPU %  │
  100  │
   70  │  ─────────────────────────────────────────── scale-out threshold (+1 instance)
       │               dead band (no action)
   30  │  ─────────────────────────────────────────── scale-in  threshold (−1 instance)
    0  └──────────────────────────────────────────────────────────────────────► time
```

**Dead band (30%–70%):** No scaling action fires in this range. This prevents
oscillation when CPU hovers near a threshold — a 5% CPU fluctuation will not
cause instances to be repeatedly added and removed.

**Evaluation periods = 2:** Each alarm requires two consecutive 60-second
periods (2 minutes total) above or below the threshold before firing. This
prevents reactions to brief CPU spikes caused by cron jobs or health check
responses.

**Cooldown = 300 s:** After a scaling action, Simple Scaling waits 300 seconds
before evaluating alarms again. This gives the new instance time to come into
service and absorb load before another scale-out is triggered.

**Step size = 1:** Both policies adjust capacity by exactly one instance per
action. This is conservative — sustained high CPU will trigger repeated
scale-out actions (one every ~7 minutes: 2-minute evaluation + 5-minute
cooldown) until demand is met or `asg_max_size` is reached. To scale faster
under sudden spikes, increase `scaling_adjustment` in the scale-out policy in
`main.tf`.

---

## Tagging Strategy

Every resource receives tags applied via the provider's `default_tags` block,
plus a per-resource `Name` tag:

| Tag Key | Value |
|---|---|
| `Name` | Unique per resource (e.g. `scalable-webapp-prod-nlb`, `scalable-webapp-prod-ec2-sg`, `scalable-webapp-prod-db`, `scalable-webapp-prod-db-sg`, `scalable-webapp-prod-cert`) |
| `Project` | Value of `var.project_name` (default: `scalable-webapp`) |
| `Environment` | Value of `var.environment` (default: `prod`) |
| `ManagedBy` | `terraform` |

> **ASG instance tags:** The ASG uses explicit `tag {}` blocks with
> `propagate_at_launch = true` because ASG instance tags are not covered by
> the provider-level `default_tags`. Instances receive all four tags above
> plus `Name = scalable-webapp-prod-web`.

> **Launch template volume tags:** `tag_specifications` blocks for both
> `"instance"` and `"volume"` resource types are included in the launch
> template so EBS volumes are tagged at creation time.

> **Database subnets and route tables:** these are created by the VPC module,
> which names them `scalable-webapp-prod-vpc-db-<az>` and applies the module's
> `tags` map (`Project`, `Environment`, `ManagedBy`). The DB subnet group is
> named `scalable-webapp-prod-vpc`.

> **Database secret:** the Secrets Manager secret that holds the master
> credential is created and owned by RDS. It is not a Terraform resource, so
> the provider's `default_tags` are not applied to it by this configuration.

> **Cloudflare records:** the two DNS records are not AWS resources and carry
> no AWS tags. `default_tags` belongs to the AWS provider only.

---

## Security Considerations

| Topic | Current Posture | Recommended Hardening |
|---|---|---|
| NLB internet exposure | Port 443 only accepts traffic from `0.0.0.0/0` — required for the NLB to receive public web traffic. Port 80 is closed: no listener and no security group rule | No change needed; this is intentional |
| EC2 instance exposure | Instances are in private subnets; inbound port 80 is restricted to the NLB security group only | No change needed |
| SSH access | Key pair is attached but no SSH inbound rule exists in the EC2 SG | Remove the key pair from the launch template entirely if SSM is the only access method |
| IMDSv2 | `HttpTokens = required` with hop limit 1 on the launch template; user data uses IMDSv2 tokens | No change needed — IMDSv2 is enforced |
| Bastion host | None required — SSM Session Manager is configured via `AmazonSSMManagedInstanceCore` | Enforce SSM access via IAM conditions if stricter control is needed |
| WAF | WAFv2 ACL is created with `AWSManagedRulesCommonRuleSet` + `AWSManagedRulesKnownBadInputsRuleSet`, but **cannot be associated with an NLB** (WAF is Layer 7; NLB is Layer 4) | Place an ALB in front of the NLB and associate the WAF ACL with the ALB ARN |
| HTTPS | `TLS:443` is the only listener and is always created. TLS ends at the NLB with the stack's own ACM certificate for `var.domain_name` | For encryption all the way to the instances, use a TLS target group with a certificate on the web server |
| NLB to instance traffic | Plain HTTP on port 80 inside the VPC, to instances in private subnets that accept port 80 from the NLB security group only | Acceptable where no compliance rule requires encryption in transit inside the VPC; otherwise see the HTTPS row |
| HTTP on port 80 | Closed. `http://` requests fail to connect and are not redirected, because an NLB can only forward | If a redirect is required, put an ALB in front, or keep a TCP 80 listener that forwards to a second target group where the web server answers `301` |
| TLS policy | `var.ssl_policy`, default `ELBSecurityPolicy-TLS13-1-2-Res-PQ-2025-09`. The name was confirmed in AWS documentation only | Confirm the name with `describe-ssl-policies` before a deploy; fall back to `ELBSecurityPolicy-TLS13-1-2-2021-06` if it is not offered |
| DNS records | Two Cloudflare records, both DNS-only. The API token is read from `CLOUDFLARE_API_TOKEN` only and is never in a file | Scope the token to Zone / DNS / Edit on the one zone |
| Database exposure | `publicly_accessible = false`; dedicated subnets whose route tables hold the local route only; the DB security group allows 5432 from the EC2 security group only and has no egress rule | No change needed |
| Database encryption | Storage is encrypted with the AWS-managed `aws/rds` key. The boot-time check connects with `sslmode=require`: encrypted, but the server certificate is not verified | Use a customer-managed KMS key; use `sslmode=verify-full` with the RDS certificate bundle |
| Database credential | RDS-managed master password in Secrets Manager. No password argument or variable exists, and the password is never in `prod.tfvars` or user data. The instance role may call `secretsmanager:GetSecretValue` on that one secret ARN only | A real application should use its own least-privilege database user, not the master credential the boot-time check uses |
| User data contents | The database address, port and secret ARN are in the user data text, so they are readable wherever user data is (the launch template, and the copy cloud-init keeps on the instance). None is a credential | No change needed for a connectivity proof |
| Database deletion | Deletion protection is off and the final snapshot is skipped by default, because the stack is routinely destroyed and holds no real data | A production stack would set `db_deletion_protection = true` and `db_skip_final_snapshot = false` |
| State file | Local backend by default | Use the S3 backend with DynamoDB state locking before team use |
| Deletion protection | Enabled on the NLB when `environment = "prod"` | No change needed |

> The postures above describe the Terraform as written. Nothing in this
> revision has been exercised in an AWS account.

---

## Cost Estimate

**Basis:** AWS Price List API, us-east-1, on-demand, 730 hours per month, idle
baseline, queried 2026-10-07. Usage-based charges (LCU, NAT data processing,
data transfer) are excluded.

"Before" is the previous architecture (HTTP only, no database tier). "After"
is the HTTPS and RDS revision, which is not deployed.

| Resource | Quantity | Before (USD/month) | After (USD/month) |
|---|---|---|---|
| EC2 `t3.medium` ($0.0416/h) | 2 | 60.74 | 60.74 |
| Network Load Balancer ($0.0225/h) | 1 | 16.43 | 16.43 |
| NAT gateway ($0.045/h) | 2 | 65.70 | 65.70 |
| Public IPv4 address ($0.005/h) | 4 (estimate: 2 NLB, 2 NAT) | 14.60 | 14.60 |
| WAFv2 web ACL ($5.00) plus 2 rules ($1.00 each) | 1 | 7.00 | 7.00 |
| CloudWatch alarms ($0.10 each) | 5 | 0.50 | 0.50 |
| RDS PostgreSQL `db.t3.micro` Multi-AZ ($0.036/h) | 1 | 0.00 | 26.28 |
| RDS gp3 storage, Multi-AZ ($0.23/GB-month) | 20 GB | 0.00 | 4.60 |
| Secrets Manager secret | 1 | 0.00 | 0.40 |
| ACM public certificate, Cloudflare DNS | 1 | 0.00 | 0.00 (estimate, not priced) |
| **Total** | | **164.97** | **196.25** |

**Delta: +$31.28 per month** for the database tier and its secret.

> **Estimates, not measurements.** The public IPv4 address count is an
> estimate. The $0 for the ACM certificate and Cloudflare DNS is an estimate
> and was not priced. RDS backup storage is assumed to cost $0 at this size,
> which is also an estimate. Not priced in either column, and identical
> before and after: EC2 detailed monitoring metrics, root EBS volumes and SNS
> email.

> **Correction to earlier versions of this README.** They stated about $138
> per month for the previous architecture. That figure priced the NLB at
> $0.008 per hour (the Price List API returns $0.0225) and left out the public
> IPv4 address charges and the two WAF rules. The "Before" column above is the
> corrected figure.

> **NAT Gateway costs dominate** when instances are in private subnets: the
> two gateways are the largest line in the table before any traffic flows,
> and their data-processing charge is usage-based and not included. Use a
> VPC Endpoint for S3 and SSM to reduce NAT traffic.
>
> The WAFv2 web ACL is charged although it is not associated with any
> resource.
>
> Costs scale as the ASG adds instances. Use the
> [AWS Pricing Calculator](https://calculator.aws) for a precise estimate
> tailored to your instance count and traffic volume.

---

## Destroying the Stack

### Terraform

```bash
# If environment = "prod", disable NLB deletion protection first
aws elbv2 modify-load-balancer-attributes \
  --load-balancer-arn $(terraform output -raw nlb_arn) \
  --attributes Key=deletion_protection.enabled,Value=false

# If db_deletion_protection = true, set it to false in prod.tfvars and
# apply that change first; RDS refuses to delete a protected instance

# Export the Cloudflare API token: destroy also removes the two DNS records
export CLOUDFLARE_API_TOKEN="<your-cloudflare-api-token>"

# Then destroy all Terraform-managed resources
terraform destroy -var-file=prod.tfvars
```

What happens to the resources this revision adds:

| Resource | On `terraform destroy` |
|---|---|
| RDS DB instance | Deleted, including the standby. With the default `db_skip_final_snapshot = true` no final snapshot is taken and the data is gone |
| Final DB snapshot | Taken only when `db_skip_final_snapshot = false`, under the fixed name `scalable-webapp-prod-db-final`. It is not managed by Terraform and survives the destroy |
| Deletion protection | With `db_deletion_protection = true` the destroy fails at the DB instance until the variable is set back to `false` and applied |
| Master credential secret | Created and owned by RDS, not a Terraform resource. It is expected to be removed by RDS together with the DB instance; this has not been exercised on this stack, so check after a destroy that the ARN from `db_secret_arn` is gone |
| Cloudflare DNS records | Both records (the ACM validation CNAME and the hostname CNAME) are Terraform resources and are deleted. The hostname stops resolving |
| ACM certificate | Deleted. The next deploy requests a new certificate and creates a new validation record |
| Database subnets, route tables, DB subnet group, DB security group | Deleted with the rest of the VPC |

> **Production note:** a production stack would turn deletion protection on
> and keep a final snapshot. Because the final snapshot name is fixed, a
> second destroy that keeps a snapshot would collide with the first one;
> remove or copy the earlier snapshot before destroying again.

**Not managed by Terraform, and left in place by a destroy:**

- The EC2 key pair named in `var.key_pair_name`
- The Cloudflare zone itself and the API token
- A final DB snapshot, if one was kept
- The local `prod.tfvars` and any local state files

Everything else in the stack is a resource in this configuration, so
`terraform destroy` plans to remove it. A destroy of this revision has not
been run.

### AWS CLI (`Automation/deploy.sh`), Legacy Reference

> **Legacy reference for the pre-change architecture.** This applies only to
> a stack built with `Automation/deploy.sh`, which is HTTP only and has no
> database. Its cleanup section knows nothing about the RDS instance, the
> secret, the certificate or the DNS records of the current design.

Uncomment the `# CLEANUP` section at the bottom of `Automation/deploy.sh` and run it.
Resources must be deleted in this order to avoid dependency errors:

1. WAF disassociation → WAF ACL deletion
2. CloudWatch alarms
3. Scaling policies
4. ASG — set `min/max/desired` to `0`, wait for instance termination, then delete
5. NLB listener → Target group → NLB (wait for NLB deletion)
6. Launch template
7. NAT Gateways (wait ~90 seconds per gateway)
8. Release Elastic IPs
9. Detach and delete Internet Gateway
10. Delete subnets
11. Delete route tables
12. Delete security groups
13. Delete VPC
14. IAM: remove role from instance profile → delete instance profile → detach policy → delete role
15. SNS topic

---

## Frequently Asked Questions

**Q: The hostname resolves but connections time out or return nothing.**

A: First check the URL. The stack serves `https://<domain_name>` only: port 80
is closed, so `http://` fails to connect by design, and browsing to the NLB DNS name
directly gives a certificate name mismatch because the certificate covers
`var.domain_name` only. An NLB works at Layer 4 and never returns an HTTP 502
or 503 page of its own; a problem behind it shows up as a connection that
times out or is reset.

If `https://<domain_name>` itself fails, the instances are likely still
initialising or the web server has not yet passed health checks. Wait 3–5
minutes and retry. If it persists:

1. Check that the ASG has launched instances: `aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names scalable-webapp-prod-asg`
2. Check target health: `aws elbv2 describe-target-health --target-group-arn <tg_arn>`
3. Verify NAT Gateways are `available` so the user data script could reach the internet to install the web server
4. Connect via SSM and inspect the web server: `aws ssm start-session --target <instance-id>`
5. Check that the hostname CNAME points at the current NLB DNS name: `dig +short CNAME <domain_name>` against `terraform output -raw nlb_dns_name`

**Q: All instances appear in only one Availability Zone.**

A: The `cpu-low` alarm fires at near-0% CPU when there is no traffic, which
triggers a scale-in that reduces `desired` to `asg_min_size`. If `asg_min_size`
is `1`, only one instance survives. Keep `asg_min_size` at `2` to guarantee
multi-AZ coverage, or restore desired capacity manually:

```bash
aws autoscaling set-desired-capacity \
  --auto-scaling-group-name scalable-webapp-prod-asg \
  --desired-capacity 2 \
  --region us-east-1
```

**Q: HTTPS is built in now. Why does `http://` not work, and where is the redirect?**

A: The stack always creates a `TLS:443` listener with its own ACM certificate,
so there is nothing to add for HTTPS; the old `acm_certificate_arn` variable is
gone. Port 80 is closed on purpose: there is no listener and no security group
rule for it. An NLB can only forward connections, it cannot answer with a
redirect, so `http://` requests fail to connect instead of being sent to
`https://`. If you need a redirect, put an ALB in front, or keep a TCP 80
listener that forwards to a second target group where Nginx or Apache answers
`301`. To serve a different hostname, change `domain_name` (and
`cloudflare_zone_id` if the zone changes) and re-run `terraform apply`.

**Q: The page says `Database: unreachable`. What do I check?**

A: The line is a boot-time snapshot, so refreshing the page does not re-run
the check. Each instance tries 5 times, 5 seconds apart, then writes the
result once. Work through these, then replace the instance so that a new one
runs the check again (an instance refresh, shown under "How do I update the
application code?"):

1. The DB instance is `available`: `aws rds describe-db-instances --db-instance-identifier scalable-webapp-prod-db --query 'DBInstances[0].DBInstanceStatus'`
2. The DB security group still allows TCP 5432 from the EC2 security group
3. The instance role still has the inline policy `scalable-webapp-prod-db-secret-read`
4. The NAT Gateways are `available`: the instance reaches Secrets Manager, and the package repository for the PostgreSQL client, through them
5. A PostgreSQL client was installed. An AMI pinned through `ami_id` to an older Amazon Linux 2023 release may not carry `postgresql18`; the script falls back to `postgresql17`, `postgresql16` and `postgresql15`

If you see the web server's default page instead of the custom page, the
check has not finished yet. The custom page is written after the check,
which takes at worst about 95 seconds (calculated, not measured).

**Q: What happens when the database primary fails?**

A: RDS fails over to the synchronous standby in the other AZ and keeps the
same endpoint name, so nothing in Terraform or on the instances changes. AWS
documents a typical failover time of 60 to 120 seconds; it has not been
exercised on this stack. The web tier keeps serving during a failover because
NLB health checks do not depend on the database. The `Database:` line on
each page does not change either, since it is a snapshot taken at boot.

**Q: Where is the second RDS instance? Can I read from the standby?**

A: No. A Multi-AZ DB instance deployment shows as one DB identifier marked
Multi-AZ in the RDS console, with one endpoint. The standby is a synchronous
copy in a second AZ that exists for availability; it has no endpoint and
cannot be queried, so it adds no read capacity. A read replica would give a
second, readable instance, but it is a different design: asynchronous, with
manual promotion, and not supported together with an RDS-managed master
password. It is out of scope for this stack.

**Q: How do I update the application code?**

A: Update the user data script in `main.tf` and run `terraform apply`. Terraform
creates a new Launch Template version. To replace running instances without
downtime, trigger an instance refresh:

```bash
aws autoscaling start-instance-refresh \
  --auto-scaling-group-name scalable-webapp-prod-asg \
  --preferences MinHealthyPercentage=50,InstanceWarmup=300 \
  --region us-east-1
```

**Q: How do I enable remote Terraform state for a team?**

A: Create an S3 bucket (versioning enabled, SSE-S3 or SSE-KMS) and a DynamoDB
table with partition key `LockID` (String). Then uncomment the `backend "s3"`
block in `provider.tf`:

```hcl
backend "s3" {
  bucket         = "your-tfstate-bucket"
  key            = "scalable-webapp/terraform.tfstate"
  region         = "us-east-1"
  encrypt        = true
  dynamodb_table = "terraform-state-lock"
}
```

Re-run `terraform init` to migrate local state to S3.

**Q: Why Simple Scaling instead of Target Tracking?**

A: Simple Scaling gives a **dead band** between the scale-in and scale-out
thresholds (30%–70%), preventing oscillation when CPU hovers at a single value.
Target Tracking converges to a single target CPU percentage — any deviation
triggers immediate action in both directions. Simple Scaling also has an
explicit cooldown period per direction, which prevents rapid back-to-back
scaling actions. The trade-off is slower reaction to sudden spikes; if sub-60-
second scale-out is required, use a Target Tracking policy set to 50%–60% CPU.

**Q: Why is the NLB used instead of an ALB?**

A: The NLB operates at Layer 4 (TCP/TLS) and preserves the client's source IP
address natively. It handles millions of requests per second with ultra-low
latency, and supports static Elastic IP addresses per AZ — useful for
allowlisting in corporate firewalls. Use an ALB if you need HTTP-level features
such as path-based routing, host-based routing, request header manipulation,
or HTTP-to-HTTPS redirects.

---

## Deployment Issues Encountered (June 2026)

> These issues are from the June 2026 deployment of the previous architecture
> (HTTP only on TCP 80, no database tier). They are kept as a record. The
> HTTPS and RDS revision has not been deployed, so it has no deployment
> issues to report yet.

Real issues hit during the first deployment of this project, with root causes and fixes.

---

**Issue 1: `terraform apply` failed — "Invalid id: ami-00fa360e28f425da0 " (trailing space)**

**Symptom:** The Auto Scaling Group creation failed immediately with:
```
ValidationError: You must use a valid fully-formed launch template.
Invalid id: "ami-00fa360e28f425da0 "
```

**Root cause:** A trailing space was accidentally included when pasting the AMI ID into `prod.tfvars`:
```hcl
ami_id = "ami-00fa360e28f425da0 "   # ← trailing space after the ID
```
The Launch Template was created with the invalid AMI ID. The ASG then rejected
it at creation time because Auto Scaling validates the AMI ID against EC2.

**Fix:** Remove the trailing space in `prod.tfvars`:
```hcl
ami_id = "ami-00fa360e28f425da0"
```
Re-run `terraform apply`. Terraform updated the Launch Template in-place (v1 → v2)
and then created the ASG successfully. The 39 resources already created were not
affected — only the Launch Template was updated and the 5 remaining resources were
created.

**Prevention:** Always verify the AMI ID before applying:
```bash
grep ami_id prod.tfvars | cat -A   # cat -A shows trailing spaces as $
```

> In the HTTPS and RDS revision `ami_id` is optional, and a validation rule
> in `variables.tf` rejects a value with surrounding whitespace.

---

**Issue 2: `terraform apply` failed — WAFv2 association rejected by AWS**

**Symptom:** The original `main.tf` included `aws_wafv2_web_acl_association` linking
the WAF ACL to the NLB ARN. AWS rejected this with:
```
ValidationException: Resource ARN must be for an Application Load Balancer
```

**Root cause:** WAFv2 Web ACL associations are only supported on **Layer 7** resources
(ALB, API Gateway, AppSync, Cognito, App Runner, Verified Access). A Network Load
Balancer operates at **Layer 4 (TCP/TLS)** and cannot inspect HTTP headers — WAF has
nothing to intercept.

**Fix:** Removed the `aws_wafv2_web_acl_association` resource block from `main.tf`.
The `aws_wafv2_web_acl` resource itself is kept — the ACL is provisioned and its ARN
is exported — so it can be associated with an ALB if one is placed in front of the NLB
later.

**Prevention:** Check the [WAFv2 supported resource types](https://docs.aws.amazon.com/waf/latest/developerguide/waf-chapter.html) before adding a WAF association. NLB is not on the list.

---

**Issue 3: Both EC2 targets unhealthy — NLB health checks failing despite Nginx running**

**Symptom:** After `terraform apply` completed successfully, both targets showed
`Target.FailedHealthChecks` in the NLB target group. SSM confirmed Nginx was
`active` on both instances. TCP health checks on port 80 were still failing.

**Root cause:** The `aws_lb` resource was missing the `security_groups` argument:
```hcl
# BEFORE (broken)
resource "aws_lb" "web" {
  ...
  # security_groups not set — NLB had no SG attached
}
```
The EC2 security group allowed port 80 **only from the NLB security group**:
```hcl
ingress {
  security_groups = [aws_security_group.nlb.id]
}
```
Since the NLB had no SG attached, its network interfaces were not members of
`aws_security_group.nlb`. The EC2 SG rule never matched any traffic — including
NLB health check packets — so all connections were silently dropped.

**Fix:** Added `security_groups = [aws_security_group.nlb.id]` to the NLB resource:
```hcl
# AFTER (fixed)
resource "aws_lb" "web" {
  ...
  security_groups = [aws_security_group.nlb.id]
}
```
Because adding a security group forces NLB replacement, deletion protection
had to be disabled first:
```bash
aws elbv2 modify-load-balancer-attributes \
  --load-balancer-arn $(terraform output -raw nlb_arn) \
  --attributes Key=deletion_protection.enabled,Value=false
```
After `terraform apply`, both targets became healthy within 90 seconds (3 × 30 s
health check intervals).

**Prevention:** Always set `security_groups` on the `aws_lb` resource when you intend
to use security group references in target EC2 SG rules. Without it, the SG exists
but is not attached to the NLB's ENIs, and EC2 SG rules referencing it match nothing.

---

**Issue 4: `health_check.sh` — CloudWatch alarms section reported `[FAIL]` despite alarms existing**

**Symptom:** Running `./health_check.sh` showed:
```
[FAIL] No CloudWatch alarms found — were they deployed?
```
All 5 alarms were confirmed present via the AWS API.

**Root cause:** Two separate bugs combined to cause the failure.

*Bug A — Wrong alarm lookup method:* The script used `--alarm-names` with a
space-separated variable. Even a single unresolvable name in the list causes the
AWS CLI to return an empty result. This made the check fragile.

*Bug B — BSD `sed` whitespace parsing on macOS:* The `tfvar()` helper function
used `\s` in `sed` substitution patterns to strip whitespace around `=`:
```bash
sed 's/.*=\s*//; s/"//g; s/\s*$//'
```
macOS BSD `sed` does not reliably recognise `\s` as a whitespace class in all
contexts. When parsing `environment = "prod"`, the leading space after `=` was
not stripped, leaving `ENVIRONMENT=" prod"` (with a leading space). This caused
`ALARM_PREFIX` to become `scalable-webapp- prod` — a prefix that matched no
alarm names.

**Fix:**
1. Switched alarm lookup from `--alarm-names` to `--alarm-name-prefix "${ALARM_PREFIX}"` —
   prefix lookup returns all alarms sharing the prefix and never fails on a single
   missing name.
2. Replaced `\s` with `[[:space:]]` throughout the `tfvar()` sed pipeline and added
   an explicit leading-whitespace strip step for POSIX/BSD sed compatibility:
```bash
sed 's/.*=[[:space:]]*//' \
| sed 's/^[[:space:]]*//' \
| sed 's/[[:space:]]*$//' \
| sed 's/"//g'
```
3. Changed the `cpu-low` alarm from a `[FAIL]` condition to an informational note —
   it always fires on idle instances with no traffic, and `asg_min_size = 2` prevents
   it from actually scaling in below 2 instances.

**Prevention:** When writing shell scripts that parse `.tfvars` files on macOS, always
use POSIX character classes (`[[:space:]]`, `[[:alpha:]]`) instead of Perl-style
escapes (`\s`, `\w`) in `sed`, or switch to `grep -P` / `awk` for the parsing step.
