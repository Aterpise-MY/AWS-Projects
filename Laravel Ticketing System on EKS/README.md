# Laravel Ticketing Platform on Amazon EKS

This project deploys a **customer-support ticketing platform** for Meridian Support Co. onto AWS as a fully reproducible, Infrastructure-as-Code `dev` environment. Terraform provisions a dedicated VPC, an **Amazon EKS** control plane (`1.36`, arm64 / Graviton throughout), a two-tier managed node group, and the stateful backing services — **RDS MySQL**, **ElastiCache Redis**, an **S3** attachments bucket, **ECR** image repositories, and **Secrets Manager** — while a Helm chart runs the Laravel application as four purpose-built workloads: an nginx + PHP-FPM `web` Deployment behind an ALB, a `worker` Deployment draining the Redis queue, a `scheduler` CronJob that fires the 15-minute SLA-escalation sweep, and a `migrate` pre-install hook Job. Pods obtain AWS credentials exclusively through **OIDC / IRSA** (no long-lived keys), read every secret through the **External Secrets Operator**, run non-root on a read-only root filesystem, and scale on three independent signals — CPU (HPA), queue depth (KEDA), and node pressure (Cluster Autoscaler). The whole environment is designed to be destroyed nightly and rebuilt on demand, which is both its cost-control model and its proof that the IaC is real.

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Networking & Routing](#2-networking--routing)
3. [Component Details](#3-component-details)
4. [Directory Structure](#4-directory-structure)
5. [Prerequisites](#5-prerequisites)
6. [Quick Start](#6-quick-start)
7. [Input Variables](#7-input-variables)
8. [Outputs](#8-outputs)
9. [Scaling Behaviour](#9-scaling-behaviour)
10. [Tagging Strategy](#10-tagging-strategy)
11. [Security Considerations](#11-security-considerations)
12. [Cost Estimate](#12-cost-estimate)
13. [Destroying the Stack](#13-destroying-the-stack)
14. [Frequently Asked Questions](#14-frequently-asked-questions)

---

## 1. Architecture Overview

```
                                    ┌──────────────────────────────┐
   Developer ─── git push ─────────▶│  GitHub Actions (OIDC)        │
                                    │  build → push → helm upgrade  │
                                    └───────────────┬──────────────┘
                                                    │ image :<git-sha>
                                                    ▼
   Requester / Agent                         ┌────────────┐
        │                                    │    ECR     │ (immutable app repo
        │ HTTPS                              └─────┬──────┘  + mutable cache repo)
        ▼                                          │ pull
┌───────────┐        ┌──────────────────────────────────────────────────────────┐
│    IGW    │        │                    VPC  10.42.0.0/16                        │
└─────┬─────┘        │                                                            │
      │              │  Public subnets (AZ-a, AZ-b)      Private subnets (AZ-a/b) │
      ▼              │  ┌───────────────┐  ┌─────────┐   ┌───────────────────────┐│
┌───────────┐  ip    │  │      ALB      │  │   NAT   │   │  EKS managed nodes     ││
│    ALB    │───────▶│  │ (internet-    │  │ Gateway │◀──│  system: t4g.small     ││
│ (ingress) │        │  │  facing)      │  │ (AZ-a)  │   │  app:    t4g.medium x2 ││
└───────────┘        │  └───────┬───────┘  └─────────┘   │   (SPOT, arm64)        ││
                     │          │ target-type: ip        │  ┌──────────────────┐  ││
      ┌──────────────┼──────────┘                        │  │ web  worker      │  ││
      │ public API   │                                   │  │ scheduler migrate│  ││
      ▼              │                                   │  └────────┬─────────┘  ││
┌──────────────┐     │                                   └───────────┼───────────┘│
│ EKS Control  │     │      ┌──────────┐  ┌──────────┐  ┌────────────▼──────────┐ │
│ Plane        │◀────┼──────│   RDS    │  │ElastiCache│ │  S3 attachments bucket │ │
│ (API + etcd) │     │      │  MySQL   │  │  Redis   │  │  (via S3 gw endpoint)  │ │
└──────┬───────┘     │      │ Single-AZ│  │ TLS+AUTH │  └───────────────────────┘ │
       │             │      └──────────┘  └──────────┘                            │
       │ api/audit   └────────────────────────────────────────────────────────────┘
       ▼                                        │ Secrets Manager (via ESO/IRSA)
┌──────────────────┐                            │ CloudWatch Logs (Fluent Bit / YACE)
│   CloudWatch      │◀───────────────────────────┘
│ (logs, metrics)   │
└──────────────────┘
```

**Traffic flow:** A requester or agent hits the Laravel UI over HTTPS. The Internet Gateway routes them to an internet-facing **Application Load Balancer** provisioned by the AWS Load Balancer Controller from the chart's `Ingress`; with `target-type: ip` the ALB registers `web` pod IPs directly and forwards requests into the private subnets. The `web` pods serve reads and writes against **RDS MySQL**, cache and sessions in **ElastiCache Redis**, and push notification jobs onto a Redis queue that the `worker` Deployment drains; attachments are streamed to **S3** through the free gateway endpoint. Nodes reach ECR, STS, and CloudWatch Logs through interface VPC endpoints and everything else through the single **NAT Gateway**. Pods authenticate to AWS via **IRSA** and never hold static keys. Control-plane `api`/`audit` logs and container logs land in **CloudWatch**.

---

## 2. Networking & Routing

### VPC

| Attribute | Value |
|---|---|
| CIDR block | `10.42.0.0/16` (65,536 addresses) |
| DNS hostnames | Enabled |
| DNS support | Enabled |
| Availability Zones | `ap-southeast-1a`, `ap-southeast-1b` |
| NAT Gateways | One, shared (in public AZ-a) |
| Flow Logs | Behind `enable_flow_logs` (default `false`) |

### Subnets

| Subnet | Type | CIDR | Purpose | Key Tag |
|---|---|---|---|---|
| Public AZ-a | Public | `10.42.0.0/20` | ALB, NAT Gateway | `kubernetes.io/role/elb = 1` |
| Public AZ-b | Public | `10.42.16.0/20` | ALB | `kubernetes.io/role/elb = 1` |
| Private AZ-a | Private | `10.42.32.0/19` | Nodes, pods, RDS, Redis | `kubernetes.io/role/internal-elb = 1` |
| Private AZ-b | Private | `10.42.64.0/19` | Nodes, pods, RDS, Redis | `kubernetes.io/role/internal-elb = 1` |
| Reserved | — | `10.42.96.0/19`+ | Future third AZ / isolation | — |

> Private subnets are `/19` (8,190 usable each), not `/24`, because the VPC CNI assigns a **real VPC IP per pod** — a busy node can consume dozens of addresses, so the address budget is sized for pod density, not node count. Both tiers also carry `kubernetes.io/cluster/ticketing-dev = shared` so EKS and the load balancer controller can discover them.

### Route Tables

| Route Table | Associated Subnets | Route | Target |
|---|---|---|---|
| Public | Public AZ-a, AZ-b | `0.0.0.0/0` | Internet Gateway (`igw`) |
| Private AZ-a | Private AZ-a | `0.0.0.0/0` | NAT Gateway (`nat`, AZ-a) |
| Private AZ-b | Private AZ-b | `0.0.0.0/0` | NAT Gateway (`nat`, AZ-a) |
| Private (both) | Private AZ-a, AZ-b | `pl-s3` prefix list | S3 Gateway Endpoint |
| Local (implicit) | All | `10.42.0.0/16` | `local` |

### Traffic Flow

```
   User HTTPS                         Node egress (image pulls, AWS APIs)
       │                                        │
       ▼                                        ▼
 ┌───────────┐                        ┌──────────────────────┐
 │    IGW    │                        │   Private Subnet      │
 └─────┬─────┘                        │   EKS worker node     │
       │ internet-facing              └──────┬──────┬─────────┘
       ▼                                     │      │ ecr/sts/logs :443
 ┌───────────┐  target-type: ip              │      ▼
 │    ALB    │──────────▶ web pod IP          │  ┌────────────────────┐
 └───────────┘                                │  │ Interface Endpoints │ (private DNS)
                                              │  └────────────────────┘
                          s3 :443             │
                    ┌────────────────┐        │ 0.0.0.0/0 (everything else)
                    │  S3 Gateway    │◀───────┤
                    │  Endpoint(free)│        ▼
                    └────────────────┘   ┌──────────────┐     ┌───────┐
                                         │ NAT Gateway  │────▶│  IGW  │──▶ Internet
                                         │ (public AZ-a)│     └───────┘
                                         └──────────────┘
```

> A single NAT Gateway in AZ-a serves **both** private route tables. This is a deliberate dev cost trade: if AZ-a fails, egress stops for both AZs. Production would run one NAT per AZ. The free S3 gateway endpoint keeps attachment traffic off NAT entirely.

---

## 3. Component Details

### 3.1 Security Groups

| Security Group | Ingress | Egress | Notes |
|---|---|---|---|
| Interface-endpoint SG | `443` from VPC CIDR (`10.42.0.0/16`) | default | Fronts the ECR/STS/Logs interface endpoints |
| EKS cluster SG | Managed by EKS | Managed | Control-plane ↔ node communication |
| Node SG | From cluster SG + intra-node | All | Output `node_security_group_id`; used as the source for RDS/Redis ingress |
| RDS SG | `3306` from node SG only | — | No CIDR rules; only in-cluster workloads reach MySQL |
| Redis SG | `6379` from node SG only | — | No CIDR rules; TLS + AUTH still required |

> RDS and ElastiCache accept ingress from the **node security group ID**, never a CIDR block. There is no path to the databases except from a pod running on a cluster node.

### 3.2 EKS Cluster (`modules/eks`)

| Attribute | Value |
|---|---|
| Cluster name | `ticketing-dev` |
| Kubernetes version | `1.36` |
| Public endpoint access | Enabled, `public_access_cidrs` default `0.0.0.0/0` (narrow before prod) |
| Control-plane logs | `api`, `audit` only → CloudWatch, 7-day retention (log group created by Terraform) |
| Access management | EKS **access entries** + `AmazonEKSClusterAdminPolicy` for `admin_principal_arns` — no `aws-auth` ConfigMap |
| OIDC provider | `aws_iam_openid_connect_provider` for IRSA |
| Add-ons | `vpc-cni` (`ENABLE_NETWORK_POLICY=true`), `coredns`, `kube-proxy`, `eks-pod-identity-agent`, `aws-ebs-csi-driver` |

### 3.3 Node Groups

| Node group | Instance | Capacity | Size (min/desired/max) | Taint / Label |
|---|---|---|---|---|
| `system` | `t4g.small` | ON_DEMAND | 1 / 1 / 1 | Taint `CriticalAddonsOnly=true:NoSchedule`, label `role=system` |
| `app` | `t4g.medium` | **SPOT** | 2 / 2 / 4 | Label `role=app` |

> The `system` group is a stable on-demand home for cluster-critical add-ons (CoreDNS, controllers) fenced off by the taint. The `app` group runs the application on Spot — dev workloads tolerate interruption, and the four-workload split is designed so a reclaimed node reschedules cleanly. The app ASG carries `k8s.io/cluster-autoscaler/enabled = true` and `k8s.io/cluster-autoscaler/ticketing-dev = owned` for autoscaler discovery. Worker launch templates set **IMDS hop limit = 1** so pods cannot reach node metadata — IRSA is the only credential path. When `node_ami_id` is set (Packer golden AMI) it is used; otherwise the EKS-optimised AL2023 arm64 AMI.

### 3.4 IRSA Roles

| Key | Namespace / ServiceAccount | Permissions |
|---|---|---|
| `alb_controller` | `kube-system` / `aws-load-balancer-controller` | Official ALB controller policy |
| `external_secrets` | `external-secrets` / `external-secrets` **and** `ticketing` / `ticketing-eso` | `secretsmanager:GetSecretValue`,`DescribeSecret` on the four project secrets only |
| `cluster_autoscaler` | `kube-system` / `cluster-autoscaler` | Autoscaling describe + set desired, scoped by ASG tag |
| `app` | `ticketing` / `ticketing` | S3 `Get/Put/Delete/List` + `AbortMultipartUpload` on the attachments bucket only |
| `fluent_bit` | `amazon-cloudwatch` / `fluent-bit` | CloudWatch Logs create / put |
| `cloudwatch_exporter` | `amazon-cloudwatch` / YACE | CloudWatch read (`Resource:*`; read actions do not support resource scoping) |

> IRSA trust policies scope the OIDC `sub` claim to the exact `system:serviceaccount:<ns>:<sa>`. The `app` SA is deliberately **S3-only**; the SecretStore authenticates with a separate `ticketing-eso` SA that carries the read-only `external_secrets` role, so the application identity can never read Secrets Manager.

### 3.5 ECR (`modules/ecr`)

| Attribute | App repo (`ticketing/app`) | Cache repo (`ticketing/app-cache`) |
|---|---|---|
| Tag mutability | `IMMUTABLE` | `MUTABLE` |
| Scan on push | `true` (basic) | `true` |
| Encryption | `AES256` | `AES256` |
| Lifecycle | Expire untagged > 1 day; keep 10 most-recent tagged | Expire untagged > 7 days |

> The cache repo **must** be `MUTABLE`: BuildKit `--cache-to type=registry` overwrites a fixed cache tag every build. An immutable cache repo silently degrades CI (builds still pass but re-import a stale manifest — the symptom is CI times regressing with nothing failing). A repository policy grants pull to the system and app node roles.

### 3.6 RDS MySQL (`modules/database`)

| Attribute | Value |
|---|---|
| Engine / version | MySQL `8.0` |
| Instance class | `db.t4g.micro` (arm64) |
| Storage | 20 GB gp3, `storage_encrypted = true` |
| Availability | Single-AZ |
| Backups | `backup_retention_period = 1`, `skip_final_snapshot = true` |
| Deletion protection | `false` |
| Credentials | `random_password` → `ticketing-dev/database` secret; **password never output** |
| `max_connections` | Engine default ≈ 85 on `db.t4g.micro` (`DBInstanceClassMemory/12582880`) |

> A `db_parameter_group` exposes `max_connections` for override but leaves the engine-default formula in place. Connection budget: 10 FPM children × 2 web pods = 20 of ~85 (~24%); 4 web pods at HPA max = 40 (< 50%).

### 3.7 ElastiCache Redis (`modules/cache`)

| Attribute | Value |
|---|---|
| Engine / version | Redis `7.1` (`aws_elasticache_replication_group`, cluster mode disabled) |
| Node type | `cache.t4g.micro` (arm64), `num_cache_clusters = 1` |
| Encryption | At-rest + in-transit both `true` |
| Auth | `auth_token` from `random_password` → `ticketing-dev/redis-auth` |
| Failover | `automatic_failover_enabled = false`, `snapshot_retention_limit = 0` |

Redis logical DB index assignment:

| Index | Role |
|---|---|
| 0 | Cache (`REDIS_CACHE_DB=0`) |
| 1 | Sessions |
| 2 | Queue (`REDIS_QUEUE_DB=2`) |

> `transit_encryption_enabled = true` means the client **must** speak TLS (chart sets `redis.tls: true`, `client: phpredis`). A plaintext client produces a connection reset that reads like a firewall problem and is not.

### 3.8 S3 Attachments (`modules/storage`)

| Attribute | Value |
|---|---|
| Versioning | Enabled |
| Public access | Fully blocked |
| Encryption | SSE-S3 (`AES256`) |
| Lifecycle | Expire noncurrent versions after 7 days; abort incomplete multipart uploads after 7 days |
| `force_destroy` | `true` (so teardown removes a non-empty bucket) |

### 3.9 Secrets Manager (`modules/secrets` + database/cache modules)

| Secret | Name | Owner module |
|---|---|---|
| App key | `ticketing-dev/app-key` | `secrets` |
| SMTP | `ticketing-dev/smtp` | `secrets` |
| DB credentials | `ticketing-dev/database` | `database` |
| Redis auth | `ticketing-dev/redis-auth` | `cache` |

> Each stateful module owns its own secret so plaintext credentials are never passed between modules as Terraform outputs. The SMTP secret carries `lifecycle { ignore_changes = [secret_string] }` so a real value set out-of-band is not clobbered. `secret_recovery_window_days = 0` lets a torn-down secret name be reused immediately on rebuild.

### 3.10 ALB Ingress (`helm/ticketing/templates/ingress.yaml`)

| Attribute | Value |
|---|---|
| Class | `alb` (AWS Load Balancer Controller) |
| Scheme | `internet-facing` |
| Target type | `ip` (registers pod IPs directly) |
| TLS | ACM cert ARN, `ELBSecurityPolicy-TLS13-1-2-2021-06` |
| Health check | `/up` |
| Deregistration delay | 30s (≥ web `terminationGracePeriodSeconds`) |

> The ALB is created by the controller at runtime, **not** by Terraform, and is therefore not in Terraform state — which is exactly why teardown must uninstall Helm before `terraform destroy` (see §13).

### 3.11 Kubernetes Workloads (`helm/ticketing`)

| Workload | Kind | Role | Scaling |
|---|---|---|---|
| `web` | Deployment | nginx (`:8080`) + PHP-FPM, serves HTTP | HPA 2→4 on 70% CPU |
| `worker` | Deployment | `php artisan queue:work`, drains Redis queue | KEDA 1→10 on queue depth |
| `scheduler` | CronJob (`* * * * *`) | `php artisan schedule:run`, fires SLA sweep | `concurrencyPolicy: Forbid` |
| `migrate` | Hook Job (pre-install/pre-upgrade, weight `0`) | `php artisan migrate --force` | one-shot |

> Ordering hooks: `SecretStore` (weight `-20`) → `ExternalSecret` (weight `-10`) → `migrate` (weight `0`), so credentials exist before migrations run. Every container is non-root with a read-only root filesystem, which requires `emptyDir` mounts at `/var/www/storage/framework/{cache,sessions,views}`, `/var/www/storage/logs`, `/var/www/bootstrap/cache`, `/tmp`, `/var/run`, and `/var/lib/nginx` — omit one and the pod crash-loops. Probes: liveness `/up`, readiness `/health/ready` (checks DB + Redis), startup `/up` with a generous `failureThreshold` for cold-Spot warm-up.

### 3.12 Autoscalers

| Autoscaler | Signal | Range | Notes |
|---|---|---|---|
| HPA (`web`) | CPU utilisation 70% | 2 → 4 pods | Scale up 30s window, down 300s |
| KEDA (`worker`) | Redis list length `laravel_database_queues:default` | 1 → 10 pods | `listLength: 20` backlog per replica, `pollingInterval: 15s` |
| Cluster Autoscaler | Unschedulable pods | app ASG 2 → 4 nodes | Discovers ASG via `k8s.io/cluster-autoscaler` tags |

> The KEDA `listName` is templated from `redis.prefix` + `queues:` + `redis.queue` (`laravel_database_queues:default`), never hardcoded — a wrong prefix means KEDA polls a key that is always empty and the worker never scales.

---

## 4. Directory Structure

```
Laravel Ticketing System on EKS/
├── README.md                        # This document
├── app/                             # Laravel application source
│   ├── app/                         # Controllers, Models, Jobs, Enums, SLA policy, console commands
│   ├── config/                      # Framework config (cache, queue, session, filesystems, ticketing)
│   ├── database/                    # Migrations, factories, seeders
│   ├── resources/                   # Blade views, CSS, JS
│   ├── routes/                      # web.php, api.php, health.php, console.php
│   ├── tests/                       # Pest feature tests (tickets, attachments, SLA, health)
│   ├── composer.json                # PHP deps (composer.lock generated pre-build — see FAQ)
│   └── package.json                 # Front-end deps (package-lock.json generated pre-build)
├── docker/                          # Container build context
│   ├── Dockerfile                   # Multi-stage arm64 image (composer --no-dev, npm build)
│   ├── entrypoint.sh                # Container entrypoint
│   ├── nginx/default.conf           # nginx site (listens :8080, non-root)
│   ├── php/                         # php.ini, opcache.ini, fpm-pool.conf
│   └── supervisor/supervisord.conf  # Process supervision
├── packer/                          # Golden AMI pipeline
│   ├── eks-node.pkr.hcl             # AL2023 arm64 EKS-node image (hardened)
│   └── cleanup-old-amis.py          # Prunes superseded AMIs
├── ansible/                         # Node / bastion configuration management
│   ├── playbooks/                   # node-hardening, bastion, db-maintenance
│   ├── roles/                       # base-packages, cis-hardening, containerd-tuning, monitoring-agents
│   └── inventory/aws_ec2.yml        # Dynamic EC2 inventory
├── terraform/
│   ├── bootstrap/                   # Remote-state backend (KMS, S3, DynamoDB lock) — run once
│   ├── dev/                         # Root environment composition (network→eks→{ecr,db,cache,storage,secrets})
│   │   ├── versions.tf backend.tf providers.tf variables.tf main.tf outputs.tf
│   │   └── terraform.tfvars.example # Sample vars — NO secrets
│   └── modules/
│       ├── network/                 # VPC, subnets, single NAT, VPC endpoints, flow logs
│       ├── eks/                     # Cluster, node groups, IRSA, add-ons, access entries
│       ├── ecr/                     # App (immutable) + cache (mutable) repositories
│       ├── database/                # RDS MySQL Single-AZ + credentials secret
│       ├── cache/                   # ElastiCache Redis (TLS + AUTH) + auth secret
│       ├── storage/                 # S3 attachments bucket
│       └── secrets/                 # APP_KEY + SMTP placeholder secrets
├── helm/
│   ├── ticketing/                   # Application chart (web/worker/scheduler/migrate, ESO, KEDA, ingress, netpol)
│   └── platform/                    # Cluster add-on values (ALB controller, ESO, KEDA, metrics-server,
│                                    #   cluster-autoscaler, kube-prometheus-stack, fluent-bit, YACE) + dashboards
├── scripts/
│   ├── bootstrap.sh                 # Verify tooling, confirm identity, terraform init, kubeconfig
│   ├── rebuild.sh                   # apply → kubeconfig → add-ons → helm → verify (prints elapsed)
│   ├── teardown.sh                  # workloads → helm uninstall → wait for ALB → terraform destroy
│   ├── verify-deployment.sh         # 5-check post-deploy smoke test
│   ├── cost-report.py               # Price List API cost estimate
│   └── lib.sh                       # Shared shell helpers
├── .github/workflows/               # ci.yml, terraform-plan.yml, build-deploy.yml
└── docs/                            # Runbooks / supporting docs
```

---

## 5. Prerequisites

| Tool | Minimum Version | Install Link |
|---|---|---|
| Terraform | 1.15.0 | https://developer.hashicorp.com/terraform/install |
| AWS CLI | 2.30 | https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html |
| kubectl | 1.33 | https://kubernetes.io/docs/tasks/tools/ |
| Helm | 3.14 | https://helm.sh/docs/intro/install/ |
| Packer | 1.11 | https://developer.hashicorp.com/packer/install |
| Ansible | 2.16 | https://docs.ansible.com/ansible/latest/installation_guide/index.html |
| Docker (with Buildx) | 24.0 | https://docs.docker.com/get-docker/ |
| Infracost | 0.10 | https://www.infracost.io/docs/ |
| jq | 1.7 | https://jqlang.github.io/jq/download/ |

Account-level requirements:

- AWS credentials for account `022499047467`, region `ap-southeast-1`, with permission to create VPC, EKS, IAM, RDS, ElastiCache, ECR, S3, and Secrets Manager resources.
- The remote-state backend must exist first — run `terraform/bootstrap/` once before `terraform/dev/`.
- An EKS service-linked role (created automatically on first EKS use) and sufficient Graviton (`t4g`) vCPU quota in `ap-southeast-1`.
- `composer.lock` / `package-lock.json` generated once with network access before the first image build (see FAQ).

---

## 6. Quick Start

```bash
# 0. Prepare workstation: verify tooling, confirm AWS identity, terraform init
cd "Laravel Ticketing System on EKS"
./scripts/bootstrap.sh                     # asserts account 022499047467, region ap-southeast-1

# 1. (First time only) create the remote-state backend
terraform -chdir=terraform/bootstrap init
terraform -chdir=terraform/bootstrap apply # KMS key, S3 state bucket, DynamoDB lock table

# 2. Configure the dev environment variables (no secrets go in the example file)
cp terraform/dev/terraform.tfvars.example terraform/dev/terraform.tfvars
#    set owner_email and admin_principal_arns

# 3. Provision the infrastructure (network → eks → ecr/db/cache/storage/secrets)
terraform -chdir=terraform/dev init
terraform -chdir=terraform/dev plan
terraform -chdir=terraform/dev apply       # type "yes" to confirm

# 4. Point kubectl at the new cluster
aws eks update-kubeconfig --region ap-southeast-1 --name ticketing-dev

# 5. Install the cluster add-ons (ALB controller, External Secrets, KEDA,
#    metrics-server, cluster-autoscaler, Fluent Bit) using helm/platform values
#    — or let scripts/rebuild.sh do steps 3–7 in one pass.

# 6. Build and push the image, then install the application chart
IMAGE_TAG="$(git rev-parse HEAD)"          # full 40-char SHA — never "latest"
ECR_URL="$(terraform -chdir=terraform/dev output -raw ecr_repository_url)"
helm upgrade --install ticketing helm/ticketing -n ticketing --create-namespace \
  --set image.repository="${ECR_URL}" \
  --set image.tag="${IMAGE_TAG}" \
  --set storage.attachmentsBucket="$(terraform -chdir=terraform/dev output -raw attachments_bucket)" \
  --set redis.host="$(terraform -chdir=terraform/dev output -raw redis_address)"

# 7. Verify the deployment end-to-end (pods, migrate hook, /up, DB write, queue)
./scripts/verify-deployment.sh
```

Allow 15–20 minutes for the EKS control plane, node groups, RDS, and ElastiCache to become healthy and for the first sync of pods and the ALB to complete.

---

## 7. Input Variables

`terraform/dev` variables:

| Variable | Type | Default | Description |
|---|---|---|---|
| `region` | string | `ap-southeast-1` | AWS region for every resource |
| `owner_email` | string | *(required)* | Written to the `Owner` default tag; set in `terraform.tfvars`, never committed |
| `name_prefix` | string | `ticketing-dev` | Prefix on every resource name |
| `cluster_name` | string | `ticketing-dev` | EKS cluster name; also drives `kubernetes.io/cluster/<name>` subnet tags (network and eks must agree) |
| `kubernetes_version` | string | `1.36` | Control-plane Kubernetes version (verified current default for the region) |
| `vpc_cidr` | string | `10.42.0.0/16` | VPC CIDR; must be a `/16` so the `/19` pod subnets fit |
| `azs` | list(string) | `["ap-southeast-1a","ap-southeast-1b"]` | Exactly two AZs for public/private subnets |
| `enable_flow_logs` | bool | `false` | Enable VPC Flow Logs to CloudWatch (charged per GB) |
| `enable_interface_endpoints` | bool | `true` | Create the four interface VPC endpoints (ECR API/DKR, STS, Logs). `false` saves ~$76/mo and routes that egress via NAT; the free S3 gateway endpoint is always created |
| `public_access_cidrs` | list(string) | `["0.0.0.0/0"]` | CIDRs allowed to reach the public Kubernetes API — narrow before promoting past dev |
| `admin_principal_arns` | list(string) | `[]` | IAM principals granted `AmazonEKSClusterAdminPolicy` via EKS access entries |
| `node_ami_id` | string | `null` | Optional Packer golden AMI ID; when `null`, the EKS-optimised AL2023 arm64 AMI is used |

> **Cross-variable notes:** `cluster_name` is consumed by both the `network` and `eks` modules and must be identical in each — it is the discovery tag the load balancer controller and EKS read. `vpc_cidr` must remain a `/16` or the `/19` pod subnets and reserved space no longer fit. Setting `node_ami_id` switches node groups from the AWS-managed AMI to the Ansible-hardened Packer image without any other change.

---

## 8. Outputs

| Output | Description |
|---|---|
| `cluster_name` | EKS cluster name (used to build a kubeconfig) |
| `cluster_endpoint` | HTTPS endpoint of the Kubernetes API server |
| `region` | AWS region the environment is deployed in |
| `ecr_repository_url` | App image repository URL (`<url>:<40-char git SHA>`) |
| `ecr_cache_repository_url` | BuildKit cache repository URL (`--cache-to`/`--cache-from`) |
| `attachments_bucket` | S3 attachments bucket name (app `AWS_BUCKET`) |
| `rds_address` | RDS MySQL DNS hostname (no port; password only in Secrets Manager) |
| `redis_address` | Redis primary node hostname (TLS + AUTH required) |
| `irsa_role_arns` | Map of IRSA role ARNs by workload (`alb_controller`, `external_secrets`, `cluster_autoscaler`, `app`, `fluent_bit`, `cloudwatch_exporter`) |
| `secret_names` | Map of logical key → Secrets Manager secret name (`app_key`, `smtp`, `database`, `redis`) |
| `vpc_id` | Dev VPC ID |
| `private_subnet_ids` | Private subnet IDs (nodes, pods, RDS, Redis) |
| `node_security_group_id` | Worker node security group ID |

```bash
# Example: fetch the ECR URL and the External Secrets IRSA role ARN
terraform -chdir=terraform/dev output -raw ecr_repository_url
terraform -chdir=terraform/dev output -json irsa_role_arns | jq -r '.external_secrets'
```

---

## 9. Scaling Behaviour

Three independent autoscalers act on three signals. They are layered: the HPA and KEDA change *pod* counts, and the Cluster Autoscaler adds *nodes* only when those extra pods cannot be scheduled.

### HPA — `web` on CPU

```
 CPU %
 100 ┤
     │                     ╭──── scale-up (window 30s): 70% breached → +pods fast
  70 ┤━━━━━━━━━━━━━━━━━━━━━╋━━━━━━━━━━━━━━━━━━━━━━━━━━━  target 70%
     │        dead-band    │        ╲
  50 ┤   (no action)       │         ╲──── scale-down (window 300s): slow, no flapping
     │                     │
   0 ┼────┬────┬────┬────┬─┴──┬────┬────┬────┬────▶ time
        2 pods (min)      burst      back toward 2 pods
```

- **Dead-band:** the HPA only acts when measured CPU crosses the 70% target with enough margin; small oscillations around it produce no change.
- **Evaluation periods:** scale-**up** uses a 30s stabilization window (PHP-FPM warm-up is cheap, so react quickly); scale-**down** uses 300s so a brief lull does not tear down capacity that is about to be needed again.
- **Step / bounds:** `minReplicas: 2` is the floor (survives one pod loss with the PDB `minAvailable: 1`); `maxReplicas: 4` bounds cost and keeps the RDS connection budget under 50% (4 × 10 FPM = 40 of ~85).

### KEDA — `worker` on queue depth

KEDA polls the Redis list `laravel_database_queues:default` every 15s. Below `activationListLength: 0` the scaler is inactive and the worker sits at `minReplicaCount: 1`; above it, KEDA scales toward `maxReplicaCount: 10` targeting `listLength: 20` backlog per replica (a 200-job backlog drives all 10 replicas). This is why a notification storm drains fast without the `web` tier ever noticing.

### Cluster Autoscaler — nodes on pod pressure

```
 nodes
   4 ┤                                 ┌──────────────  app max (4)
     │                                 │  CA adds a node when a web/worker
   3 ┤                        ┌────────┘  pod is Pending for lack of capacity
     │                        │
   2 ┤━━━━━━━━━━━━━━━━━━━━━━━━┛━━━━━━━━━━━━━━━━━━━━━━━━  app min/desired (2)
     │   steady state          HPA/KEDA created more pods than fit
   0 ┼────┬────┬────┬────┬────┬────┬────┬────┬────▶ time
```

The Cluster Autoscaler watches for `Pending` pods (~every 10s) and raises the app ASG desired count within `2 → 4`, scaling back down after the pods drain. Spot reclamation is handled the same way — a lost node's pods go `Pending` and the autoscaler replaces capacity.

---

## 10. Tagging Strategy

Applied globally via the `terraform/dev/providers.tf` `default_tags` block:

| Tag Key | Value |
|---|---|
| `Project` | `ticketing` |
| `Environment` | `dev` |
| `ManagedBy` | `terraform` |
| `Owner` | `var.owner_email` |
| `Repository` | `github.com/brendonang/ticketing-platform` |
| `AutoDelete` | `true` |

Per-module `Component` tag (not in `default_tags` because it varies):

| Module | `Component` |
|---|---|
| network | `network` |
| eks | `compute` |
| ecr | `registry` |
| database / cache / storage / secrets | `data` |

> **Per-module quirk:** each module takes a `tags` input and merges its own `Component` value, so `Component` is set once per module rather than globally. **Bootstrap exception:** `terraform/bootstrap/` deliberately omits `AutoDelete = true` and uses `Component = bootstrap` — it holds the Terraform state for everything else, and a sweeper keyed on `AutoDelete` would otherwise delete the state bucket first and orphan the whole environment. Functional tags (`kubernetes.io/role/*`, `kubernetes.io/cluster/*`, `k8s.io/cluster-autoscaler/*`) are read by AWS controllers — do not remove them.

---

## 11. Security Considerations

| Topic | Current posture | Recommended hardening |
|---|---|---|
| Pod → AWS credentials | OIDC / IRSA per workload; no static keys anywhere | Keep; add `aws:SourceVpc`/`aws:SourceVpce` conditions on IRSA policies |
| Node metadata | IMDS **hop limit = 1** — pods cannot reach the node role | Keep; audit for any DaemonSet legitimately needing IMDS |
| Container runtime | Non-root (`runAsUser: 1000`), `readOnlyRootFilesystem: true`, all capabilities dropped, `seccompProfile: RuntimeDefault` | Add Pod Security Admission `restricted` enforcement at the namespace |
| Network segmentation | `NetworkPolicy` per workload; `vpc-cni` `ENABLE_NETWORK_POLICY=true` enforces it | Tighten egress `0.0.0.0/0:443` to specific endpoint/prefix-list CIDRs |
| Secrets | External Secrets Operator syncs from Secrets Manager; none in Git | Rotate DB/Redis credentials on a schedule; add CMK + rotation Lambda |
| Database exposure | RDS/Redis ingress from node SG only, no CIDR rules; both encrypted | Multi-AZ + IAM DB auth in prod |
| API server | Public endpoint, `public_access_cidrs = 0.0.0.0/0` | Narrow to office/CI CIDRs or make the endpoint private-only |
| Cluster access | EKS access entries, no `aws-auth` ConfigMap | Scope `admin_principal_arns` per team; avoid shared admin |
| Image supply chain | Immutable tags (git SHA), ECR basic scan on push | Cosign signing + SBOM; fail the build on CRITICAL/HIGH |
| Control-plane logging | `api` + `audit` to CloudWatch, 7-day retention | Enable all five log types; longer retention; VPC Flow Logs on |

> The `NetworkPolicy` for `web` ingress allows the **ALB public-subnet CIDRs** (`10.42.0.0/20`, `10.42.16.0/20`), not just the controller namespace — with `target-type: ip` the packet source is the ALB ENI, and a namespace-only rule black-holes all user traffic. The Ansible CIS hardening role is **scoped, not blanket**: it documents the controls it skips (IP-forward disable, `overlay`/`br_netfilter`/`nf_conntrack` blacklist, host default-deny) because each one breaks the CNI, containerd, or kube-proxy.

---

## 12. Cost Estimate

Region `ap-southeast-1`, on-demand list rates pulled live from the AWS Price List API. A month is billed as 730 hours. ALB, EBS root volumes, and app log volume appear once workloads run.

### Scenario A — running 24/7 (default, endpoints ON)

| Resource | Quantity | Monthly (USD) |
|---|---|---|
| EKS control plane | 1 cluster | 73.00 |
| NAT Gateway (hourly + ~20 GB data) | 1 | 44.25 |
| Interface VPC endpoints | 4 × 2 AZ + data | 76.12 |
| System node `t4g.small` on-demand | 1 | 15.48 |
| App nodes `t4g.medium` Spot (est.) | 2 | 21.90 |
| EBS gp3 root volumes | 3 × 20 GB | 5.76 |
| RDS `db.t4g.micro` Single-AZ | 1 | 18.25 |
| RDS gp3 storage | 20 GB | 2.76 |
| ElastiCache `cache.t4g.micro` | 1 | 17.52 |
| ALB (base + ~1 LCU est.) | 1 | 23.40 |
| Secrets Manager | 4 secrets | 1.65 |
| CloudWatch Logs (api/audit + Fluent Bit, ~4 GB) | ~4 GB | 3.00 |
| S3 attachments + ECR image storage | ~10 GB | 1.00 |
| **Total (24/7, endpoints ON)** | | **≈ 304.09** |

| Variant | Monthly (USD) |
|---|---|
| 24/7, `enable_interface_endpoints = false` | ≈ 228 |
| **Realistic dev** (torn down nights/weekends, ~176 hr/mo) | **≈ 74** |
| Light use (spin-up-to-test, ~60 hr/mo) | ≈ 30 |

> **Structural floor:** EKS control plane ($73) + four interface endpoints ($76) + NAT Gateway ($43) = **$192 before a single node or database runs** — so a 24/7 stack cannot fit a $200 budget while EKS + NAT + RDS + Redis + ALB are all up. The teardown/rebuild model (§13) is the real cost control and lands the environment at ~$74/month. The `enable_interface_endpoints` toggle is the one-line −$76 lever: at dev traffic the interface endpoints cost ~$76/mo in fixed hourly charges while the NAT data they offload is ~$1/mo, so they are a production-shaped pattern kept ON by default but cheaply disabled. Spot, LCU, NAT/endpoint data, and log volume are usage-driven estimates. Model your own numbers with the [AWS Pricing Calculator](https://calculator.aws/).

---

## 13. Destroying the Stack

```bash
cd "Laravel Ticketing System on EKS"

# Ordered, safe teardown: workloads → helm uninstall → wait for ALB + SGs → destroy
./scripts/teardown.sh            # type DESTROY to confirm (or --yes for automation)

# Leave the infrastructure up but remove the app + ALB:
./scripts/teardown.sh --keep-infra
```

`teardown.sh` runs the only correct order and exists because doing it any other way orphans resources:

1. **Scale workloads to zero** — stops the app writing to RDS/Redis/S3 and stops the scheduler spawning pods mid-teardown.
2. **`helm uninstall`** — deletes the `Ingress`, which is the *only* signal that tells the AWS Load Balancer Controller to delete the ALB it created.
3. **Wait for the ALB and its controller-managed security groups to actually disappear** (polls `elbv2 describe-load-balancers` and SGs tagged `elbv2.k8s.aws/cluster`) — the AWS-side deletion is asynchronous and ENI detachment lags.
4. **`terraform destroy`** — only now is the VPC free of foreign dependencies.

> **The orphaned-ALB trap:** the ALB and its security groups are created by a controller inside the cluster and are **not in Terraform state**. Skip the uninstall-and-wait and go straight to `terraform destroy` and it hangs ~20 minutes, then fails with `DependencyViolation` on the subnets, security groups, and VPC — leaving you to hand-delete the load balancer, wait for ENIs to detach, and re-run. The script's wait gates prevent exactly this.

**What survives / what is gone:**

- **Gone permanently:** RDS has `skip_final_snapshot = true` and Redis `snapshot_retention_limit = 0`, so there is **no final backup** — data is unrecoverable. `force_destroy = true` lets the non-empty S3 bucket be deleted. `secret_recovery_window_days = 0` deletes secrets immediately (no 7-day recovery window), so their names can be reused on rebuild.
- **Not managed by `terraform/dev` (survives a dev destroy):** the `terraform/bootstrap/` state backend — the KMS key, S3 state bucket, and DynamoDB lock table — is intentionally left standing so the environment can be rebuilt. Any Packer AMIs and their EBS snapshots also survive; prune them with `packer/cleanup-old-amis.py`.

Rebuild the whole environment with `./scripts/rebuild.sh`, which runs apply → kubeconfig → add-ons → Helm → verify and prints total wall time (target < 30 minutes).

---

## 14. Frequently Asked Questions

**Q1. The app returns `502`/`504` through the ALB — what's wrong?**
A `502`/`504` from the ALB means the target group has no healthy backend. Check `kubectl get pods -n ticketing`: if `web` pods are `Pending`, the app node group may be full (the Cluster Autoscaler needs headroom up to 4 nodes) or Spot capacity is unavailable; if `CrashLoopBackOff`, the usual cause is a missing `emptyDir` mount breaking the read-only root filesystem, or the readiness probe `/health/ready` failing because DB/Redis credentials never synced (check the `ExternalSecret` and the `ticketing-app` Kubernetes Secret). Also confirm the ALB health check path `/up` is returning `200` and that `deregistrationDelaySeconds` (30) is not shorter than a rollout's grace period.

**Q2. Everything runs behind a single NAT Gateway in one AZ — isn't that a single point of failure?**
Yes, and it is deliberate for dev. Both private route tables egress through one NAT in AZ-a, so if AZ-a fails, image pulls and outbound AWS calls from AZ-b stop too. RDS is Single-AZ and Redis is single-node for the same cost reason. The nodes and pods still spread across both AZs, so in-cluster traffic survives, but this topology is a dev cost trade, not an HA design. Production sets one NAT per AZ, Multi-AZ RDS with a read replica, and an ElastiCache replica with automatic failover — each is a one-knob change from what is authored here.

**Q3. How do I stand up a second environment (e.g. `staging` or `prod`)?**
Add a sibling root directory beside `terraform/dev` (e.g. `terraform/prod`) that composes the same `modules/*` with a different `name_prefix`, `cluster_name`, `vpc_cidr`, and a distinct backend state key, then flip the production-delta knobs (Multi-AZ RDS, NAT per AZ, non-Spot web nodes, all five control-plane log types, CMK, Inspector scanning). The Helm chart needs **no** per-environment values file by design — the only things that differ between environments are infrastructure endpoints, and those are supplied from `terraform output` at install time via `--set`. Duplicating the 300-line `values.yaml` per environment is how the two copies drift and how a prod install silently keeps a stale dev Redis endpoint.

**Q4. How do I update the application code?**
Build a new image tagged with the **full 40-character git SHA** (never `latest`), push it to the ECR app repo, and `helm upgrade` with `--set image.tag=<sha>`. Because the app repo is `IMMUTABLE`, a tag can never be overwritten — the tag is a content address, which is exactly why `pullPolicy: IfNotPresent` is safe and why a rollback is just re-deploying an older SHA. The `migrate` pre-upgrade hook Job runs `php artisan migrate --force` before the new pods roll, so schema changes ship atomically with the code. CI (`.github/workflows/build-deploy.yml`) does this on merge.

**Q5. Should I use remote state, and where is it?**
Yes — remote state is mandatory here, not optional. `terraform/bootstrap/` creates the S3 state bucket (versioned, SSE-KMS, public access blocked) and a DynamoDB lock table before anything else, and `terraform/dev/backend.tf` points at them. Run bootstrap once per account; it is deliberately excluded from the `AutoDelete` sweep so a teardown of the dev environment never destroys the state that makes rebuilds possible.

**Q6. Why is the app node group all Spot?**
Because this is dev and the workloads are interruption-tolerant. The four-workload split is built for it: `web` sits behind a PDB (`minAvailable: 1`) and an HPA, `worker` jobs are retried (`tries: 3`) and idempotent, the `scheduler` CronJob uses `concurrencyPolicy: Forbid` with a `startingDeadlineSeconds` so a missed run is skipped rather than stacked, and `migrate` is a one-shot hook. A reclaimed Spot node's pods go `Pending` and the Cluster Autoscaler replaces the capacity. Spot saves roughly 65% versus on-demand (~$22/mo vs ~$62/mo for two `t4g.medium`). The `system` node group is on-demand precisely so cluster-critical add-ons never ride Spot. Production would move the web tier to on-demand or a mixed-instances policy — again, a one-line capacity-type change.

**Q7. `composer install` / `npm ci` fails in the image build — why?**
`composer.lock` and `package-lock.json` are intentionally **not committed**, and `npm ci` hard-fails without a lock file. Generate them once with network access (`composer install` and `npm install` in `app/`) and commit them before the first image build or CI run. They were not hand-fabricated because a wrong lock file is worse than none — it pins the wrong dependency tree and passes CI while shipping something you never tested.
