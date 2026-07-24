# Architecture — Meridian Support Co. Ticketing Platform (dev)

This document explains what the `ticketing-dev` platform is, who it serves, how a
ticket flows through it end to end, why every component sits at the layer it does,
and why some tools that look redundant on a Kubernetes platform (Ansible, Packer)
still earn their place. It is the canonical design reference; the operational
procedures live in [`runbook.md`](./runbook.md) and the money in [`cost.md`](./cost.md).

## Table of Contents

1. [Enterprise Scenario](#enterprise-scenario)
2. [Full-System Architecture](#full-system-architecture)
3. [The Life of a Ticket](#the-life-of-a-ticket)
4. [Why Each Component Sits Where It Does](#why-each-component-sits-where-it-does)
5. [Why Ansible and Packer Still Earn Their Place](#why-ansible-and-packer-still-earn-their-place)
6. [Immutable ECR Tags and the Lifecycle Policy](#immutable-ecr-tags-and-the-lifecycle-policy)
7. [Deliberately Deferred: Signing, SBOM, and Tracing](#deliberately-deferred-signing-sbom-and-tracing)

## Enterprise Scenario

**Company.** Meridian Support Co. is a mid-market B2B SaaS vendor of about 180
employees selling a logistics-tracking product to roughly 400 business customers
across APAC. Support is contractual: SLAs are written into the customer
agreements, so a missed escalation is a financial and reputational event, not a
cosmetic one.

**Why they are building this.** Their current help desk is a hosted, Zendesk-style
SaaS they have outgrown on cost and, more importantly, cannot customise. They need
SLA logic tied to their own customer tiers, and their ticket attachments must live
in their own AWS account for data-residency reasons — Singapore, `ap-southeast-1`.

**This repository is the DEV environment for that platform, and only the dev
environment, on purpose.** The team is two platform engineers and three
application developers. There is no dedicated ops rota, so the platform has to be
cheap, reproducible, and destroyable — nobody babysits it overnight. That single
constraint drives most of the decisions below: the whole environment is built to
be torn down each night and rebuilt each morning inside a published, repeatable
duration (see `scripts/rebuild.sh` and `scripts/teardown.sh`).

**Personas.** The four workloads in the cluster are not a diagram flex — each one
exists to serve a real persona and a real runtime behaviour.

| Persona | Need the infra serves | Workload it drives |
|---|---|---|
| Requester (customer) | Files tickets, receives email updates | `worker` (queued notifications) |
| Agent (support staff) | Works the queue, uploads attachments | `web` + S3 + Redis sessions |
| SLA (the clock) | 15-minute escalation sweep must run once | `scheduler` (CronJob) |
| Platform engineer | Rebuilds the entire env on demand | `migrate` hook + teardown/rebuild scripts |

**Scale and SLOs (dev).** Single-digit concurrent users, tens of tickets a day in
test, no production traffic. The availability target for dev is best-effort
business hours.

> This is exactly why Single-AZ RDS, a single-node Redis, and a single NAT Gateway
> are all correct here and would all be wrong in production. The postures below are
> dev-grade implementations of prod-grade patterns — OIDC + IRSA instead of static
> keys, Secrets Manager + External Secrets instead of secrets in Git, non-root
> read-only-rootfs containers, least-privilege IAM. The point is that the pattern is
> already in place and can harden without a redesign. The production deltas are
> enumerated in [`cost.md`](./cost.md#what-would-change-if-this-were-production).

## Full-System Architecture

```
                                     Internet
                                        │
                                        │ HTTPS
                                        ▼
                          ┌─────────────────────────┐
                          │   Internet Gateway (IGW)  │
                          └────────────┬─────────────┘
                                       │
              ┌────────────────────────┼────────────────────────┐
              │  Public subnets  10.42.0.0/20 · 10.42.16.0/20    │
              │  ┌─────────────────────────────┐  ┌───────────┐  │
              │  │  Application Load Balancer    │  │    NAT    │  │
              │  │  (created by AWS LB Controller│  │  Gateway  │  │
              │  │   from the Ingress object,    │  │  (AZ-a)   │  │
              │  │   target-type: ip)            │  └─────┬─────┘  │
              │  └───────────────┬──────────────┘        │        │
              └──────────────────┼────────────────────────┼───────┘
                                 │ to pod ENIs             │ egress
              ┌──────────────────┼────────────────────────┼───────┐
              │  Private subnets  10.42.32.0/19 · 10.42.64.0/19    │
              │                   ▼                                 │
              │   ┌───────────────────────────────────────────┐   │
              │   │            EKS 1.36  (arm64/Graviton)        │   │
              │   │                                              │   │
              │   │  system node group (t4g.small, ON_DEMAND,    │   │
              │   │   taint CriticalAddonsOnly): ALB controller, │   │
              │   │   External Secrets, cluster-autoscaler, KEDA,│   │
              │   │   metrics-server, Fluent Bit, kube-prom-stack│   │
              │   │                                              │   │
              │   │  app node group (t4g.medium, SPOT, 2–4):     │   │
              │   │   ns ticketing ─────────────────────────────┐│   │
              │   │    ┌────────┐ ┌────────┐ ┌─────────┐ ┌─────┐││   │
              │   │    │  web   │ │ worker │ │scheduler│ │migr.│││   │
              │   │    │Deploy. │ │Deploy. │ │ CronJob │ │ Job │││   │
              │   │    │nginx+  │ │queue:  │ │schedule:│ │php  │││   │
              │   │    │php-fpm │ │work    │ │run/15m  │ │migr.│││   │
              │   │    └───┬────┘ └───┬────┘ └────┬────┘ └──┬──┘││   │
              │   └────────┼──────────┼───────────┼─────────┼───┘│   │
              │            │          │           │         │    │   │
              └────────────┼──────────┼───────────┼─────────┼────┘   │
                           │          │           │         │        │
       ┌───────────────────┼──────────┼───────────┼─────────┼────────┼──────┐
       │  VPC endpoints    │          │           │         │        │      │
       │  s3 (Gateway,free)│  ecr.api · ecr.dkr · sts · logs (Interface)     │
       └───────────────────┼──────────┼───────────┼─────────┼────────┼──────┘
                           ▼          ▼           ▼         ▼        ▼
                    ┌──────────┐┌──────────┐┌──────────┐┌────────┐┌──────────┐
                    │   RDS    ││ElastiCach││    S3     ││Secrets ││   ECR    │
                    │  MySQL   ││  Redis   ││attachment ││Manager ││app +     │
                    │ 8.0 t4g  ││ 7.1 t4g  ││ bucket    ││4 secre.││cache repo│
                    │ Single-AZ││ 1 node   ││(versioned)││        ││IMMUTABLE │
                    └──────────┘└──────────┘└──────────┘└────────┘└──────────┘

  Identity plane (no long-lived keys anywhere):
  ┌──────────────────────────────────────────────────────────────────────────┐
  │  OIDC provider  ──►  IRSA roles bound to exact service accounts:           │
  │    system:serviceaccount:ticketing:ticketing        → S3 only (app SA)     │
  │    system:serviceaccount:ticketing:ticketing-eso    → Secrets Manager read │
  │    system:serviceaccount:external-secrets:external-secrets → Secrets read  │
  │    + alb_controller, cluster_autoscaler, fluent_bit, cloudwatch_exporter   │
  │                                                                            │
  │  External Secrets flow:                                                    │
  │    SecretStore (auth: ticketing-eso SA)  ──►  reads ticketing-dev/*        │
  │      ──►  writes a k8s Secret  ──►  mounted by web/worker/scheduler/migrate │
  └──────────────────────────────────────────────────────────────────────────┘
```

**Traffic flow:** Internet → IGW → ALB in the public subnets → (target-type `ip`)
directly to `web` pod ENIs in the private subnets → php-fpm. Outbound app traffic
to AWS APIs prefers the VPC endpoints (S3 gateway, and the four interface
endpoints for ECR/STS/logs); anything with no endpoint egresses through the single
NAT Gateway in AZ-a. Data services (RDS, ElastiCache, S3, Secrets Manager) are
reached over private networking only.

> Two identities, one operator. The `ticketing-eso` service account is
> deliberately distinct from the app service account. The app SA (`ticketing`)
> carries an IRSA role scoped to S3 on the attachments bucket only and cannot read
> Secrets Manager. The `ticketing-eso` SA carries the read-only Secrets Manager
> role and is the identity the namespaced `SecretStore` authenticates as. Splitting
> them keeps the app's blast radius at "its own bucket" while still letting the
> platform pull the four secrets. See [Seam-4 in the decisions ledger] and
> `helm/ticketing/templates/serviceaccount.yaml`.

## The Life of a Ticket

Tracing one ticket end to end names which workload and which AWS service each step
touches. This is the clearest way to see why the four-workload split exists.

```
 1. CREATE            Agent/requester POSTs /tickets
    ────────          web pod (nginx → php-fpm) → TicketController::store()
                      · writes the row to RDS MySQL (reference TCK-000123)
                      · SlaPolicy::dueAt() sets sla_due_at from the priority tier
                      · session state read/written to ElastiCache Redis (DB 1)
                                    │
                                    ▼
 2. QUEUE NOTIFY      SendTicketNotification::dispatch($ticket, 'created')
    ────────          · job pushed onto Redis list laravel_database_queues:default
                        (Redis logical DB 2 — the queue index)
                      · web pod returns immediately; it never speaks SMTP inline
                                    │
                                    ▼
 3. WORKER DRAINS     worker Deployment (php artisan queue:work) pops the job
    ────────          · sends TicketNotificationMail via SMTP (creds from
                        Secrets Manager ticketing-dev/smtp)
                      · KEDA watches the SAME Redis list length and scales the
                        worker Deployment 0→N on backlog
                                    │
                                    ▼
 4. ATTACH TO S3      Agent uploads a file: POST /tickets/{t}/attachments
    ────────          web pod → AttachmentController::store()
                      · Storage::disk('s3')->putFileAs() streams to the
                        attachments bucket via the app IRSA role (multipart)
                      · object key generated (ULID) — no client path traversal
                      · download later = 302 to a 5-min pre-signed URL, so a
                        large transfer never occupies a php-fpm child
                                    │
                                    ▼
 5. SLA SWEEP         scheduler CronJob fires every minute (Kubernetes heartbeat);
    ────────          Laravel's own schedule runs tickets:escalate-sla every 15m
                      · EscalateSlaBreaches finds open tickets past sla_due_at
                      · raises priority, sets new sla_due_at, writes RDS
                      · dispatches SendTicketNotification($ticket,'escalated')
                        → back to step 2's Redis queue → worker → SMTP
```

The scheduler pod must finish fast and must never run twice at once: the CronJob
carries `concurrencyPolicy: Forbid`, and inside the app `->everyFifteenMinutes()`
is guarded with `->withoutOverlapping(30)`, whose lock lives in the Redis cache
store (DB 0). The escalation command dispatches the notification to the queue
rather than sending it inline, exactly so the scheduler tick returns before the
next CronJob firing.

## Why Each Component Sits Where It Does

| Layer | Component | Why here |
|---|---|---|
| Edge | Application Load Balancer | L7 routing and TLS termination for the `web` HTTP path. Created by the AWS Load Balancer Controller from the `Ingress` object, `target-type: ip` so it addresses pod ENIs directly. It is NOT in Terraform state — the controller owns it, which is why teardown must `helm uninstall` before `terraform destroy`. |
| Edge | NAT Gateway (single, AZ-a) | One egress path for private-subnet traffic that has no VPC endpoint. Single NAT is a deliberate dev cost trade; prod would run one per AZ. |
| Compute | EKS 1.36, system node group | Runs the platform add-ons only. Tainted `CriticalAddonsOnly=true:NoSchedule` and on ON_DEMAND capacity so controllers are not evicted by a Spot reclaim. |
| Compute | EKS app node group (Spot 2–4) | Runs the four application workloads. All-Spot is a dev cost trade; the workloads tolerate interruption because the queue is durable-enough and the web tier is replicated. |
| Compute | `web` Deployment | Stateless nginx + php-fpm. Horizontal — sessions live in Redis, attachments in S3, so any pod can serve any request. HPA + PodDisruptionBudget. |
| Compute | `worker` Deployment | Isolates slow, failure-prone SMTP work off the request path. Scaled by KEDA on Redis queue length, independent of the web tier. |
| Compute | `scheduler` CronJob | The SLA clock. A CronJob (not a sidecar loop) so Kubernetes guarantees at-most-one via `concurrencyPolicy: Forbid`. |
| Compute | `migrate` Job (Helm pre-upgrade hook) | Schema changes run once per release, before new pods roll, ordered after the secret chain (weights −30/−20/−10/0). |
| Data | RDS MySQL 8.0 (Single-AZ) | System of record: tickets, comments, users, failed_jobs. Private subnets, SG ingress from node SG only, no public path. |
| Data | ElastiCache Redis 7.1 (1 node) | Three logical roles on one node: DB 0 cache, DB 1 sessions, DB 2 queue. TLS + AUTH token. The queue index is the load-bearing one KEDA reads. |
| Data | S3 attachments bucket | Durable object store for uploads — the only correct home given read-only-rootfs pods and multi-pod web tier. Versioned, private, 7-day noncurrent expiry. |
| Data | Secrets Manager (4 secrets) | `app-key`, `database`, `redis-auth`, `smtp`. No secret ever lands in Git or a container image. |
| Registry | ECR (app + cache repos) | App images (immutable) and a BuildKit layer cache (mutable). Pulled by the nodes over the ECR interface endpoints. |
| Identity | OIDC provider + IRSA roles | Every pod that talks to AWS assumes a role scoped to exactly what it needs, via a projected token — no static credentials anywhere. IMDS hop limit is 1 on the nodes so pods cannot borrow the node role. |
| Networking | VPC endpoints (S3 gateway + 4 interface) | Keep ECR/STS/logs traffic on private networking rather than the NAT path. The S3 gateway endpoint is free and mandatory; the interface endpoints are a production-shaped posture gated behind `enable_interface_endpoints` (see cost note). |

## Why Ansible and Packer Still Earn Their Place

A containerised, Kubernetes-native platform looks like it should have no use for a
configuration-management tool or an image baker — the app is a container, and
Kubernetes reconciles the app. That intuition is correct about the **application**
and wrong about the **host** underneath it. The two tools survived precisely
because Kubernetes took the application config away from them, which narrowed their
scope to the one thing Kubernetes does not manage: the EC2 node itself.

There are three configuration surfaces here, and they belong to three different owners:

```
   Packer   owns the MACHINE IMAGE   — what a node boots from
   Ansible  owns the HOST            — kernel, containerd, kubelet tuning, CIS
   Kubernetes/Helm owns the APP      — the four workloads and their config
```

**Packer** bakes a hardened EKS node AMI (`packer/eks-node.pkr.hcl`). It does not
build from bare Amazon Linux — it layers a baseline on top of AWS's official
`amazon-eks-node-al2023-arm64-standard-1.36-*` image, because reproducing
kubelet/containerd/nodeadm packaging by hand is a maintenance liability with no
upside. What Packer produces is a single AMI ID written to `manifest.json` and
consumed by Terraform as `modules/eks var.node_ami_id`. The value it adds on a
container platform is a *known, immutable, CVE-attributable starting point* for
every node — the AMI is tagged with its source AMI, git SHA, and build timestamp,
so "what exactly is running on our nodes and where did it come from" has one answer.

**Ansible** owns everything inside that image that is below the container runtime:
base packages and time sync, CIS hardening, containerd/kubelet tuning, and the
monitoring agents (`ansible/roles/*`). Crucially, Packer *invokes* Ansible during
the bake, but the roles live outside Packer so the **same** code can be re-applied
to a running node for drift correction, or run as day-2 operations. That day-2 role
is where Ansible still clearly pays for itself on this platform:
`ansible/playbooks/db-maintenance.yml` takes RDS snapshots, diffs live schema
against a committed baseline, and rotates the database credential in RDS + Secrets
Manager — then asks the Kubernetes control plane for a rolling restart rather than
touching pods itself.

**How their scope narrowed once Kubernetes arrived.** Before Kubernetes, an Ansible
role like this would also deploy the application, template its config, and restart
its service. Here it does none of that, and the playbook says so in a hard "layer
boundary" banner: Ansible does not deploy the app, does not edit Kubernetes
Secrets, and does not alter the schema (`php artisan migrate` runs as a Helm hook).
Kubernetes took application lifecycle, config, and rollout. What was left for
Ansible is the node OS and AWS-control-plane day-2 work — a smaller job than it
used to have, but a real one that Kubernetes has no opinion about.

> The CIS hardening is scoped, not blanket. The role documents which controls it
> deliberately skips — disabling IP forwarding, blacklisting overlay /
> `br_netfilter` / `nf_conntrack`, host default-deny firewalling — because each of
> those breaks the CNI, containerd, or kube-proxy on an EKS node. Hardening that
> bricks the kubelet is not hardening.

## Immutable ECR Tags and the Lifecycle Policy

The app repository is `image_tag_mutability = "IMMUTABLE"`, images are always
tagged with the full 40-character git SHA (never `latest`), and a lifecycle policy
expires untagged images after 1 day and keeps the 10 most recent tagged images.
These three choices are one design, and each covers a gap the others leave.

**Why immutable tags are correct.** An immutable tag is a permanent, one-to-one
binding between a tag and an image digest: once `…:<sha>` is pushed, that tag can
never be re-pointed at different bytes. That gives you a guarantee Kubernetes
relies on — the image a Deployment references cannot change underneath it.

**What specifically breaks when you deploy `latest` to Kubernetes.** Kubernetes
does not re-pull an image it already has cached on a node unless `imagePullPolicy`
forces it, and a Deployment whose pod spec still says `:latest` has no change for
the control plane to detect — so `kubectl apply` / `helm upgrade` is a no-op even
though "latest" now means different bytes upstream. The concrete failure modes:

- **Rollouts silently do nothing.** You push a fix as `latest`, run `helm upgrade`,
  the pod template is byte-identical, no rollout happens, and the old code keeps
  running. The deploy "succeeds" and changes nothing.
- **Node-to-node drift.** A scale-up or Spot replacement pulls `latest` *now* and
  gets the new bytes, while pods already scheduled still run the old cached image.
  The same Deployment is now running two different builds and which one served a
  request depends on which node it landed on.
- **Rollback is impossible.** There is no earlier digest to go back to — every
  build overwrote the same tag. You cannot answer "what was running at 14:00?"

The full-SHA immutable tag makes every deploy an explicit, detectable pod-template
change (which is what makes `helm rollback` meaningful) and makes "what is running"
a question with a durable answer.

**Why immutability needs the lifecycle policy as its pair.** Immutable tags can
never be overwritten, so nothing is ever reclaimed by reuse — every build is a new,
permanent object and the repo grows without bound and bills forever. The lifecycle
policy is the required counterweight: expire untagged layers (orphaned by newer
pushes) after a day, and cap retained tagged images at 10 so old SHAs are reclaimed
on a rolling basis. Immutability without a lifecycle policy is a slow storage leak;
a lifecycle policy without immutability lets tags drift. You need both.

> The BuildKit cache repository is the deliberate exception: it is `MUTABLE`.
> `docker buildx --cache-to type=registry` overwrites a fixed cache tag on every
> build by design. An IMMUTABLE cache repo does not fail loudly — cache export is
> best-effort, so builds still pass but silently re-import a stale manifest, and the
> only symptom is CI build times slowly regressing with nothing erroring. Its
> lifecycle policy expires untagged manifests after 7 days.

## Deliberately Deferred: Signing, SBOM, and Tracing

Three production-grade controls are designed-for but intentionally not enabled in
dev. Documenting *where* they slot in matters more than enabling them on an
environment that is torn down nightly.

| Control | Where it inserts | What it addresses | Status in dev |
|---|---|---|---|
| cosign image signing + SBOM | In `.github/workflows/build-deploy.yml`, right after the image is pushed to ECR and before the deploy step: `cosign sign` the digest and attach an SBOM (`syft`/`cosign attest`). A cluster-side admission policy would then reject unsigned digests. | Supply-chain integrity — proof that the digest a node pulls is the exact artefact CI built, and a machine-readable inventory of what is inside it for CVE response. | Skipped. The immutable full-SHA tag already gives provenance; signing adds the cryptographic gate that a real registry-to-cluster trust boundary needs. |
| OpenTelemetry tracing | An OTel SDK in the Laravel app exporting spans, plus an OTel Collector DaemonSet/Deployment on the cluster; spans cover the web → queue → worker → SMTP and web → RDS/Redis/S3 paths. | Distributed latency and failure attribution across the four workloads — answering "where did this ticket's notification spend its time / where did it fail" without grepping four logs. | Skipped. CloudWatch Logs (via Fluent Bit) plus the four Prometheus dashboards cover dev; the p95-latency-by-route dashboard is the documented follow-up that needs the app to expose `http_request_duration_seconds_bucket{route}`. |

Both are one-knob additions to what is already authored, which is the point: the
platform is shaped so these harden in without a redesign. The full production-delta
list is in [`cost.md`](./cost.md#what-would-change-if-this-were-production).
