# Scalable Web App (ALB+ASG+RDS)

An infrastructure-as-code project that deploys a horizontally scalable web
application on AWS using Terraform. Clients reach an Application Load Balancer
over HTTPS on a hostname managed in Cloudflare DNS; plain HTTP on port 80 is
answered with a redirect to HTTPS. The load balancer distributes traffic across
EC2 instances in an Auto Scaling Group, which automatically adds or removes
instances in response to CPU load. Behind the instances sits a Multi-AZ RDS for
PostgreSQL deployment (a primary plus a synchronous standby), which each
instance checks once at boot.

> **Status (2026-10-07): the HTTPS and RDS revision described in this README is
> authored and validate-clean, not deployed.** `terraform apply` has not been
> run for it. The screenshots in `screenshots/` and the contents of `Result.md`
> record the June 2026 deployment of the previous architecture (HTTP only, no
> database tier). Resource IDs, the load balancer DNS name and alarm states
> quoted below also come from that June 2026 deployment and are marked as such.
>
> Checks run on this revision: `terraform fmt -check -recursive`,
> `terraform init`, `terraform validate` ("Success! The configuration is
> valid."), and `terraform plan` against an empty state with a placeholder
> Cloudflare token (`Plan: 36 to add, 0 to change, 0 to destroy.`). The user
> data script is clean under `bash -n` and `shellcheck` and was exercised
> against stub commands on a workstation only.
>
> Not run: `terraform apply`, the user data on a real instance, the database
> check against a real database, certificate issuance, the Cloudflare records,
> a plan with a real Cloudflare token, and a check in the account that the TLS
> policy exists.

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

---

## Architecture Overview

```
                      Browser: https://<domain_name>
                                     │
                                     │  Cloudflare DNS (DNS only): CNAME → ALB
                  ┌──────────────────▼──────────────────┐
                  │               Internet              │
                  └──────────────────┬──────────────────┘
                                     │
                  ┌──────────────────▼──────────────────┐
                  │           Internet Gateway          │
                  │        igw-076bdd124057cfb98        │
                  └──────────────────┬──────────────────┘
                                     │  HTTPS 443 (HTTP 80 is answered with a 301)
                  ┌──────────────────▼──────────────────┐
                  │   Application Load Balancer (ALB)   │
                  │   WebAppALB, internet-facing        │
                  │   HTTPS:443  ACM certificate        │
                  │   HTTP:80    redirect to HTTPS      │
                  └─────────┬─────────────────┬─────────┘
                            │  HTTP 80 in VPC │
           ┌────────────────▼───┐         ┌───▼────────────────┐
           │     us-east-1a     │         │     us-east-1b     │
           │    10.0.0.0/28     │         │    10.0.0.16/28    │
           │  ┌──────────────┐  │         │  ┌──────────────┐  │
           │  │ EC2 instance │  │         │  │ EC2 instance │  │
           │  │  t3.medium   │  │         │  │  t3.medium   │  │
           │  │ Amazon Linux │  │         │  │ Amazon Linux │  │
           │  │ 2023, Apache │  │         │  │ 2023, Apache │  │
           │  └──────────────┘  │         │  └──────────────┘  │
           └─────────┬──────────┘         └──────────┬─────────┘
                     └───────────────┬───────────────┘
                                     │  Auto Scaling Group (1 – 4 instances)
                                     │  Scale out: CPU > 60%
                                     │  Scale in:  CPU < 40%
                                     │
                                     │  TCP 5432 over TLS, one check at boot
       ┌─────────────────────────────▼─────────────────────────────┐
       │ Database subnets, local route only                        │
       │ 10.0.0.64/28 (us-east-1a) and 10.0.0.80/28 (us-east-1b)   │
       │ ┌────────────────────────┐        ┌─────────────────────┐ │
       │ │ RDS PostgreSQL primary ├─ sync ─┤ Standby, other AZ   │ │
       │ │ webapp-db              │        │ not readable        │ │
       │ └────────────────────────┘        └─────────────────────┘ │
       └───────────────────────────────────────────────────────────┘

   ┌──────────────────────────────────────────────────────────────────┐
   │  CloudWatch                                                      │
   │   • CPUUtilization HIGH alarm  ──►  scale-out policy             │
   │   • CPUUtilization LOW alarm   ──►  scale-in  policy             │
   └──────────────────────────────────────────────────────────────────┘
```

**Traffic flow:**
`User → Cloudflare DNS (CNAME, DNS only) → IGW → ALB (HTTPS 443, TLS ends here) → Target Group → EC2 instance (HTTP 80, Apache)`

A request to port 80 on the load balancer never reaches an instance: the
listener answers it with a `301` redirect to HTTPS. Each instance opens one
connection to the database when it boots (TCP 5432 over TLS) and records the
result as a status line on its page; page requests do not touch the database.

---

## Networking & Routing

> Resource IDs and the "Available IPs" and "State" values in this section were
> recorded at the June 2026 deployment of the previous architecture. The
> `us-east-1b` public subnet is created by Terraform, so it gets a new ID each
> time the stack is re-created. The database subnets and their route table
> belong to the revision that is not deployed, so they have no IDs yet and are
> listed by their `Name` tag.

### VPC

| Field | Value |
|---|---|
| **VPC ID** | `vpc-0b8ea2c5bf5093847` |
| **CIDR Block** | `10.0.0.0/24` |
| **Internet Gateway** | `igw-076bdd124057cfb98` (state: available) |

### Subnets

| Subnet | AZ | CIDR | Available IPs | Public IP on Launch | Managed by |
|---|---|---|---|---|---|
| `subnet-017d9e213cb1cd657` | us-east-1a | `10.0.0.0/28` | 9 | Yes | Pre-existing |
| `subnet-0ff2ce1b2900affd6` | us-east-1b | `10.0.0.16/28` | 10 | Yes | Terraform (`aws_subnet.web_1b`) |
| `WebApp-db-subnet-us-east-1a` (not created) | us-east-1a | `10.0.0.64/28` | — | No | Terraform (`aws_subnet.db["us-east-1a"]`) |
| `WebApp-db-subnet-us-east-1b` (not created) | us-east-1b | `10.0.0.80/28` | — | No | Terraform (`aws_subnet.db["us-east-1b"]`) |

The two database subnets come from one variable, `database_subnets`, a map of
Availability Zone name to CIDR block. The rows above show its defaults. The
ranges must be unused inside the VPC.

### Route Tables

| Route Table | Type | Destination | Target | State | Subnets |
|---|---|---|---|---|---|
| `rtb-09ef904e894338594` | Public | `10.0.0.0/24` | local | active | us-east-1a, us-east-1b |
| `rtb-09ef904e894338594` | Public | `0.0.0.0/0` | `igw-076bdd124057cfb98` | active | us-east-1a, us-east-1b |
| `rtb-090756b8feaaaa054` | Main (private) | `10.0.0.0/24` | local | active | — (no subnets assigned) |
| `WebApp-db-rt` (not created) | Database | `10.0.0.0/24` | local | — | Both database subnets |

> Both public subnets share the public route table so EC2 instances can reach
> the internet via the IGW during boot — required for the `dnf install` steps in
> user data and for the instances' calls to Secrets Manager and Systems Manager.

> The database route table (`aws_route_table.db`) holds only the implicit local
> route for the VPC CIDR, so the database subnets have no path to an internet
> gateway or a NAT gateway. It is declared with `route = []`, which makes
> Terraform remove any route added to that table by hand.

### Traffic Flow

```
Internet
    │
    │  DNS: <domain_name> CNAME → ALB DNS name (Cloudflare, DNS only)
    ▼  0.0.0.0/0 → igw-076bdd124057cfb98
Internet Gateway
    │
    ▼
Application Load Balancer (WebAppALB)
    ├── subnet-017d9e213cb1cd657  (us-east-1a, 10.0.0.0/28)
    └── subnet-0ff2ce1b2900affd6  (us-east-1b, 10.0.0.16/28)
    │
    ├── HTTP:80   → 301 redirect to HTTPS:443 (goes no further)
    ▼  HTTPS:443 → TLS ends at the ALB → HTTP:80 → Target Group (WebApp-tg)
EC2 Instances (Auto Scaling Group)
    ├── us-east-1a  (10.0.0.0/28)
    └── us-east-1b  (10.0.0.16/28)
    │
    ▼  TCP 5432 over TLS, local route only (one check at boot)
RDS for PostgreSQL (webapp-db), Multi-AZ primary and standby
    ├── us-east-1a  (10.0.0.64/28)
    └── us-east-1b  (10.0.0.80/28)
```

---

## Component Details

Resource names below assume the default `app_name = "WebApp"`.

### 1. Security Groups (`WebApp-alb-sg`, `WebApp-ec2-sg`, `WebApp-db-sg`)

One security group per tier replaces the single shared group (`WebApp-sg`) of
the previous architecture. Every rule is its own Terraform resource.

| Group | Direction | Protocol | Port | Source / Destination | Purpose |
|-------|-----------|----------|------|----------------------|---------|
| `WebApp-alb-sg` | Inbound  | TCP | 80   | 0.0.0.0/0 | HTTP from the internet, redirected to HTTPS by the listener |
| `WebApp-alb-sg` | Inbound  | TCP | 443  | 0.0.0.0/0 | HTTPS from the internet |
| `WebApp-alb-sg` | Outbound | All | All  | 0.0.0.0/0 | Forwarding and health checks to the instances |
| `WebApp-ec2-sg` | Inbound  | TCP | 80   | `WebApp-alb-sg` (security group reference) | HTTP from the load balancer only |
| `WebApp-ec2-sg` | Outbound | All | All  | 0.0.0.0/0 | Package repositories, Secrets Manager and Systems Manager over HTTPS; the database on 5432 |
| `WebApp-db-sg`  | Inbound  | TCP | 5432 | `WebApp-ec2-sg` (security group reference) | PostgreSQL from the instances only |

`WebApp-ec2-sg` has no rule for port 22 and none for port 443. `WebApp-db-sg`
has one ingress rule and no egress rule.

> **Production note:** Port 22 is not open anywhere. Shell access to an
> instance is through Systems Manager Session Manager, which the instance role
> allows. The instances still sit in the public subnets with public IP
> addresses; it is the security group, not the subnet, that keeps the internet
> off port 80 on the instances.

---

### 2. Launch Template (`WebAppTemplate`)

| Attribute        | Value |
|------------------|-------|
| AMI              | Latest Amazon Linux 2023 x86_64 (standard image, default kernel), resolved at plan time from the public Systems Manager parameter `/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64`. There is no variable to override it |
| Instance Type    | `t3.medium` (2 vCPU, 4 GB RAM) |
| Key Pair         | None by default. `key_pair_name` is optional; port 22 is not open, so a key pair gives no access by itself |
| Security Group   | `WebApp-ec2-sg` |
| Instance Profile | `WebApp-ec2-profile` (role `WebApp-ec2-role`, described below) |
| Instance Metadata | IMDSv2 required (`http_tokens = "required"`), hop limit 1 |
| Detailed Monitoring | Enabled (1-minute CloudWatch metrics) |
| User Data        | Installs Apache httpd and serves a dynamic HTML page showing the instance ID, the AZ, the environment and a database status line; then installs the `postgresql18` client and runs the boot-time database check |

The launch template now **enforces IMDSv2**; in the previous architecture the
user data used IMDSv2 tokens but the template did not require them. The hop
limit of 1 keeps the metadata service, and with it the role credentials that
can read the database secret, on the instance itself. The HTML page updates
automatically per instance, making it easy to observe load balancing in action.

**Instance role (`WebApp-ec2-role`)**

| Attribute | Value |
|-----------|-------|
| Trusted service | `ec2.amazonaws.com` |
| Instance profile | `WebApp-ec2-profile` |
| Managed policy | `AmazonSSMManagedInstanceCore` (Session Manager) |
| Inline policy | `WebApp-db-secret-read`: `secretsmanager:GetSecretValue` on the one secret that RDS manages for the database master user |

The role and the instance profile are new in this revision; the previous
architecture attached no role to the instances.

**Boot sequence (user data, inline in `main.tf`)**

1. `dnf install -y httpd`, then read the instance ID and AZ from the metadata
   service with an IMDSv2 token.
2. Write the page with the database status line set to `unreachable`, and
   start Apache. From here on the load balancer health check can pass.
3. `dnf install -y postgresql18`, which is the only client package the script
   tries, and `awscli-2` only if the AMI does not already provide the `aws`
   command.
4. Run the database check: fetch the secret with the instance role and run
   `SELECT 1` through `psql`. At most five attempts, ten seconds apart.
5. Rewrite the page. The status line becomes `connected` only if an attempt
   succeeded.

The status line on the page is exactly
`<p>Database: <strong id="db-status">connected</strong></p>`, or the same line
with `unreachable`.

> **Caveats on the database check:**
> - It is a snapshot taken at boot. The line does not change if the database
>   later becomes unreachable, or reachable.
> - The page is served with `unreachable` first, so it can read `unreachable`
>   for up to about a minute after boot even when the database is reachable.
> - The connection uses `sslmode=require`, which encrypts it but does not
>   verify the server certificate.
> - It uses the master credential. That is acceptable for a connectivity proof
>   and not for a real application.
> - The page shows only `connected` or `unreachable`. The user name and
>   password are read from the secret at boot and are never in user data, on
>   the page, in a log or on disk. The database address, port and secret ARN
>   are templated into the user data; none of them is a credential.
> - The web server starts before the check, so load balancer health checks
>   never depend on the database.
> - The script has only been exercised against stub commands on a workstation.
>   Whether the Amazon Linux 2023 `postgresql18` client connects cleanly to a
>   PostgreSQL 18 server is unproven until a deploy.

---

### 3. Application Load Balancer (`WebAppALB`)

| Attribute        | Value |
|------------------|-------|
| Scheme           | Internet-facing |
| Type             | Application (Layer 7) |
| Security Group   | `WebApp-alb-sg` |
| Subnets          | The pre-existing public subnet given in `subnet_ids` (us-east-1a) plus the Terraform-managed us-east-1b subnet |
| Listener `HTTPS:443` | Presents the ACM certificate under the security policy in `ssl_policy` (default `ELBSecurityPolicy-TLS13-1-2-Res-PQ-2025-09`) and forwards to the target group |
| Listener `HTTP:80` | Answers every request with an `HTTP_301` redirect to HTTPS on port 443; carries no application traffic |
| Deletion Protection | Disabled (`enable_deletion_protection = false`) |
| DNS Name         | Assigned by AWS when the load balancer is created, and different after every re-create; read it with `terraform output alb_dns_name`. At the June 2026 deployment it was `WebAppALB-99455837.us-east-1.elb.amazonaws.com` |

TLS ends at the load balancer. From there to the instances a request travels
as HTTP on port 80 inside the VPC.

The ALB distributes traffic using a round-robin algorithm by default. Each
request lands on a healthy instance; if an instance fails health checks it is
drained and removed from rotation within ~90 seconds.

> **Before a deploy:** the security policy name was confirmed in AWS
> documentation only, not against the account. Confirm it with the read-only
> call in [Quick Start](#quick-start) before the first `apply`.

---

### 4. Target Group (`WebApp-tg`)

| Attribute               | Value |
|-------------------------|-------|
| Protocol / Port         | HTTP / 80 |
| Target Type             | Instance |
| Health Check Path       | `/` |
| Health Check Interval   | 30 seconds |
| Healthy Threshold       | 2 consecutive successes |
| Unhealthy Threshold     | 3 consecutive failures |
| Expected HTTP Status    | `200` |

Health checks run every 30 seconds. An instance must return two consecutive
`200 OK` responses before traffic is sent to it, and three consecutive failures
before it is marked unhealthy and traffic is redirected.

---

### 5. Auto Scaling Group (`WebAppASG`)

| Attribute              | Value |
|------------------------|-------|
| Desired capacity       | 2 (scales down to 1 under low CPU — see note below) |
| Minimum capacity       | 1 |
| Maximum capacity       | 4 |
| Health check type      | ELB (uses ALB health checks, not just EC2 status) |
| Health check grace period | 120 seconds (allows Apache to start before first check) |
| Subnets                | us-east-1a + us-east-1b |
| Created after          | The database instance, the secret-read policy, the Session Manager policy attachment and the HTTPS listener (explicit `depends_on`) |

> **Note:** The `cpu-low` alarm fires at ~0% CPU when there is no traffic,
> causing the ASG to scale in to `desired=1`. To prevent this, increase
> `evaluation_periods` in `main.tf` or add an `estimated_instance_warmup`
> to the scale-in policy.

> **Ordering:** instances run their database check once, at boot, so the ASG
> is created only after the database exists and the role can read its secret.
> It also waits for the HTTPS listener, which in turn waits for ACM to issue
> the certificate, so no instance launches before then.

---

### 6. Scaling Policies & CloudWatch Alarms

Two independent **Step Scaling** policies are used — one per direction — giving
explicit control over step sizes and cooldowns.

#### Scale-Out Policy

| Condition | Action |
|-----------|--------|
| CPU between 60% and 80% | Add **1** instance |
| CPU above 80%           | Add **2** instances (rapid spike) |

Triggered by the `cpu-high` CloudWatch alarm:
- Metric: `CPUUtilization` averaged across the ASG
- Period: 60 seconds
- Evaluation periods: 2 (alarm fires after 2 consecutive breaches)
- Threshold: > 60%
- State at the June 2026 deployment: **OK**

#### Scale-In Policy

| Condition | Action |
|-----------|--------|
| CPU below 40% | Remove **1** instance |

Triggered by the `cpu-low` CloudWatch alarm:
- Metric: `CPUUtilization` averaged across the ASG
- Period: 60 seconds
- Evaluation periods: 2
- Threshold: < 40%
- State at the June 2026 deployment: **ALARM** (idle instance, no traffic)

Both alarms use `treat_missing_data = "notBreaching"` to avoid spurious
scale-in events when an instance is terminating and stops publishing metrics.

---

### 7. RDS for PostgreSQL (`webapp-db`)

| Attribute | Value |
|-----------|-------|
| Identifier | `webapp-db`, from `lower("${var.app_name}-db")` |
| Engine | RDS for PostgreSQL, `engine_version = "18"` (major version only) with automatic minor version upgrades |
| Deployment | Multi-AZ DB instance deployment: a primary plus a synchronous standby in a second Availability Zone |
| Instance Class | `db.t3.micro` (`db_instance_class`) |
| Storage | 20 GB gp3, encrypted with the AWS-managed `aws/rds` key; storage autoscaling off |
| Master User | `dbadmin` (`db_master_username`). RDS generates the password and keeps it in Secrets Manager (`manage_master_user_password = true`) |
| Port | 5432 |
| Subnet Group | `webapp-db-subnet-group` (the two database subnets) |
| Security Group | `WebApp-db-sg` |
| Publicly Accessible | No |
| Automated Backups | 7 days (`db_backup_retention_period`) |
| Deletion Protection | Off by default (`db_deletion_protection`) |
| Final Snapshot | Skipped by default (`db_skip_final_snapshot`). When kept, it is named `webapp-db-final-snapshot` |

"Two instances" here means one Multi-AZ deployment. It appears under a single
DB identifier and has a single endpoint; the standby exists for failover and
cannot be queried.

There is no password argument and no password variable anywhere in the
configuration. Terraform is given no password; it reads back the ARN of the
secret, which is exposed as the `db_secret_arn` output.

> **Production note:** the defaults suit a stack that is created and destroyed
> often. A production stack would turn deletion protection on
> (`db_deletion_protection = true`) and keep a final snapshot
> (`db_skip_final_snapshot = false`).

> **Instance class:** the default is `db.t3.micro` because the class first
> proposed, `db.t4g.micro`, returned no orderable options for this account in
> `us-east-1` on 2026-10-07 (`DescribeOrderableDBInstanceOptions`).

> **Not configured:** CloudWatch alarms for the database, Performance
> Insights, enhanced monitoring, a custom parameter group and a
> customer-managed KMS key are all outside this revision.

---

### 8. Certificate and DNS Records

| Resource | Terraform address | Details |
|----------|-------------------|---------|
| ACM certificate | `aws_acm_certificate.web` | Public certificate for `domain_name`, validated through DNS, requested in the stack's region (`us-east-1` by default); `Name` tag `WebApp-cert` |
| Validation record | `cloudflare_dns_record.acm_validation` | CNAME built from the record name and value that ACM returns (trailing dot trimmed), TTL 60, DNS only (not proxied) |
| Issuance wait | `aws_acm_certificate_validation.web` | Waits until ACM has issued the certificate. The HTTPS listener takes the certificate ARN from this resource, so it is not created before issuance |
| Hostname record | `cloudflare_dns_record.web` | CNAME from `domain_name` to the load balancer DNS name, TTL 60, DNS only (not proxied) |

The hostname approved for this project is `webapp-alb.aterpise.com`, in the
Cloudflare zone `aterpise.com`. Both records are managed through the
`cloudflare/cloudflare` provider (`~> 5.0`). The provider reads its API token
only from the `CLOUDFLARE_API_TOKEN` environment variable; the token is never
a Terraform variable and never goes in a tfvars file.

> **Caveats:**
> - The validation record must stay in place for as long as the certificate is
>   in use, because ACM renews the certificate through it.
> - Both records are DNS only. With Cloudflare's proxy turned on, clients would
>   negotiate TLS with Cloudflare rather than with the listener described
>   above; proxying is outside this revision.
> - Certificate issuance and both Cloudflare records are unexercised: nothing
>   has been applied.

---

## Directory Structure

```
.
├── main.tf                        # Providers, data source, and all resource definitions (user data is inline)
├── variables.tf                   # Input variable declarations with descriptions & validation
├── outputs.tf                     # Values exported after apply (HTTPS URL, ALB DNS name, DB endpoint, etc.)
├── terraform.tfvars.example       # Sample variable values with placeholders — copy to terraform.tfvars
├── .gitignore                     # Keeps state, tfvars, plan files and private keys out of git
├── Automation/
│   ├── check-alb.sh               # Read-only post-deploy check script (see Quick Start, step 9)
│   ├── deploy.sh                  # Legacy AWS CLI reference for the pre-change architecture (HTTP only, no database)
│   └── .gitignore                 # Ignores generated reports and temporary files
├── Result.md                      # Architecture audit of the June 2026 deployment — rewritten by the /audit skill
├── screenshots/
│   ├── webapp-running.png         # Web app served through the ALB (June 2026 deployment)
│   └── ec2-instances.png          # EC2 console showing ASG instances (June 2026 deployment)
└── README.md                      # This file
```

`terraform.tfvars` is not in the repository. You create it from
`terraform.tfvars.example`; it holds real VPC, subnet and route table IDs and
is git-ignored. `variables.tf` is tracked in git as of this revision (it was
git-ignored before), and `terraform.tfvars.example` is new.

> **`Automation/deploy.sh` is a legacy reference.** It builds the pre-change
> architecture with the AWS CLI: one shared security group, an HTTP listener
> only, and no database. It has not been updated for this revision and should
> not be used to create the design described in this README.

---

## Prerequisites

| Tool      | Minimum Version | Install |
|-----------|-----------------|---------|
| Terraform | 1.9.0           | https://developer.hashicorp.com/terraform/install |
| AWS CLI   | 2.x             | https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html |
| AWS credentials | — | `aws configure` or environment variables |
| Cloudflare API token | — | Created in the Cloudflare dashboard with Zone / DNS / Edit permission on the one zone; exported as `CLOUDFLARE_API_TOKEN` |

The Terraform minimum is now 1.9.0 (it was 1.6.0), because `variables.tf` has
validation rules that refer to other variables, which Terraform accepts only
from 1.9.

You also need:

- An existing AWS VPC with at least one public subnet, and a route table in it
  that has a `0.0.0.0/0` route to an internet gateway. The `us-east-1b` public
  subnet is created and managed by this Terraform configuration.
- Two unused CIDR ranges inside that VPC for the database subnets
  (`database_subnets`; the defaults are `10.0.0.64/28` and `10.0.0.80/28`).
- A hostname in a Cloudflare zone you can manage (`domain_name`) and the ID of
  that zone (`cloudflare_zone_id`). The hostname approved for this project is
  `webapp-alb.aterpise.com`.

> `.terraform.lock.hcl` is git-ignored in this repository, so provider versions
> are constrained (`~> 5.0` for both `hashicorp/aws` and
> `cloudflare/cloudflare`) but not pinned. The checks listed at the top of this
> README resolved Terraform `1.15.1`, `hashicorp/aws` `5.100.0` and
> `cloudflare/cloudflare` `5.27.0`.

### Before a deploy

1. Create a Cloudflare API token with Zone / DNS / Edit on `aterpise.com` and
   export it as `CLOUDFLARE_API_TOKEN`. It never goes in a file. The token is
   required before `terraform plan` and `terraform apply`.
2. Put `domain_name` and `cloudflare_zone_id` in your local `terraform.tfvars`,
   alongside `vpc_id`, `subnet_ids` and `public_route_table_id`.
3. Confirm the TLS policy name with a read-only `describe-ssl-policies` call
   for load balancer type `application` (step 4 of Quick Start).
4. Get explicit approval for `terraform apply`. It has not been given for this
   revision.

---

## Quick Start

```bash
# 1. Clone / enter the project directory
cd "Scalable Web App (ALB+ASG+RDS)"

# 2. Create your variable file from the example and fill in your real values
#    Required: vpc_id, subnet_ids, public_route_table_id, domain_name, cloudflare_zone_id
cp terraform.tfvars.example terraform.tfvars
vim terraform.tfvars

# 3. Export the Cloudflare API token (Zone / DNS / Edit on the zone).
#    Required before plan and apply. Never put it in a file.
export CLOUDFLARE_API_TOKEN=...

# 4. Confirm the TLS policy exists for Application Load Balancers (read-only)
aws elbv2 describe-ssl-policies \
  --names ELBSecurityPolicy-TLS13-1-2-Res-PQ-2025-09 \
  --load-balancer-type application \
  --region us-east-1

# 5. Initialise Terraform (downloads the AWS and Cloudflare providers)
terraform init

# 6. Preview the execution plan
terraform plan -var-file=terraform.tfvars

# 7. Deploy — only with explicit approval (type "yes" when prompted)
terraform apply -var-file=terraform.tfvars

# 8. Visit the application
terraform output https_url

# 9. Run the post-deploy check script (read-only; needs aws, python3 and curl).
#    The optional argument is the hostname. It defaults to webapp-alb.aterpise.com.
./Automation/check-alb.sh
./Automation/check-alb.sh <hostname>      # only if domain_name is a different hostname

# 10. Run the architecture audit skill
# Type /audit in Claude Code to check all resources and update Result.md
```

> **Status:** `terraform init` and `terraform plan` have been run for this
> revision, the plan with a placeholder Cloudflare token against an empty
> state. The call in step 4 has not been run. `terraform apply` (step 7) has
> not been run and is not approved, so steps 8 to 10 have not been run either.

`Automation/check-alb.sh` (step 9) is a read-only check to run after a deploy.
It checks that the load balancer is up and serving traffic, and that the HTTPS
and database parts of this revision are in the expected state:

- It requests the page at `https://<hostname>`, with the certificate checked.
- It expects port 80 to answer with a 301 redirect to HTTPS.
- It expects the database instance to be available, Multi-AZ, not publicly
  accessible and encrypted, the database security group to admit only the
  instance security group, and the page to report `connected`.

It makes read-only AWS calls only and prints `[OK]`, `[WARN]` and `[FAIL]`
lines. The region and the resource names inside it follow the defaults
(`us-east-1`, `app_name = "WebApp"`).

`apply` creates the database and waits for ACM to issue the certificate before
it launches any instance. How long that takes has not been measured for this
revision.

Allow **2–3 minutes** after `apply` completes for the EC2 instances to pass
their health checks before the ALB begins forwarding traffic. That figure is
carried over from this README as written for the previous architecture and has
not been measured for this revision; the health check settings are unchanged.
The database status line on the page can read `unreachable` for up to about a
minute after an instance boots.

---

## Input Variables

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `region` | `string` | `"us-east-1"` | AWS region |
| `app_name` | `string` | `"WebApp"` | Prefix for all resource names |
| `environment` | `string` | `"production"` | Deployment environment |
| `vpc_id` | `string` | *(required)* | Existing VPC ID |
| `subnet_ids` | `list(string)` | *(required)* | Pre-existing subnet IDs (e.g. us-east-1a). The us-east-1b subnet is Terraform-managed and appended automatically |
| `public_route_table_id` | `string` | *(required)* | Route table ID with `0.0.0.0/0 → IGW` — used to make the us-east-1b subnet public |
| `database_subnets` | `map(string)` | `{ "us-east-1a" = "10.0.0.64/28", "us-east-1b" = "10.0.0.80/28" }` | Database subnets to create, as a map of Availability Zone name to CIDR block. The ranges must be unused inside the VPC |
| `domain_name` | `string` | *(required)* | Fully qualified hostname the application is served on, in lower case. The certificate is issued for it and a Cloudflare CNAME points it at the load balancer |
| `cloudflare_zone_id` | `string` | *(required)* | ID of the Cloudflare zone that holds `domain_name` (the 32-character hexadecimal identifier, not the zone name) |
| `ssl_policy` | `string` | `"ELBSecurityPolicy-TLS13-1-2-Res-PQ-2025-09"` | Elastic Load Balancing security policy for the `HTTPS:443` listener |
| `instance_type` | `string` | `"t3.medium"` | EC2 instance type |
| `key_pair_name` | `string` | `""` | Existing EC2 key pair to associate with the instances (optional). Port 22 is not open; shell access is through Session Manager |
| `db_instance_class` | `string` | `"db.t3.micro"` | RDS DB instance class. Must be orderable for PostgreSQL in a Multi-AZ deployment in the target region |
| `db_master_username` | `string` | `"dbadmin"` | Master user name for the database |
| `db_backup_retention_period` | `number` | `7` | Days to keep automated database backups (0 to 35; 0 turns them off) |
| `db_deletion_protection` | `bool` | `false` | Turn on RDS deletion protection |
| `db_skip_final_snapshot` | `bool` | `true` | Skip the final snapshot when the database is destroyed |
| `asg_desired` | `number` | `2` | Desired instance count |
| `asg_min` | `number` | `1` | Minimum instance count |
| `asg_max` | `number` | `4` | Maximum instance count |
| `scale_out_cpu_threshold` | `number` | `60` | CPU % that triggers scale-out |
| `scale_in_cpu_threshold` | `number` | `40` | CPU % that triggers scale-in |

There is no variable for the database password, for the Cloudflare API token
or for the AMI. RDS generates the password, the token comes from the
environment, and the AMI is whichever Amazon Linux 2023 image is latest when
`terraform plan` runs.

**Cross-variable validation rules** (these are why Terraform 1.9 or later is
required):

- `asg_desired` must be between `asg_min` and `asg_max`, inclusive.
- `scale_in_cpu_threshold` must be greater than 0 and less than
  `scale_out_cpu_threshold`.

**Single-variable validation rules:**

- `subnet_ids` must contain at least one subnet ID.
- `database_subnets` must name at least two Availability Zones, and every
  value must be a valid IPv4 CIDR block.
- `domain_name` must be a lower-case fully qualified hostname with no trailing
  dot and no wildcard.
- `cloudflare_zone_id` must be the 32-character lower-case hexadecimal zone ID.
- `db_master_username` must be 1 to 63 characters, start with a letter, contain
  only letters, digits and underscores, and not be `admin` or `rdsadmin`.
- `db_backup_retention_period` must be between 0 and 35.
- `scale_out_cpu_threshold` must be between 1 and 100.

Terraform rejects a value that breaks any of these rules before any AWS API
calls are made.

---

## Outputs

| Output | Description |
|--------|-------------|
| `https_url` | HTTPS URL of the application (`https://<domain_name>`) — use as your app's entry point |
| `alb_dns_name` | Public DNS name of the load balancer, with no scheme. The Cloudflare CNAME for `domain_name` points here |
| `alb_arn` | ARN of the ALB |
| `certificate_arn` | ARN of the ACM certificate attached to the HTTPS listener |
| `target_group_arn` | ARN of the ALB Target Group |
| `asg_name` | Name of the Auto Scaling Group |
| `launch_template_id` | ID of the EC2 Launch Template |
| `launch_template_latest_version` | Current latest version number |
| `alb_security_group_id` | ID of the load balancer security group |
| `ec2_security_group_id` | ID of the instance security group |
| `db_security_group_id` | ID of the database security group |
| `ami_id` | Amazon Linux 2023 AMI ID resolved at plan time |
| `db_instance_identifier` | Identifier of the RDS DB instance |
| `db_endpoint` | Connection endpoint of the RDS DB instance, as `host:port`. Reachable from the instance security group only |
| `db_secret_arn` | ARN of the Secrets Manager secret that RDS manages for the master user. The ARN only; the secret value is never an output |

Retrieve any output after apply:

```bash
terraform output https_url
terraform output -raw alb_dns_name
terraform output -json          # all outputs as JSON
```

> **Changed from the previous architecture.** Anything that reads these
> outputs needs updating:
> - `security_group_id` is gone. It is replaced by `alb_security_group_id`,
>   `ec2_security_group_id` and `db_security_group_id`.
> - `alb_dns_name` is now the bare DNS name. It used to be an `http://` URL.
> - `ami_id` now reports an Amazon Linux 2023 AMI. It used to report an Amazon
>   Linux 2 AMI.
> - New: `https_url`, `certificate_arn`, `db_instance_identifier`,
>   `db_endpoint` and `db_secret_arn`.

---

## Scaling Behaviour

```
CPU %  │
  100  │
   80  │              ┌─────────────────────────────────  +2 instances
   60  │         ─────┘  scale-out threshold              +1 instance
   40  │  scale-in threshold ─────┐
   20  │                          └─────────────────────  -1 instance
    0  └──────────────────────────────────────────────────────► time
```

**Dead band (40%–60%):** No scaling action occurs in this range, preventing
oscillation when CPU hovers near a threshold.

**Evaluation periods = 2:** The alarm must breach the threshold for two
consecutive 60-second periods (2 minutes total) before firing. This prevents
reactions to momentary CPU spikes.

**Scale-out step sizes:**
- Moderate load (60%–80%): +1 instance — gradual scale for sustained but
  manageable traffic growth.
- Heavy load (>80%): +2 instances — faster reaction to sudden traffic spikes.

---

## Tagging Strategy

Every resource receives three standard tags applied via the provider's
`default_tags` block, plus a per-resource `Name` tag:

| Tag Key     | Value |
|-------------|-------|
| `Name`      | Unique per resource (e.g. `WebAppALB`, `WebApp-alb-sg`, `webapp-db`) |
| `Environment` | Value of `var.environment` (default: `production`) |
| `ManagedBy` | `terraform` |
| `Project`   | Value of `var.app_name` (default: `WebApp`) |

Because ASG tag propagation uses a different mechanism than provider
`default_tags`, ASG instances receive their tags explicitly via `tag {}` blocks
inside `aws_autoscaling_group`.

Two things created by this revision sit outside that scheme:

- The two Cloudflare DNS records are not AWS resources and carry no AWS tags.
  Each has a `comment` that says it is managed by Terraform.
- The Secrets Manager secret for the database master user is created by RDS,
  not by a Terraform resource, so Terraform sets no tags on it.

---

## Security Considerations

"Current posture" describes the configuration as authored in this revision.
None of it is running.

| Topic | Current posture | Recommended hardening |
|-------|-----------------|----------------------|
| SSH access | Port 22 is not open in any security group. Shell access is through Systems Manager Session Manager (`AmazonSSMManagedInstanceCore` on the instance role) | Leave `key_pair_name` empty so that no key pair is associated |
| HTTPS | `HTTPS:443` listener with an ACM certificate and the `ssl_policy` security policy; `HTTP:80` answers `HTTP_301` to HTTPS | Confirm the security policy name in the account before the first `apply` |
| TLS behind the load balancer | TLS ends at the ALB; ALB to instance is HTTP on port 80 inside the VPC | Use an HTTPS target group with certificates on the instances if a compliance requirement calls for it |
| Security groups | One per tier. Instances accept port 80 from the ALB group only; the database accepts 5432 from the instance group only | — |
| Instance placement | Instances are in the public subnets and have public IP addresses | Move them to private subnets behind a NAT gateway |
| Subnet size | Both public subnets are `/28` and hold the ALB nodes as well as the instances | AWS advises ALB subnets of at least `/27` with eight free addresses |
| IMDSv2 | Required by the launch template (`http_tokens = "required"`), hop limit 1 | — |
| Instance role | `AmazonSSMManagedInstanceCore`, plus `secretsmanager:GetSecretValue` on one secret ARN | — |
| Secrets | RDS generates the database master password and keeps it in Secrets Manager. There is no password variable, and the password is not in tfvars or in user data | — |
| Database credential used by the app tier | The boot-time check uses the master credential | Create a dedicated, least-privilege database user for a real application |
| Database connection | `sslmode=require`: encrypted, but with no check of the server certificate | Use `sslmode=verify-full` with the RDS certificate bundle |
| Database exposure | Not publicly accessible; subnets with a local route only | — |
| Database encryption at rest | Storage encrypted with the AWS-managed `aws/rds` key | Use a customer-managed KMS key |
| Database monitoring | No alarms on the database | Add CloudWatch alarms for the DB instance |
| Deletion protection | Disabled on the ALB and on the database; no final snapshot by default | In production set `enable_deletion_protection = true` on the ALB, `db_deletion_protection = true` and `db_skip_final_snapshot = false` |
| Cloudflare API token | Read from `CLOUDFLARE_API_TOKEN` only; never a variable, never in a file | Scope it to Zone / DNS / Edit on the one zone |
| User data contents | The database address, port and secret ARN are templated into the user data. None is a credential | — |
| State file | Local backend | Use an S3 backend with DynamoDB state locking for team use |

> **Production note:** a production stack would turn deletion protection on
> and keep a final snapshot. The defaults here are for a stack that is created
> and destroyed often and holds no real data.

---

## Cost Estimate

Basis: AWS Price List API, us-east-1, on-demand, 730 hours per month, idle
baseline, queried 2026-10-07. Usage-based charges (LCU, NAT data processing,
data transfer) are excluded.

| Resource | Quantity | Previous architecture, monthly cost (USD) | This revision, monthly cost (USD) |
|----------|----------|-------------------------------------------|-----------------------------------|
| EC2 `t3.medium` ($0.0416/h) | 2 | 60.74 | 60.74 |
| Application Load Balancer ($0.0225/h) | 1 | 16.43 | 16.43 |
| Public IPv4 address ($0.005/h) | 4 (estimate: 2 ALB, 2 instances) | 14.60 | 14.60 |
| CloudWatch alarms ($0.10 each) | 2 | 0.20 | 0.20 |
| RDS PostgreSQL `db.t3.micro` Multi-AZ ($0.036/h) | 1 | 0.00 | 26.28 |
| RDS gp3 storage, Multi-AZ ($0.23/GB-month) | 20 GB | 0.00 | 4.60 |
| Secrets Manager secret | 1 | 0.00 | 0.40 |
| ACM public certificate, Cloudflare DNS | 1 | 0.00 | 0.00 (estimate, not priced) |
| **Total** | | **91.97** | **123.25** |

The revision adds **$31.28 per month** over the previous architecture.

> **Correction to the earlier figure.** This README used to state about $78
> per month for the previous architecture. That figure left out the public
> IPv4 address charge. The "previous architecture" column above is the
> corrected figure.

> **Estimates and exclusions.** The public IPv4 address count is an estimate.
> RDS backup storage is assumed to cost $0 at this size, which is also an
> estimate. Not priced, and the same before and after: EC2 detailed monitoring
> metrics and root EBS volumes. Nothing is running, so none of these figures
> has been checked against a bill.

Costs rise as the ASG adds instances. Use [AWS Pricing Calculator](https://calculator.aws) for a precise estimate tailored to your traffic profile.

---

## Destroying the Stack

```bash
export CLOUDFLARE_API_TOKEN=...   # destroy removes the two Cloudflare records
terraform destroy -var-file=terraform.tfvars
```

This removes all Terraform-managed resources including the `us-east-1b` subnet.
The pre-existing VPC, `us-east-1a` subnet, route table, and internet gateway
are **not** managed by this config and will not be affected.

> `destroy` has not been run for this revision. The notes below describe what
> the configuration does, not an observed run.

### Before you destroy

| Item | What to do |
|------|------------|
| Deletion protection | If `db_deletion_protection` is `true`, set it to `false` and run `terraform apply` first. With the default (`false`) there is nothing to do |
| Final snapshot | With the default (`db_skip_final_snapshot = true`) the database is deleted with no final snapshot. To keep one, set `db_skip_final_snapshot = false` and run `terraform apply` before destroying; the snapshot is named `webapp-db-final-snapshot` |
| Secret ARN | Note the value of `terraform output db_secret_arn` so that you can check afterwards that the secret is gone |
| Cloudflare token | Export `CLOUDFLARE_API_TOKEN`, as shown above |

### What is removed

- The database (`webapp-db`), its subnet group, the two database subnets and
  their route table.
- The ACM certificate and both Cloudflare DNS records (the hostname CNAME and
  the ACM validation CNAME). After a destroy the hostname no longer resolves.
- The load balancer, both listeners, the target group, the launch template,
  the Auto Scaling Group and its instances, the scaling policies and alarms.
- The three security groups, the IAM role and the instance profile.
- The `us-east-1b` public subnet and its route table association.

### What survives

| Item | Why |
|------|-----|
| The VPC, the `us-east-1a` subnet, the public route table and the internet gateway | Pre-existing; not managed by this config |
| The Cloudflare zone | Only the two records in it are managed here |
| A final snapshot, if you chose to keep one | Snapshots outlive the database. The name is fixed, so a later destroy that also keeps a snapshot collides with it unless the earlier snapshot is deleted first |
| The EC2 key pair, if `key_pair_name` was set | Referenced by name; not managed by this config |

> **The master user secret is not a Terraform resource.** RDS created it and
> RDS owns its lifecycle; Terraform holds only its ARN. `terraform destroy`
> deletes the database and leaves the removal of the secret to RDS. Check
> afterwards that the secret is gone.

> **Production note:** a production stack would turn deletion protection on
> and keep a final snapshot, so that a destroy cannot silently discard data.

---

## Frequently Asked Questions

> Answers about HTTPS, the database and Session Manager describe the revision
> as authored. They have not been exercised against a running stack.

**Q: The hostname resolves but returns 502 Bad Gateway.**
A: The instances are still starting or Apache has not yet passed health checks.
Wait 2–3 minutes and retry. If it persists, check that both public subnets have
`map_public_ip_on_launch = true` and are associated with a route table that has
a `0.0.0.0/0 → IGW` route — instances need internet access during boot to run
`dnf install -y httpd`. The database is not a cause: Apache starts before the
database check runs, and the health check does not depend on it.

**Q: The page says `Database: unreachable`.**
A: For up to about a minute after an instance boots this is expected: the page
is served with `unreachable` first and rewritten to `connected` only when the
check succeeds. After that, remember that the line is a snapshot taken at boot.
An instance that booted while the database was unavailable keeps showing
`unreachable` until it is replaced, and an instance that shows `connected` says
nothing about the database now. To investigate, open a Session Manager shell on
the instance and check, in order: that `postgresql18` installed, that the
instance role can read the secret, and that `WebApp-db-sg` still allows 5432
from `WebApp-ec2-sg`. To re-run the check, replace the instance (see the
instance refresh command below).

**Q: SSH to the instances no longer works. How do I get a shell?**
A: Port 22 is not open in this revision. Use Session Manager, which needs the
Session Manager plugin for the AWS CLI:
```bash
aws ssm start-session --target <instance-id> --region us-east-1
```

**Q: All instances appear in only one AZ.**
A: The `cpu-low` CloudWatch alarm may have fired (CPU ~0% under no traffic),
triggering a scale-in that reduced `desired` to 1. Restore with:
```bash
aws autoscaling set-desired-capacity \
  --auto-scaling-group-name WebAppASG \
  --desired-capacity 2 \
  --region us-east-1
```

**Q: How is HTTPS set up, and how do I change the hostname?**
A: HTTPS is part of the stack in this revision; there is nothing to add.
Terraform requests an ACM certificate for `domain_name`, writes the validation
CNAME and the hostname CNAME in Cloudflare, and creates an `HTTPS:443` listener
that uses the certificate. The `HTTP:80` listener answers every request with a
`301` redirect to HTTPS. To serve a different hostname, change `domain_name`
(and `cloudflare_zone_id` if the zone changes) and run `terraform apply`: the
certificate and both DNS records are derived from those two variables.

**Q: `terraform apply` sits on `aws_acm_certificate_validation.web`.**
A: That resource waits until ACM has issued the certificate, and the HTTPS
listener and the Auto Scaling Group wait behind it. ACM issues the certificate
once it can read the validation CNAME. Check that the record exists in the
zone named by `cloudflare_zone_id`, that it is still DNS only as Terraform
writes it, and that `domain_name` belongs to that zone.

**Q: What happens if the database's Availability Zone fails?**
A: The database is a Multi-AZ deployment, so RDS fails over to the standby in
the other Availability Zone automatically. AWS documentation puts a failover at
typically 60 to 120 seconds; it has not been measured here. The endpoint does
not change. The standby cannot be queried, so it adds availability and not read
capacity. The status line on the page does not change during a failover,
because it is written once at boot.

**Q: How do I update the application code?**
A: Update the user data in `main.tf`, then run `terraform apply`. Terraform
creates a new Launch Template version. To replace existing instances, trigger
an instance refresh:
```bash
aws autoscaling start-instance-refresh \
  --auto-scaling-group-name WebAppASG \
  --preferences MinHealthyPercentage=50,InstanceWarmup=120 \
  --region us-east-1
```
Each replacement instance runs the boot-time database check again.

**Q: How do I store Terraform state remotely?**
A: Add a `backend "s3"` block to `main.tf`:
```hcl
terraform {
  backend "s3" {
    bucket         = "your-tfstate-bucket"
    key            = "webApp/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "terraform-state-lock"
    encrypt        = true
  }
}
```

**Q: Why Step Scaling instead of Target Tracking?**
A: Step Scaling gives explicit control over step sizes per alarm, a dead band
between thresholds (preventing oscillation), and separate cooldown periods per
direction. Target Tracking is simpler but doesn't support a dead band or
asymmetric step sizes in one policy definition.

**Q: How do I re-run the architecture audit?**
A: Type `/audit` in Claude Code. The skill inspects all live AWS resources via
the AWS API MCP server and rewrites `Result.md` with current IDs, health
status, and routing details. Until that is done after the next deploy,
`Result.md` records the June 2026 deployment of the previous architecture.
