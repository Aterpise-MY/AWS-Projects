# Cost — Meridian Support Co. Ticketing Platform (dev)

Monthly cost model for the `ticketing-dev` environment in `ap-southeast-1`
(account `022499047467`). All fixed rates were pulled live from the AWS Price List
API on 2026-07-24; a month is billed as **730 hours**. Usage-driven figures (Spot,
data transfer, LCU, log volume) are labelled `est.` and are not massaged. Design
context is in [`architecture.md`](./architecture.md); operations in
[`runbook.md`](./runbook.md).

> Infracost could not produce this table: its CLI token is invalid (`invalid_grant`)
> and `infracost scan` treats `terraform/dev` as the repo root, so the `../modules`
> sources resolve "outside the repository" and load zero resources. The tables below
> are therefore built by hand from the Price List API.

## Table of Contents

1. [Verified unit rates](#verified-unit-rates)
2. [Scenario A — 24/7, endpoints ON (default)](#scenario-a-247-endpoints-on-default)
3. [The endpoints ON/OFF toggle](#the-endpoints-onoff-toggle)
4. [Scenario B — realistic dev usage](#scenario-b-realistic-dev-usage)
5. [Budget verdict](#budget-verdict)
6. [Every cost-driven decision and what it traded away](#every-cost-driven-decision-and-what-it-traded-away)
7. [The endpoints premise is inverted at dev scale](#the-endpoints-premise-is-inverted-at-dev-scale)
8. [What would change if this were production](#what-would-change-if-this-were-production)

## Verified unit rates

| Item | Rate | Source usagetype |
|---|---|---|
| EKS control plane | `$0.10` / cluster-hr | `APS1-AmazonEKS-Hours:perCluster` |
| NAT Gateway | `$0.059` / hr + `$0.059` / GB | `APS1-NatGateway-Hours` / `-Bytes` |
| Interface VPC endpoint | `$0.013` / endpoint-AZ-hr + `$0.01` / GB | `APS1-VpcEndpoint-Hours` / `-Bytes` |
| S3 Gateway endpoint | `$0.00` (free) | contract mandates it |
| `t4g.small` on-demand | `$0.0212` / hr | EC2 `MZGPYWV687EP4MDV` |
| `t4g.medium` on-demand | `$0.0424` / hr | EC2 `PHK9B7XN4EQWDWPJ` |
| `t4g.medium` Spot (est.) | `~$0.015` / hr | Spot not in Price List API; ~65% off on-demand |
| EBS gp3 | `$0.096` / GB-mo | `APS1-EBS:VolumeUsage.gp3` |
| `db.t4g.micro` MySQL Single-AZ | `$0.025` / hr | RDS `45E67P7R8R7HMVBG` |
| RDS gp3 storage (Single-AZ) | `$0.138` / GB-mo | `APS1-RDS:GP3-Storage` |
| `cache.t4g.micro` Redis | `$0.024` / hr | ElastiCache `2EWBNSK2RMEHF7K3` |
| ALB | `$0.0252` / hr + LCU | `APS1-LoadBalancerUsage` (Application) |
| Secrets Manager | `$0.40` / secret-mo + `$0.05` / 10k req | `APS1-AWSSecretsManager-Secret` |
| CloudWatch Logs | `$0.70` / GB ingest + `$0.03` / GB-mo | `APS1-DataProcessing-Bytes` / `-TimedStorage` |

## Scenario A — 24/7, endpoints ON (default)

The environment left running continuously for a full 730-hour month, with the four
interface VPC endpoints enabled (`enable_interface_endpoints = true`, the default).

| Resource | Qty | Arithmetic | Monthly USD |
|---|---|---|---|
| EKS control plane | 1 | `0.10 × 730` | `73.00` |
| NAT Gateway (hours) | 1 | `0.059 × 730` | `43.07` |
| NAT Gateway (data, ~20 GB) | 20 GB | `0.059 × 20` | `1.18` |
| Interface VPC endpoints | 4 × 2 AZ | `0.013 × 8 × 730` | `75.92` |
| VPC endpoint data (~20 GB) | 20 GB | `0.01 × 20` | `0.20` |
| System node `t4g.small` on-demand | 1 | `0.0212 × 730` | `15.48` |
| App nodes `t4g.medium` Spot (est.) | 2 | `0.015 × 2 × 730` | `21.90` |
| EBS gp3 root volumes | 3 × 20 GB | `0.096 × 60` | `5.76` |
| RDS `db.t4g.micro` Single-AZ | 1 | `0.025 × 730` | `18.25` |
| RDS gp3 storage | 20 GB | `0.138 × 20` | `2.76` |
| ElastiCache `cache.t4g.micro` | 1 | `0.024 × 730` | `17.52` |
| ALB (base + ~1 LCU est.) | 1 | `0.0252 × 730 + ~5` | `23.40` |
| Secrets Manager | 4 secrets | `0.40 × 4 + API` | `1.65` |
| CloudWatch Logs (api/audit + fluent-bit, ~4 GB) | ~4 GB | `0.70 × 4 + storage` | `3.00` |
| S3 attachments + ECR image storage (~10 GB) | ~10 GB | mixed | `1.00` |
| **Total (24/7, endpoints ON)** | | | **`~304.09`** |

> ALB, EBS root volumes, and CloudWatch app logs are created at deploy/runtime (the
> ALB by the AWS Load Balancer Controller, not Terraform), so they appear once
> workloads run. Spot, NAT/endpoint data, LCU, and log volume are usage-driven
> estimates — flagged `est.` — not fixed Price List values.

## The endpoints ON/OFF toggle

`enable_interface_endpoints` (in `terraform/dev/variables.tf`, wired to
`modules/network`) is a one-line lever. Default ON is production-shaped. Turning it
off drops the four interface endpoints (keeping the free S3 gateway endpoint):

| Configuration | Interface endpoints | Monthly total (24/7) | Delta |
|---|---|---|---|
| Endpoints ON (default) | 4 × 2 AZ = `$75.92` | `~$304` | — |
| Endpoints OFF | none (S3 gateway stays, free) | `~$228` | `−$76` |

Turning them off routes ECR/STS/logs egress over the single NAT Gateway instead —
which at dev traffic costs about `$1/mo` in data processing. See
[the inverted premise](#the-endpoints-premise-is-inverted-at-dev-scale) for why
that trade is so lopsided.

## Scenario B — realistic dev usage

The stack is deliberately built for repeatable teardown (`force_destroy = true`,
`secret_recovery_window_days = 0`, `skip_final_snapshot = true`). Running it about
8 hrs/day × 22 workdays = **176 hrs/month** (a 0.241 duty cycle) and destroying it
otherwise scales every hourly and stored resource down roughly proportionally:

| | 24/7, endpoints ON | Realistic (~176 hrs) | Light use (~60 hrs) |
|---|---|---|---|
| **Estimated monthly total** | `~$304` | `~$74` | `~$30` |

The "light use" column is the spin-up-only-to-test pattern (~60 hrs/month), which
is where the environment actually lands in practice.

## Budget verdict

- **Scenario A (24/7, endpoints ON): ~$304/month — OVER the $200 ceiling.**
- **Scenario A with endpoints OFF: ~$228/month — still OVER $200.**
- **Scenario B (realistic business-hours dev, ~176 hrs): ~$74/month — UNDER budget.**
- **Light use (~60 hrs): ~$30/month — at the in-practice target.**

The infrastructure as authored is correct; whether it fits $200 depends entirely on
the run schedule.

> **24/7-under-$200 is structurally impossible with this design.** Three fixed
> anchors dominate the 24/7 figure and cannot be trimmed without changing the
> architecture: the EKS control plane (`$73`), the four interface VPC endpoints
> (`$76`), and the NAT Gateway (`$43`) — together `$192` **before a single node or
> database runs**. Add RDS + Redis + ALB, all of which must be up for the platform
> to function, and $200 is gone. **Teardown is the cost control**, not any single
> resource choice — which is exactly what the whole project is architected for
> (`scripts/teardown.sh`, `scripts/rebuild.sh`, and the destroy-friendly module flags).

### If it must stay up 24/7

1. **Primary lever — use the intended teardown model.** Destroy nights/weekends;
   this is what the module flags are for and it lands at ~$74/month.
2. **Drop the four interface endpoints (`−$76`).** Brings 24/7 to ~$228/month; keep
   the free S3 gateway endpoint. See the inverted-premise section.
3. **Structural costs cannot be trimmed further without changing the design.** The
   EKS control plane (`$73`) and NAT (`$43`) are fixed. A pure-dev variant could
   collapse to one app node (`−~$11`), but 24/7 will not reach $200 while EKS + NAT
   + RDS + Redis + ALB all run continuously.

## Every cost-driven decision and what it traded away

Each row is a deliberate dev-grade choice. The middle column is the money saved;
the right column is what was given up and would be reversed in production (see
[the production section](#what-would-change-if-this-were-production)).

| Decision | Why (cost) | What was traded away |
|---|---|---|
| **Single NAT Gateway** (AZ-a only) | One `$43/mo` NAT instead of one per AZ | If AZ-a's NAT fails, private-subnet egress in both AZs is down. Prod runs one NAT per AZ. |
| **All-Spot app node group** (`t4g.medium`, 2–4) | ~65% off on-demand: `~$22/mo` vs `~$62/mo` for the app tier | Nodes can be reclaimed with 2 minutes' notice; workloads must tolerate interruption. Prod uses on-demand or mixed for the web tier. |
| **Graviton (arm64) everywhere** | `t4g` is cheaper than equivalent `x86` and the whole stack is arm64-native | None at dev — this is a strict win. It just requires arm64 images (which the pipeline builds). |
| **Single-AZ RDS** | Half the cost of Multi-AZ; `$18/mo` for the instance | No standby; an AZ failure or instance failure is downtime, and `skip_final_snapshot = true` means the only recovery point is a manual snapshot. Prod is Multi-AZ + a read replica. |
| **Single-node Redis** (`num_cache_clusters = 1`, no failover) | One `cache.t4g.micro` at `$17.52/mo` instead of a replicated group | No automatic failover; a node loss drops cache, sessions, and the queue at once. Prod adds a replica + `automatic_failover_enabled`. |
| **S3/RDS/ECR use AES256, not a CMK** | No KMS key charges or per-request costs | Encryption keys are AWS-managed, not customer-controlled/rotatable/auditable. Prod uses a CMK. |
| **ECR basic scan-on-push, not Inspector enhanced** | Avoids per-image Inspector charges | Basic CVE scanning only; no continuous re-scan as new CVEs are published. Prod enables Inspector enhanced scanning. |
| **7-day retentions** (control-plane logs, S3 noncurrent versions, ECR untagged) | Minimises CloudWatch storage and S3/ECR storage of stale objects | Short forensic/rollback window. Prod lengthens log and backup retention. |
| **Control-plane logging: `api` + `audit` only** | Two log types instead of five cuts CloudWatch ingest | No `authenticator`/`controllerManager`/`scheduler` logs for deep debugging. Prod turns on all five. |
| **VPC Flow Logs off** (`enable_flow_logs = false`) | No flow-log ingest/storage bill | No network forensics/traffic audit trail. Prod turns them on. |
| **No Prometheus persistence** | No EBS PVC for Prometheus; metrics are in-memory only | Metrics are lost on a Prometheus pod restart — acceptable for a torn-down-nightly env. Prod adds persistent storage (or ships to a managed backend). |
| **CloudWatch Logs over Loki; YACE over classic CW exporter** | Reuses managed CloudWatch instead of running/storing a Loki stack; YACE is lighter than the classic exporter | Less flexible log querying than Loki. Proportionate-dev observability trades. |

## The endpoints premise is inverted at dev scale

The original spec assumed VPC interface endpoints would "cost less than the NAT
data they replace." **At this environment's traffic that premise is inverted, and
it is worth being honest about it.**

- Interface endpoints cost `~$76/mo` in **fixed hourly charges** (`$0.013` ×
  4 endpoints × 2 AZ × 730 h), regardless of whether any traffic flows.
- The NAT **data** they offload — the ECR/STS/logs egress they exist to keep off
  the NAT — is roughly `$1/mo` at dev volumes (`$0.059/GB` × ~20 GB).

So at dev scale the endpoints cost about 76× what they save. They are a
**production** pattern: they earn their keep at volume, and they are the correct
posture for a fully private-subnet design where you do not want data-plane traffic
touching the internet path at all. That is why the design **keeps** them (default
ON, production-shaped) but puts them behind `enable_interface_endpoints` so a
cost-conscious dev run can flip them off for `−$76` with one variable. The honest
framing: at this scale the endpoints buy posture and NAT-independence, not savings.

## What would change if this were production

Every item below is a one-knob change from what is already authored — that is the
whole point of building the dev environment as a faithful, hardenable pattern
rather than a throwaway. None of these require a redesign.

| Area | Dev (now) | Production change |
|---|---|---|
| RDS availability | Single-AZ, no replica | Multi-AZ + a read replica |
| NAT | One NAT in AZ-a | One NAT Gateway per AZ |
| Redis | Single node, no failover | ElastiCache replica + `automatic_failover_enabled` |
| App nodes | All-Spot | On-demand or mixed node groups for the web tier |
| ECR scanning | Basic scan-on-push | Inspector enhanced scanning |
| Encryption | AES256 (AWS-managed) | Customer-managed CMK |
| Control-plane logs | `api` + `audit` | All 5 log types |
| VPC Flow Logs | Off | On |
| Image supply chain | Immutable full-SHA tags | + cosign signing + SBOM, admission-gated |
| CI/CD gates | Build → push → deploy | + a manual approval gate in build-deploy |
| Vulnerability gate | Scan runs, non-blocking | Scan-gate enforced — fail the build on CRITICAL/HIGH |
| Retention | 7-day logs/backups | Longer log and backup retention |
| Tracing | CloudWatch Logs + dashboards | Distributed tracing (OpenTelemetry) end to end |

No numbers in this document were massaged: Spot, data-transfer, LCU, and log
volumes are labelled estimates; every fixed rate is a live Price List value cited
in [Verified unit rates](#verified-unit-rates).
