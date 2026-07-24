# Deployment Result — Laravel Ticketing System on Amazon EKS

**Date:** 2026-07-24
**Region:** `ap-southeast-1` (Asia Pacific, Singapore)
**Environment:** `dev` (the only environment — no staging, no prod)
**Account:** `022499047467`

> **Status: AUTHORED AND VALIDATED — NOT YET APPLIED.**
> This is a reproducible-from-code build verified to the ceiling of static analysis
> (`terraform validate`, `helm lint`/`template`, `shellcheck`, `php -l`, YAML/JSON parse,
> a live read-only AMI lookup). No `terraform apply`, `helm install`, `packer build`, or any
> AWS mutation has been run, so this file lists the resource **inventory the code provisions**
> and the **verification actually performed** — not live ARNs or resource IDs. Those get
> filled in on first apply. This mirrors the project's core deliverable: the platform is
> destroyed and rebuilt on demand from code, and that rebuild capability — not a long-lived
> running stack — is the artifact.

---

## How this differs from a normal `/audit`

The `/audit` skill reads live AWS resource data. With nothing applied, a live audit would return
an empty account. Rather than fabricate ARNs, this report documents what a `terraform apply` of
`terraform/dev/` (after `terraform/bootstrap/`) will create, grounded in the validated configuration.
On first deployment, re-run `/audit` to replace the inventory below with live resource IDs.

---

## Resource inventory (what the code provisions)

Counts are the Terraform-managed resources per module in `terraform/dev/`, plus the in-cluster
objects the Helm charts render. Exact per-resource ARNs are populated on apply.

### Terraform — `terraform/bootstrap/` (run once, local state)

| # | Resource Type | Name |
|---|---|---|
| 1 | KMS key + alias | `alias/ticketing-dev-tfstate` |
| 2 | S3 bucket (versioned, SSE-KMS, public-access-blocked) | `ticketing-dev-tfstate-022499047467` |
| 3 | DynamoDB lock table (PAY_PER_REQUEST, PITR, SSE) | `ticketing-dev-tflock` |
| 4 | S3 bucket policy (`DenyInsecureTransport`) + ownership/public-access controls | — |

### Terraform — `terraform/dev/` (S3 backend, DynamoDB lock)

| Module | Component tag | Key resources |
|---|---|---|
| `network` | `network` | VPC `10.42.0.0/16`; 2 public + 2 private subnets across `ap-southeast-1a/1b`; 1 shared NAT Gateway; IGW; 2 private route tables; S3 gateway endpoint (free, always on); 4 interface endpoints (ECR API/DKR, STS, CloudWatch Logs) gated behind `enable_interface_endpoints` (default `true`); endpoint SG; optional flow logs (default off) |
| `eks` | `compute` | EKS cluster `1.36` (`api`+`audit` logs only, 7-day log group); `system` node group (1×`t4g.small` on-demand, tainted); `app` node group (2–4×`t4g.medium` Spot); OIDC provider; node SG; launch templates (IMDSv2, hop-limit 1, gp3 encrypted); EKS access entries; addons: vpc-cni (network policy on), coredns, kube-proxy, pod-identity-agent, ebs-csi; **6 IRSA roles** (`alb_controller`, `external_secrets`, `cluster_autoscaler`, `app` [S3-only], `fluent_bit`, `cloudwatch_exporter`) |
| `ecr` | `registry` | `ticketing/app` (IMMUTABLE, scan-on-push, AES256, lifecycle: expire untagged >1d, keep 10 tagged); `ticketing/app-cache` (MUTABLE, for BuildKit); repository policies granting pull to the node roles |
| `database` | `data` | RDS MySQL 8.0 `db.t4g.micro` Single-AZ, 20 GB gp3 encrypted; SG (3306 from node SG only); parameter group; credentials in Secrets Manager `ticketing-dev/database` (never an output) |
| `cache` | `data` | ElastiCache Redis 7.1 `cache.t4g.micro` single node; encryption at-rest + in-transit; AUTH token in `ticketing-dev/redis-auth`; SG (6379 from node SG only) |
| `storage` | `data` | S3 attachments bucket (versioned, SSE-S3, public-access-blocked, noncurrent expiry 7d, `force_destroy`) |
| `secrets` | `data` | Secrets Manager `ticketing-dev/app-key` and `ticketing-dev/smtp` (`recovery_window=0`) |

### Kubernetes — `helm/ticketing/` (release `ticketing`, namespace `ticketing`)

| Kind | Name | Purpose |
|---|---|---|
| Deployment | `ticketing-web` | nginx + php-fpm; 2 replicas; HPA 2–4 @ 70% CPU; PDB `minAvailable:1`; AZ anti-affinity |
| Deployment | `ticketing-worker` | `queue:work`; KEDA-scaled on `laravel_database_queues:default`; `terminationGracePeriod:120` |
| CronJob | `ticketing-scheduler` | `schedule:run` every minute; `concurrencyPolicy: Forbid` |
| Job (Helm hook) | `ticketing-migrate` | `migrate --force --isolated`; `pre-install,pre-upgrade` weight 0 |
| ServiceAccount | `ticketing` | app IRSA — **S3-only** |
| ServiceAccount | `ticketing-eso` | External Secrets IRSA identity (weight -30) |
| SecretStore + ExternalSecret | `ticketing-app` | materialises the 4 secrets (weights -20 / -10) |
| Service / Ingress | `ticketing-web` / ALB | internet-facing ALB, ACM cert, HTTP→HTTPS |
| NetworkPolicy | default-deny + allows | DB/Redis/DNS egress; ALB-subnet + ingress-ns ingress |
| HPA / ScaledObject | web / worker | CPU and queue-depth autoscaling |

### Kubernetes — `helm/platform/` (observability + add-ons)

kube-prometheus-stack (7-day retention, no persistence), 4 PrometheusRule alerts, 3 Grafana
dashboards-as-code, prometheus-redis-exporter, YACE CloudWatch exporter, Fluent Bit (7-day CW Logs),
Alertmanager (Slack via secret), plus AWS Load Balancer Controller, External Secrets Operator,
metrics-server, KEDA, cert-manager, Cluster Autoscaler.

---

## Verification actually performed

Every command below was run during the build; output was pasted in the engineers' reports.

| Check | Command | Result |
|---|---|---|
| Terraform format | `terraform fmt -recursive -check` | exit 0, clean |
| Terraform validate — all 7 modules | `terraform validate` per module | `Success! The configuration is valid.` (×7) |
| Terraform validate — bootstrap | `terraform validate` | `Success!` |
| Terraform validate — `dev` root | `terraform init -backend=false && terraform validate` | `Success!` |
| DB password not exported | `grep password modules/database/outputs.tf` | no match (exit 1) — correct |
| Helm lint | `helm lint helm/ticketing` | `1 chart(s) linted, 0 chart(s) failed` |
| Helm render | `helm template … ` | 16 documents, all parse |
| KEDA key templated | render + override test | `laravel_database_queues:default`, changes with prefix override |
| Image-tag guard | render with `latest` / short SHA | rejected; only 40-char hex SHA renders |
| securityContext + emptyDirs | programmatic audit of 4 workloads | non-root, RO-rootfs, caps dropped, 8 emptyDirs each |
| Shell scripts | `shellcheck scripts/*.sh` (v0.11.0) | exit 0, zero findings |
| Shell syntax | `bash -n` on all `.sh` | OK |
| Python | `py_compile` cost-report + cleanup-old-amis | OK |
| PHP lint | `php -l` on 60 files | `failures=0` |
| composer.json | `composer validate` | valid |
| Workflow / K8s / Ansible YAML | `yaml.safe_load(_all)` | all parse (17 ansible + 3 workflows + platform) |
| Dashboards | `json.load` | all parse |
| Alert anchors | grep runbook headers vs `runbook_url` | 4/4 resolve |
| Golden AMI base (live, read-only) | `aws ec2 describe-images … 1.36-*` | resolves, e.g. `ami-04117a932fe8152dc` |
| Provider version (live) | GitHub latest release | aws `v6.56.0` (`~> 6.0`) |

---

## Cost summary (live AWS Price List API, `ap-southeast-1`)

| Scenario | Monthly USD | vs $200 budget |
|---|---|---|
| 24/7, interface endpoints ON (default) | ~$304 | over |
| 24/7, endpoints OFF (`enable_interface_endpoints=false`) | ~$228 | over |
| Realistic dev (teardown nights/weekends, ~176 hr) | ~$74 | under |
| Light use (spin-up-to-test, ~60 hr) | ~$30 | at target |

Structural floor (EKS $73 + 4 endpoints $76 + NAT $43 = $192) makes 24/7-under-$200 impossible with
EKS + NAT + RDS + Redis + ALB all running. The teardown model is the cost control. Full breakdown and
the production-delta are in `docs/cost.md`.

---

## Definition of Done — status

| Item | Status |
|---|---|
| `terraform apply` in a clean account, no manual steps | Authored + validate-clean; **apply pending** |
| `teardown.sh` → `rebuild.sh` under 30 min | Scripts written; **measure on first apply** |
| Commit to `main` reaches the cluster automatically | `build-deploy.yml` authored (OIDC, SHA-check, atomic) |
| Image traceable to a Git SHA, tag not overwritable | ECR IMMUTABLE + 40-char SHA guard — verified in render |
| Killing a pod → zero user errors | PDB + anti-affinity + readiness authored; **verify live** |
| Spot interruption → zero lost jobs | `terminationGracePeriod:120` + graceful `queue:work`; **verify live** |
| DB connections < 50% of `max_connections` | fpm math 20/85 (~24%); **measure live** |
| No secret value in Git history | scanned clean (AKIA / private-key), secrets via Secrets Manager + ESO |
| Every alert has a runbook entry | 4/4 anchors resolve |
| `terraform destroy` leaves no orphans | `force_destroy`, `recovery_window=0`, teardown ALB-drain ordering; **verify live** |
| Infracost under $200/month | Under $200 realistic; over 24/7 — documented, teardown is the control |

---

## Open items before this is live

1. **Generate lockfiles** — `composer.lock` and `package-lock.json` are not committed; the Docker
   build (`composer install`, `npm ci`) requires them. Run `composer install && npm install` once with
   network access. See `docs/runbook.md` → "Before first build".
2. **Apply `terraform/bootstrap/`** first (creates the state backend), then `terraform/dev/`.
3. **Measure and record** in `docs/runbook.md`: actual `max_connections`, `redis-cli KEYS "*queues*"`,
   and `rebuild.sh` elapsed time.
4. **App-side metrics** — add `http_request_duration_seconds_bucket{route}` for the p95 latency
   dashboard (queue-depth and RDS-connection dashboards already work with no app change).
