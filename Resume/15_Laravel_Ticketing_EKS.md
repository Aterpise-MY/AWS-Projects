# Laravel Ticketing Platform on Amazon EKS — Resume Summary

> Status: authored and verified to the ceiling of static validation (`terraform validate` + `terraform fmt`, `helm lint` + `helm template`, `shellcheck`, `php -l`, YAML/JSON parse, and a live read-only AMI lookup); **not yet applied**. No `terraform apply`, `helm install`, `packer build`, or other AWS mutation has been run, so figures below describe the authored footprint, not live resource IDs.

## Project Overview

A self-hostable customer-support ticketing platform for Meridian Support Co. — a mid-market B2B SaaS vendor whose ~400 business customers carry contractual SLAs and whose ticket attachments must stay in their own AWS account in Singapore (`ap-southeast-1`) for data residency. A Laravel 11 application is decomposed by runtime behaviour into four Kubernetes workloads on **Amazon EKS `1.36`** (arm64 / Graviton throughout): an nginx + PHP-FPM `web` Deployment behind an ALB, a `worker` Deployment that KEDA scales on Redis queue depth, a `scheduler` CronJob that fires the 15-minute SLA-escalation sweep, and a `migrate` Helm pre-install/pre-upgrade hook Job. Terraform provisions the VPC, EKS control plane and a two-tier managed node group, **RDS MySQL 8.0**, **ElastiCache Redis 7.1** (TLS + AUTH), an **S3** attachments bucket, two **ECR** repositories, and four **Secrets Manager** secrets synced into the cluster by the **External Secrets Operator**. Every pod-to-AWS call uses **IRSA over OIDC** (IMDS hop limit `1` forces it), containers run non-root on a read-only root filesystem, and nodes can boot from a **Packer** golden AMI hardened by a scoped **Ansible** CIS role. This is the `dev` environment for a small team with no dedicated ops, so the whole design optimises for cheap, reproducible, and destroyable: it is meant to be torn down nightly and rebuilt on demand, which is both the cost-control model and the proof that the IaC is real. Targets account `022499047467` under the prefix `ticketing-dev`.

## Architecture

```
   Developer ── git push ──►┌───────────────────────────────────────┐
                            │ GitHub Actions (OIDC only, no keys)     │
                            │ build arm64 → push ECR → helm upgrade   │
                            │ --set image.tag=<40-char git SHA>       │
                            └───────────────────┬───────────────────┘
                                                ▼
                            ┌───────────────────────────────────────┐
                            │ ECR  ticketing/app (IMMUTABLE)          │
                            │      ticketing/app-cache (MUTABLE)      │
                            └───────────────────┬───────────────────┘
  Requester / Agent                             │ pull
        │ HTTPS                                 │
        ▼                                       │
 ┌──────────────────────────────────────────────┼──────────────────────┐
 │ VPC 10.42.0.0/16   ap-southeast-1a / 1b       │                      │
 │ ┌── Public 10.42.0.0/20 · 10.42.16.0/20 ─────┼───────────────────┐  │
 │ │  IGW    ALB (internet-facing, target-type: ip)   NAT GW (AZ-a) │  │
 │ └──────────────┬──────────────────────────────────────▲─────────┘  │
 │                │ web pod IPs                           │ egress      │
 │ ┌── Private 10.42.32.0/19 · 10.42.64.0/19 ─────────────┴─────────┐  │
 │ │  EKS 1.36 managed nodes                                         │  │
 │ │   system: 1 × t4g.small ON_DEMAND (tainted CriticalAddonsOnly)  │  │
 │ │   app:    2-4 × t4g.medium SPOT                                 │  │
 │ │  ┌──────────┐ ┌──────────┐ ┌─────────────┐ ┌──────────────┐    │  │
 │ │  │ web      │ │ worker   │ │ scheduler   │ │ migrate      │    │  │
 │ │  │ HPA 2-4  │ │ KEDA 1-10│ │ CronJob     │ │ pre-install  │    │  │
 │ │  └────┬─────┘ └────┬─────┘ └──────┬──────┘ └──────┬───────┘    │  │
 │ └───────┼────────────┼──────────────┼───────────────┼────────────┘  │
 │         ▼            ▼              ▼               ▼               │
 │  ┌─────────────┐ ┌──────────────────┐ ┌───────────────────────────┐ │
 │  │ RDS MySQL   │ │ ElastiCache Redis│ │ S3 attachments            │ │
 │  │ 8.0 1-AZ    │ │ 7.1  TLS + AUTH  │ │ (via free S3 gw endpoint) │ │
 │  │ 3306←nodeSG │ │ 6379←nodeSG      │ └───────────────────────────┘ │
 │  └─────────────┘ └──────────────────┘                               │
 │  Interface endpoints (ECR API/DKR, STS, Logs) — enable_interface_   │
 │  endpoints, default ON                                              │
 └─────────────────────────────────────────────────────────────────────┘
        │ IRSA / OIDC                           │ api + audit logs
        ▼                                       ▼
 ┌──────────────────────────────┐    ┌───────────────────────────────┐
 │ Secrets Manager (4 secrets)   │    │ CloudWatch (control plane,    │
 │ → External Secrets Operator   │    │ Fluent Bit, YACE exporter)    │
 └──────────────────────────────┘    └───────────────────────────────┘
```

## Technology Stack

| Layer | Technology | Purpose |
|---|---|---|
| **Kubernetes** | Amazon EKS `1.36`, managed node groups (arm64 / Graviton) | `system` on-demand group for add-ons; `app` Spot group for workloads; EKS access entries instead of `aws-auth` |
| **Networking** | VPC `10.42.0.0/16`, 2 AZ, single NAT, S3 gateway + 4 interface endpoints | `/19` private subnets sized for VPC CNI pod density; endpoints gated by `enable_interface_endpoints` |
| **Application** | Laravel 11 (PHP `^8.3`), nginx + PHP-FPM, Pest tests | Tickets, comments, attachments, queued notifications, SLA escalation command |
| **Container build** | Multi-stage arm64 Dockerfile (`composer:2.8`, `node:20-alpine`, `php:8.3-fpm-alpine3.20`) | Non-root runtime image; BuildKit registry cache |
| **Packaging** | Helm (`helm/ticketing` app chart, `helm/platform` add-on values) | Four workloads, ESO hooks, ingress, HPA, KEDA `ScaledObject`, NetworkPolicy, PDB |
| **Database** | Amazon RDS MySQL 8.0 (`db.t4g.micro`, Single-AZ, 20 GB gp3) | Primary ticket store; credentials only in Secrets Manager |
| **Cache / queue** | Amazon ElastiCache Redis 7.1 (`cache.t4g.micro`, TLS + AUTH) | DB 0 cache, DB 1 sessions, DB 2 queue |
| **Storage** | Amazon S3 (versioned, SSE-S3, public access blocked) | Ticket attachments via the app's S3-only IRSA role |
| **Registry** | Amazon ECR (`ticketing/app` IMMUTABLE, `ticketing/app-cache` MUTABLE) | SHA-addressed images + BuildKit layer cache; scan-on-push |
| **Secrets** | AWS Secrets Manager + External Secrets Operator | 4 secrets materialised as the `ticketing-app` Kubernetes Secret |
| **Autoscaling** | HPA (CPU), KEDA (Redis list length), Cluster Autoscaler | Three independent signals for pods and nodes |
| **Identity** | IAM OIDC provider + 6 IRSA roles; GitHub Actions OIDC | Zero long-lived credentials for pods or CI |
| **Observability** | kube-prometheus-stack, Alertmanager, Fluent Bit, YACE, redis-exporter, CloudWatch | 4 PrometheusRule alerts, 3 Grafana dashboards-as-code, control-plane `api`/`audit` logs |
| **Golden image / config** | Packer (`eks-node.pkr.hcl`, AL2023 arm64), Ansible (4 roles, 3 playbooks) | Scoped CIS hardening, containerd tuning, monitoring agents |
| **CI/CD** | GitHub Actions (`ci.yml`, `terraform-plan.yml`, `build-deploy.yml`) | Lint + static analysis (PHPStan, hadolint, tflint, checkov, ansible-lint, kubeconform), plan + cost delta on PRs, build-and-deploy by SHA |
| **IaC** | Terraform `>= 1.9.0` (aws `>= 5.90, < 7.0`; live-checked `v6.56.0`), random, tls | 7 modules + `bootstrap` (KMS, S3 state, DynamoDB lock) + `dev` root |

## Key Achievements

- **Four-workload decomposition driven by runtime behaviour** — `web` (HPA 2→4 on 70% CPU, PDB `minAvailable: 1`), `worker` (KEDA 1→10 on `laravel_database_queues:default`, `listLength: 20`), `scheduler` (CronJob, `concurrencyPolicy: Forbid`), and `migrate` (`php artisan migrate --force` as a pre-install/pre-upgrade hook), each mapped to a real persona.
- **Zero long-lived credentials** — six IRSA roles scoped to exact `system:serviceaccount:<ns>:<sa>` subjects; launch templates set IMDS hop limit `1` so pods cannot reach the node role; CI authenticates via GitHub OIDC only.
- **Secrets never in Git or Terraform outputs** — each stateful module owns its own secret, the DB password is never an output (verified by `grep`), and ESO syncs four secrets through a dedicated `ticketing-eso` identity so the S3-only app identity can never read Secrets Manager.
- **Deterministic hook ordering** — `ticketing-eso` ServiceAccount (weight `-30`) → `SecretStore` (`-20`) → `ExternalSecret` (`-10`) → `migrate` (`0`), so credentials exist before migrations run.
- **Hardened, least-privilege runtime** — non-root (`runAsUser: 1000`), `readOnlyRootFilesystem: true`, all capabilities dropped, `seccompProfile: RuntimeDefault`, 8 `emptyDir` mounts per workload, and per-workload `NetworkPolicy` enforced by the VPC CNI.
- **Immutable, traceable images** — the chart rejects `latest` and short SHAs (verified in render); only a 40-character hex SHA renders, and the IMMUTABLE app repo makes every tag a content address.
- **Cost control is the architecture** — `force_destroy`, `recovery_window = 0`, and `skip_final_snapshot` make teardown clean; `teardown.sh` drains the controller-owned ALB before `terraform destroy`; ~$304/month 24/7 becomes ~$74/month on a nights/weekends schedule.
- **Honest cost finding** — the spec assumed interface endpoints would undercut NAT data charges; at dev scale they cost ~$76/month fixed versus ~$1/month of NAT data offloaded, so they were kept (production-shaped) but gated behind a one-line `−$76` toggle.
- **Six cross-artifact integration issues diagnosed and resolved** before any apply (see below).

## Infrastructure Components

Terraform resources are summarised per module (the sources give per-module inventories, not a single total); in-cluster objects are what the Helm charts render.

| Component | Count | Details |
|---|---|---|
| **Bootstrap backend** | 1 stack | KMS key + `alias/ticketing-dev-tfstate`, S3 bucket `ticketing-dev-tfstate-022499047467` (versioned, SSE-KMS, `DenyInsecureTransport`), DynamoDB lock table `ticketing-dev-tflock` |
| **Terraform modules** | 7 | `network`, `eks`, `ecr`, `database`, `cache`, `storage`, `secrets`, composed by `terraform/dev` |
| **VPC + subnets** | 1 + 4 | `10.42.0.0/16`; public `/20` × 2, private `/19` × 2; `10.42.96.0/19`+ reserved |
| **NAT / IGW** | 1 / 1 | Single shared NAT in AZ-a serves both private route tables |
| **VPC endpoints** | 1 + 4 | S3 gateway (always on) + ECR API, ECR DKR, STS, Logs interface endpoints (default on) |
| **EKS cluster** | 1 | `ticketing-dev`, `1.36`, `api` + `audit` logs (7-day), OIDC provider, access entries, 5 add-ons (`vpc-cni`, `coredns`, `kube-proxy`, `eks-pod-identity-agent`, `aws-ebs-csi-driver`) |
| **Node groups** | 2 | `system` 1 × `t4g.small` ON_DEMAND; `app` 2-4 × `t4g.medium` SPOT |
| **IRSA roles** | 6 | `alb_controller`, `external_secrets`, `cluster_autoscaler`, `app` (S3-only), `fluent_bit`, `cloudwatch_exporter` |
| **ECR repositories** | 2 | `ticketing/app` IMMUTABLE (untagged > 1 d, keep 10); `ticketing/app-cache` MUTABLE (untagged > 7 d) |
| **RDS MySQL** | 1 | 8.0, `db.t4g.micro`, Single-AZ, 20 GB gp3 encrypted, SG `3306` from node SG only |
| **ElastiCache Redis** | 1 | 7.1, `cache.t4g.micro`, 1 node, at-rest + in-transit encryption, AUTH, SG `6379` from node SG only |
| **S3 attachments** | 1 | Versioned, SSE-S3, public access blocked, noncurrent expiry 7 d, `force_destroy` |
| **Secrets Manager** | 4 | `ticketing-dev/app-key`, `/smtp`, `/database`, `/redis-auth` |
| **Helm app chart** | 16 rendered documents | Includes web/worker Deployments, scheduler CronJob, migrate Job, 2 ServiceAccounts, SecretStore + ExternalSecret, Service, Ingress, HPA, ScaledObject, PDB, NetworkPolicy, ConfigMap |
| **Platform add-ons** | 11 values files | ALB controller, ESO, KEDA, metrics-server, Cluster Autoscaler, cert-manager, kube-prometheus-stack, Alertmanager, Fluent Bit, YACE, redis-exporter; plus PrometheusRules and 3 dashboards |

## Deployment Issues Diagnosed & Resolved

These six issues were found by cross-component review during the build (recorded in the root README and the project's commit history), not during a live apply — the stack has not been applied.

| Issue | Root cause | Fix |
|---|---|---|
| Redis AUTH would not resolve through ESO | The `ExternalSecret` pulled the Redis key as `auth_token`, but the `ticketing-dev/redis-auth` secret stores it as `password` | Aligned the ExternalSecret `remoteRef` property with the secret's actual `password` key; every key is mapped explicitly so a mismatch surfaces as a named stuck `ExternalSecret` rather than an empty password |
| `AccessDenied` from Secrets Manager on `helm install` | The `SecretStore` authenticated as the `ticketing` app ServiceAccount, whose IRSA role is deliberately S3-only | Split out a dedicated `ticketing-eso` ServiceAccount carrying the read-only `external_secrets` IRSA role (hook weight `-30`); the app SA stays S3-only |
| Ansible and Helm disagreed on the Kubernetes Secret name | `db-maintenance.yml` targeted `ticketing-external-secret`, while the chart emits `ticketing-app` | Pointed the playbook's `external_secret_name` at `ticketing-app` |
| YACE CloudWatch exporter had no AWS identity | The `helm/platform` YACE values expected an IRSA role that the `eks` module did not create | Added the `cloudwatch_exporter` IRSA role (CloudWatch read, `Resource: *` because read actions cannot be resource-scoped) |
| Spec's VPC-endpoint cost premise was inverted | Interface endpoints bill ~$76/month in fixed hourly charges (`$0.013` × 4 × 2 AZ × 730 h) while the NAT data they offload is ~$1/month at dev volume | Kept the endpoints as the production-shaped default but gated them behind `enable_interface_endpoints` (default `true`) as a one-line `−$76` lever; documented in `docs/cost.md` |
| Image build cannot run `composer install` / `npm ci` | `composer.lock` and `package-lock.json` are not committed, and `npm ci` hard-fails without a lockfile | Deliberately not hand-fabricated (a wrong lockfile is worse than none); documented as the first open item with a "Before first build" runbook step to generate and commit them with network access |

## Test Results

Static verification actually performed (from `Result.md`); no live cluster or pod tests have been run.

| Check | Command / scope | Result |
|---|---|---|
| Terraform format | `terraform fmt -recursive -check` | Clean (exit 0) |
| Terraform validate — modules | `terraform validate` on all 7 modules | `Success!` × 7 |
| Terraform validate — bootstrap + `dev` root | `terraform validate` (dev with `-backend=false`) | `Success!` |
| DB password not exported | `grep password modules/database/outputs.tf` | No match — correct |
| Helm lint | `helm lint helm/ticketing` | 1 chart linted, 0 failed |
| Helm render | `helm template` | 16 documents, all parse |
| KEDA key templating | Render + prefix-override test | `laravel_database_queues:default`; changes with prefix |
| Image-tag guard | Render with `latest` / short SHA | Rejected; only 40-char hex SHA renders |
| securityContext + `emptyDir`s | Programmatic audit of 4 workloads | Non-root, RO rootfs, caps dropped, 8 `emptyDir`s each |
| Shell scripts | `shellcheck scripts/*.sh` (v0.11.0) + `bash -n` | Zero findings / OK |
| Python | `py_compile` on `cost-report.py`, `cleanup-old-amis.py` | OK |
| PHP | `php -l` on 60 files; `composer validate` | `failures=0`; valid |
| YAML / JSON | `yaml.safe_load(_all)`, `json.load` | All parse (17 Ansible + 3 workflows + platform; dashboards) |
| Alert runbook anchors | Runbook headers vs `runbook_url` | 4/4 resolve |
| Golden AMI base (live, read-only) | `aws ec2 describe-images … 1.36-*` | Resolves (e.g. `ami-04117a932fe8152dc`) |
| Live deploy + smoke tests | `rebuild.sh`, `verify-deployment.sh` (5 checks) | Not yet run — pending apply |

> The four Pest feature test files under `app/tests/Feature/` are authored but are not recorded as executed.

## Quick Start

```bash
# 0. Verify tooling, confirm identity (account 022499047467, ap-southeast-1)
cd "Laravel Ticketing System on EKS"
./scripts/bootstrap.sh

# 1. (First time only) create the remote-state backend
terraform -chdir=terraform/bootstrap init
terraform -chdir=terraform/bootstrap apply

# 2. Configure and provision the dev environment
cp terraform/dev/terraform.tfvars.example terraform/dev/terraform.tfvars   # set owner_email, admin_principal_arns
terraform -chdir=terraform/dev init
terraform -chdir=terraform/dev apply

# 3. Point kubectl at the cluster (then install helm/platform add-ons)
aws eks update-kubeconfig --region ap-southeast-1 --name ticketing-dev

# 4. Install the app chart by full git SHA — never "latest"
IMAGE_TAG="$(git rev-parse HEAD)"
helm upgrade --install ticketing helm/ticketing -n ticketing --create-namespace \
  --set image.repository="$(terraform -chdir=terraform/dev output -raw ecr_repository_url)" \
  --set image.tag="${IMAGE_TAG}" \
  --set storage.attachmentsBucket="$(terraform -chdir=terraform/dev output -raw attachments_bucket)" \
  --set redis.host="$(terraform -chdir=terraform/dev output -raw redis_address)"

# 5. Five-check smoke test (or run ./scripts/rebuild.sh for steps 2-5 in one pass)
./scripts/verify-deployment.sh

# Teardown in the only safe order: workloads → helm uninstall → wait for ALB → destroy
./scripts/teardown.sh
```

> Allow 15-20 minutes for the EKS control plane, node groups, RDS, and ElastiCache to become healthy and for the first pod and ALB sync. Generate `composer.lock` / `package-lock.json` before the first image build.

## Cost Estimate

`ap-southeast-1`, on-demand list rates pulled live from the AWS Price List API, 730 hours/month — Scenario A (running 24/7, interface endpoints ON).

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
| CloudWatch Logs | ~4 GB | 3.00 |
| S3 attachments + ECR storage | ~10 GB | 1.00 |
| **Total (24/7, endpoints ON)** | | **≈ $304.09 / month** |

| Variant | Monthly (USD) |
|---|---|
| 24/7, `enable_interface_endpoints = false` | ≈ $228 |
| Realistic dev (torn down nights/weekends, ~176 hr) | ≈ $74 |
| Light use (spin-up-to-test, ~60 hr) | ≈ $30 |

> Structural floor: EKS ($73) + four interface endpoints ($76) + NAT ($43) = $192 before any node or database runs, so 24/7 cannot fit the $200 budget — the teardown/rebuild model is the cost control. $0 while destroyed.

## Security Posture

| Topic | Posture |
|---|---|
| Pod → AWS credentials | IRSA per workload, OIDC `sub` scoped to exact namespace/SA; no static keys anywhere |
| Node metadata | IMDSv2 with hop limit `1` — pods cannot reach the node role |
| Container runtime | Non-root, read-only root filesystem, all capabilities dropped, `RuntimeDefault` seccomp |
| Network segmentation | Default-deny `NetworkPolicy` + per-workload allows; `web` ingress allows the ALB public-subnet CIDRs (required with `target-type: ip`) |
| Database exposure | RDS `3306` and Redis `6379` ingress from the node SG only, no CIDR rules; both encrypted, Redis TLS + AUTH |
| Secrets | Secrets Manager → ESO via dedicated `ticketing-eso` identity; app SA is S3-only; scanned clean for AKIA / private keys in Git |
| CI/CD | GitHub OIDC only; plan-only role for `terraform-plan.yml`; actions pinned to major tags (full-SHA pinning documented as prod posture) |
| Image supply chain | IMMUTABLE ECR tags, 40-char SHA guard, basic scan-on-push; cosign + SBOM deferred |
| API server | Public endpoint with `public_access_cidrs = 0.0.0.0/0` — documented to narrow before prod |
| Cluster access | EKS access entries, no `aws-auth` ConfigMap |
| Encryption at rest | AES256 / SSE-S3 (AWS-managed) for S3, RDS, ECR; state bucket SSE-KMS; CMK documented as prod delta |
| Host hardening | Scoped Ansible CIS role that documents the controls it skips (IP-forward disable, `overlay`/`br_netfilter` blacklist, host default-deny) because they break the CNI, containerd, or kube-proxy |

## Project Structure

```
Laravel Ticketing System on EKS/
├── README.md                          # Full documentation (14 sections)
├── Result.md                          # Resource inventory + verification performed (not applied)
├── .gitignore                         # State, tfvars, vendor/node_modules, .env, keys
├── .github/workflows/
│   ├── ci.yml                         # PHP lint/PHPStan/Pest, hadolint, tflint+checkov, ansible-lint, helm+kubeconform
│   ├── terraform-plan.yml             # Plan + priced cost delta on PRs (plan-only role)
│   └── build-deploy.yml               # arm64 build → ECR → helm upgrade by SHA
├── app/                               # Laravel 11 source
│   ├── app/                           # Controllers, Models, Jobs, Mail, Enums, SlaPolicy, EscalateSlaBreaches
│   ├── config/                        # app, cache, queue, session, filesystems, ticketing, ...
│   ├── database/                      # 5 migrations, 2 factories, seeder
│   ├── resources/                     # Blade views, CSS, JS
│   ├── routes/                        # web.php, api.php, health.php, console.php
│   ├── tests/Feature/                 # Attachment, Health, SLA escalation, Ticket creation (Pest)
│   └── composer.json / package.json   # Lockfiles not yet generated
├── docker/
│   ├── Dockerfile                     # Multi-stage arm64 (composer, node, php-fpm)
│   ├── entrypoint.sh
│   ├── nginx/default.conf             # :8080, non-root
│   ├── php/                           # php.ini, opcache.ini, fpm-pool.conf
│   └── supervisor/supervisord.conf
├── packer/
│   ├── eks-node.pkr.hcl               # AL2023 arm64 EKS golden AMI
│   ├── cleanup-old-amis.py            # Prunes superseded AMIs
│   └── README.md
├── ansible/
│   ├── ansible.cfg / requirements.yml / README.md
│   ├── inventory/aws_ec2.yml          # Dynamic EC2 inventory
│   ├── playbooks/                     # node-hardening, bastion, db-maintenance
│   └── roles/                         # base-packages, cis-hardening, containerd-tuning, monitoring-agents
├── terraform/
│   ├── bootstrap/                     # KMS + S3 state + DynamoDB lock (run once)
│   ├── dev/                           # versions, backend, providers, variables, main, outputs, tfvars.example
│   └── modules/                       # network, eks (cluster/nodegroups/irsa/addons), ecr,
│                                      #   database, cache, storage, secrets
├── helm/
│   ├── ticketing/                     # Chart.yaml, values.yaml, 14 manifest templates + helpers/NOTES
│   └── platform/                      # 11 add-on values files, prometheus-rules, 3 dashboards
├── scripts/
│   ├── bootstrap.sh / rebuild.sh / teardown.sh
│   ├── verify-deployment.sh           # 5-check post-deploy smoke test
│   ├── cost-report.py                 # Price List API estimate
│   └── lib.sh                         # Shared shell helpers
└── docs/
    ├── architecture.md                # Scenario, personas, life of a ticket
    ├── cost.md                        # Verified rates, budget verdict, prod deltas
    └── runbook.md                     # Before first build, rotation, alert runbooks
```

## Key Learnings & Technical Decisions

**Decompose by runtime behaviour, not by code.** One Laravel codebase becomes four workloads because it has four genuinely different runtime shapes: request/response (`web`, CPU-scaled), backlog draining (`worker`, queue-depth-scaled via KEDA), exactly-once periodic work (`scheduler`, `concurrencyPolicy: Forbid`), and one-shot schema change (`migrate`, a Helm hook that ships atomically with the code). Each scales and fails independently, which is also what makes an all-Spot app node group safe for dev.

**Identity separation is a design decision, not an afterthought.** The most instructive integration bug was the `SecretStore` authenticating as the app's S3-only ServiceAccount. The fix was not to widen the app role but to give ESO its own `ticketing-eso` identity, so the application can never read Secrets Manager even if compromised. Combined with IMDS hop limit `1`, IRSA becomes the only credential path in the cluster.

**Controller-owned resources change the teardown contract.** The ALB is created by the AWS Load Balancer Controller from an `Ingress`, so it is not in Terraform state. A bare `terraform destroy` hangs and fails with `DependencyViolation`; `teardown.sh` therefore scales workloads to zero, uninstalls Helm, waits for the ALB and its security groups to disappear, and only then destroys.

**Be honest about cost premises.** Pricing the spec's assumption with live Price List data showed interface endpoints cost ~76× what they save at dev traffic. Rather than silently dropping or silently keeping them, the design keeps the production-shaped posture and exposes the trade as a documented toggle — and makes teardown, not resource trimming, the primary cost control.

## What I'd Do Differently

- **Generate and commit the lockfiles first** — `composer.lock` and `package-lock.json` are the first blocker to a real image build and CI run.
- **Apply, measure, and audit** — record the actual `max_connections`, the live Redis queue key, and `rebuild.sh` wall time, then re-run `/audit` so `Result.md` carries live IDs instead of an inventory.
- **Run the authored CI pipeline for real** — `ci.yml` wires Pest, PHPStan, tflint, checkov, and kubeconform, but only `php -l` and the static checks above are recorded as executed.
- **Narrow `public_access_cidrs`** and pin every third-party action to a full commit SHA.
- **Add the app-side latency metric** (`http_request_duration_seconds_bucket{route}`) so the p95 dashboard works.
- **Apply the documented production deltas** when promoting: Multi-AZ RDS, NAT per AZ, a Redis replica with failover, on-demand web nodes, a CMK, all five control-plane log types, and cosign/SBOM with a blocking scan gate.

## Summary

This project demonstrates a production-shaped Kubernetes platform built as a disposable `dev` environment: a Laravel 11 help desk split into four behaviour-driven workloads on EKS `1.36` (Graviton), backed by RDS MySQL, TLS-only ElastiCache Redis, S3, and four Secrets Manager secrets synced by the External Secrets Operator, with IRSA as the only credential path, hardened non-root containers, three independent autoscalers, a Packer + Ansible golden-AMI pipeline, and GitHub Actions deploying immutable SHA-tagged images over OIDC. It spans 7 Terraform modules plus a bootstrap backend and a `dev` root, a 16-document Helm chart, and 11 platform add-on values files; six cross-artifact integration issues were caught and resolved in review. It is verified to the ceiling of static validation — `terraform validate`, `helm lint`/`template`, `shellcheck`, `php -l` on 60 files — but **not yet applied**, with lockfile generation the first open item. Estimated cost is ~$304/month 24/7 and ~$74/month on the intended nights/weekends teardown schedule, $0 while destroyed.
