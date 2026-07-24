# Platform Add-ons (`helm/platform/`)

Cluster-scoped controllers and the observability stack for the `ticketing-dev`
EKS cluster. The application chart in `helm/ticketing/` deliberately installs
none of these — it declares them as prerequisites (`ticketing.io/requires`) and
assumes they already exist. This directory is that "already exists": one values
file per add-on, plus the alert rules, dashboards-as-code, and exporters that
turn a running cluster into an observable one.

Everything here is sized for a **single, disposable dev environment** on a
two-node-group cluster (`1x t4g.small` system, `2-4x t4g.medium` Spot app). The
recurring theme in the comments is that durability and breadth are traded away
for cost on purpose. None of these settings should be copied to production
unchanged.

## Table of Contents

1. [Why this lives outside the app chart](#why-this-lives-outside-the-app-chart)
2. [Install order](#install-order)
3. [What each piece is and why it is here](#what-each-piece-is-and-why-it-is-here)
4. [Templated values from Terraform](#templated-values-from-terraform)
5. [Secrets that must exist first](#secrets-that-must-exist-first)
6. [Alerts and their runbook contract](#alerts-and-their-runbook-contract)
7. [Dashboards as code](#dashboards-as-code)
8. [Metric dependencies the app must satisfy](#metric-dependencies-the-app-must-satisfy)
9. [Distributed tracing — deliberately skipped](#distributed-tracing--deliberately-skipped)
10. [Known gaps and blocked items](#known-gaps-and-blocked-items)
11. [Verification](#verification)

## Why this lives outside the app chart

Installing shared controllers from the application release would couple the app's
deploy/rollback lifecycle to the lifecycle of cluster-wide singletons. A
`helm rollback ticketing` should never risk uninstalling the ALB controller that
every other workload depends on. So the split is: this directory owns anything
cluster-scoped or shared; `helm/ticketing/` owns only namespaced application
objects.

## Install order

Order matters — several add-ons have admission webhooks or CRDs that later ones
depend on. Install top to bottom:

```
┌──────────────────────────────────────────────────────────────────────┐
│  1. cert-manager            webhooks/CRDs many others need             │
│  2. metrics-server          HPA + KEDA need it before any scaling      │
│  3. aws-load-balancer-ctlr  reconciles the Ingress into a real ALB     │
│  4. external-secrets-op     materialises every *secret* below          │
│  5. cluster-autoscaler      adds nodes when KEDA-scaled pods can't fit  │
│  6. keda                    CRDs the ticketing ScaledObject needs       │
│  7. kube-prometheus-stack   Prometheus + Grafana + Alertmanager + KSM   │
│     └─ + alertmanager.values.yaml (same release, -f both files)        │
│  8. prometheus-redis-exporter    queue-depth metrics                    │
│  9. yace-cloudwatch-exporter     RDS metrics                            │
│ 10. aws-for-fluent-bit           logs to CloudWatch Logs                │
│ 11. prometheus-rules.yaml        the four alerts (kubectl apply)        │
│ 12. dashboards ConfigMap         kubectl/kustomize, sidecar imports     │
└──────────────────────────────────────────────────────────────────────┘
        ▲                                            ▲
        │ steps 1-6 are prerequisites for            │ steps 7-12 are the
        │ the ticketing application release          │ observability layer
```

> The `ticketing` application release is installed AFTER step 6 and can go in
> parallel with steps 7-12 — the app does not depend on monitoring being up.

Example for the Prometheus stack (note the two `-f` files on one release):

```bash
helm upgrade --install kube-prometheus-stack \
  prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  -f kube-prometheus-stack.values.yaml \
  -f alertmanager.values.yaml
```

## What each piece is and why it is here

| File | Add-on | Why it exists in a dev cluster |
|---|---|---|
| `cert-manager.values.yaml` | cert-manager | Issues the admission-webhook certs other controllers rely on. No AWS access. |
| `metrics-server.values.yaml` | metrics-server | Feeds the CPU HPA and KEDA's HPA. Without it the web HPA reads `<unknown>/70%` and never scales. |
| `aws-load-balancer-controller.values.yaml` | ALB controller | Turns the ticketing `Ingress` into an actual ALB. Nothing serves traffic without it. |
| `external-secrets-operator.values.yaml` | External Secrets | Syncs the four `ticketing-dev/*` Secrets Manager secrets into Kubernetes. |
| `cluster-autoscaler.values.yaml` | Cluster Autoscaler | Adds an app node when KEDA-scaled worker pods have nowhere to schedule. |
| `keda.values.yaml` | KEDA | Scales the worker Deployment from Redis queue depth. |
| `kube-prometheus-stack.values.yaml` | Prometheus/Grafana/Alertmanager | The metrics, dashboards and alerting core. |
| `alertmanager.values.yaml` | Alertmanager routing | Slack routing + grouping/inhibition, webhook read from a mounted secret. |
| `prometheus-rules.yaml` | PrometheusRule | The only four alerts this environment fires. |
| `prometheus-redis-exporter.values.yaml` | redis_exporter | Publishes `redis_key_size` — queue backlog and failed-job count. |
| `yace-cloudwatch-exporter.values.yaml` | YACE | Publishes RDS CloudWatch metrics, especially connection count. |
| `fluent-bit.values.yaml` | aws-for-fluent-bit | Ships structured Laravel logs to CloudWatch Logs, 7-day retention. |
| `dashboards/*.json` | Grafana dashboards | Queue/jobs, HTTP latency, RDS connections — as committed JSON. |
| `dashboards-configmap.yaml` | ConfigMap glue | Shows how the JSON gets the `grafana_dashboard: "1"` label the sidecar keys on. |

Design choices worth calling out (rationale is in each file's header comments):

- **YACE over the classic CloudWatch exporter** — batched `GetMetricData` (fewer
  paid API calls), tag-based resource discovery that survives a rebuild, and
  native tag decoration on metrics.
- **CloudWatch Logs over Loki** — Loki is better long-term but is another
  stateful system to run and back up; at one environment's log volume CloudWatch
  is fewer moving parts and cheaper. Documented in `fluent-bit.values.yaml`.
- **No persistence on Prometheus or Grafana** — an explicit EBS-cost trade. A
  restart loses metric history; dashboards survive because they are code.

## Templated values from Terraform

Every `REPLACE_ME_*` placeholder is filled at install time from
`terraform -chdir=terraform/dev output`. Nothing here hardcodes an ARN.

| Placeholder | Terraform output |
|---|---|
| `REPLACE_ME_irsa_role_arns_alb_controller` | `irsa_role_arns["alb_controller"]` |
| `REPLACE_ME_irsa_role_arns_external_secrets` | `irsa_role_arns["external_secrets"]` |
| `REPLACE_ME_irsa_role_arns_cluster_autoscaler` | `irsa_role_arns["cluster_autoscaler"]` |
| `REPLACE_ME_irsa_role_arns_fluent_bit` | `irsa_role_arns["fluent_bit"]` |
| `REPLACE_ME_irsa_role_arns_cloudwatch_exporter` | **does not exist yet — see gaps** |
| `REPLACE_ME_vpc_id` | `vpc_id` |
| `REPLACE_ME_redis_primary_endpoint` | `redis_address` |
| `ticketing-dev` (clusterName) | `cluster_name` |

## Secrets that must exist first

Two platform components need a secret in their own namespace before they start.
Both should be materialised by an `ExternalSecret` (the operator from step 4),
never a literal.

**Redis exporter auth** (namespace `monitoring`):

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: ticketing-redis-exporter-auth
  namespace: monitoring
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: ticketing-aws        # a SecretStore in the monitoring namespace
    kind: SecretStore
  target:
    name: ticketing-redis-exporter-auth
  data:
    - secretKey: auth_token
      remoteRef:
        key: ticketing-dev/redis-auth
        property: auth_token
```

**Alertmanager Slack webhook** (namespace `monitoring`, mounted at
`/etc/alertmanager/secrets/alertmanager-slack/webhook-url`): create it the same
way from a Secrets Manager entry holding the webhook URL, or for a quick dev
bring-up:

```bash
kubectl -n monitoring create secret generic alertmanager-slack \
  --from-literal=webhook-url='https://hooks.slack.com/services/XXX/YYY/ZZZ'
```

## Alerts and their runbook contract

`prometheus-rules.yaml` contains **exactly four** alerts. Every one carries a
`severity` and a `runbook_url` deep-linking to an anchor in `docs/runbook.md`.
An alert without a runbook entry is not "done".

| Alert | Fires when | Severity | Runbook anchor |
|---|---|---|---|
| `TicketingQueueBacklogHigh` | `laravel_database_queues:default` > 100 for 5m | warning | `#queue-backlog-high` |
| `TicketingPodCrashLooping` | any pod in `CrashLoopBackOff` ≥ 5m | critical | `#pod-crashloopbackoff` |
| `TicketingRDSConnectionsHigh` | RDS connections > 70% of ~85 for 5m | critical | `#rds-connections-high` |
| `TicketingFailedJobsIncreasing` | failed-job set grows over 15m | warning | `#failed-jobs-increasing` |

> `docs/runbook.md` is owned by the Documentation Engineer and is OUT of this
> engineer's scope. These four anchors are a hard dependency: the Documentation
> Engineer must create `docs/runbook.md` with a section for each anchor above,
> or the `runbook_url` links dead-end. This is flagged as a blocked item.

## Dashboards as code

Three dashboards live in `dashboards/` as committed JSON. They are applied by
the kube-prometheus-stack Grafana **sidecar**, which watches every namespace for
ConfigMaps labelled `grafana_dashboard: "1"` and imports the JSON they hold. A
dashboard that only exists in a browser does not survive `terraform destroy`;
one in a git-committed ConfigMap does. `dashboards-configmap.yaml` shows both the
`kubectl` and `kustomize` ways to produce those ConfigMaps from the JSON files.

| Dashboard | Panels |
|---|---|
| `ticketing-queues-jobs.json` | Redis queue depth per queue, default backlog stat, failed-job count, failed-job 15m rate of change |
| `ticketing-http.json` | p95 latency by route, p95 vs p50, request rate by status class |
| `ticketing-rds.json` | Connection utilisation gauge vs `max_connections`, connections (max/avg) vs ceiling, CPU + freeable memory |

## Metric dependencies the app must satisfy

Some panels and alerts require metrics the platform layer cannot produce on its
own. These are dependencies on the application (owned by another engineer); they
are documented here so the coupling is explicit, not silent.

- **Failed jobs.** `redis_key_size{key="laravel_database_queues:default:failed"}`
  only exists if Laravel stores failed jobs in Redis (the redis failed-job
  driver), so the exporter's `check-keys` can measure the set. If failed jobs go
  to the MySQL `failed_jobs` table instead (Laravel's default), alert 4 and the
  failed-job panels must be re-pointed at a database exporter. Decide the driver
  and keep it consistent with `prometheus-rules.yaml`.
- **HTTP latency.** The `ticketing-http.json` dashboard expects the app to expose
  a Prometheus histogram `http_request_duration_seconds_bucket{route,method}` and
  a counter `http_requests_total{status_class}` (e.g. via a Laravel Prometheus
  middleware behind a `ServiceMonitor`). Without it those panels read "No data".
  ALB access logs cannot supply per-route p95, so this has to come from the app.
- **`max_connections`.** Not a CloudWatch metric. The `85` literal in the alert
  and the dashboard constant is the `db.t4g.micro` default; confirm the real
  value with `SHOW VARIABLES LIKE 'max_connections';` and record it in the
  runbook. Update both places if the DB parameter group changes it.

## Distributed tracing — deliberately skipped

There is no OpenTelemetry, no Tempo/Jaeger, no trace collector in this stack.
This is a considered omission, not an oversight.

**Where it would be inserted.** An OpenTelemetry Collector `Deployment` (or
DaemonSet) in a new `observability`/`opentelemetry` namespace, receiving OTLP
from the Laravel app (the app instrumented with the OpenTelemetry PHP SDK +
auto-instrumentation for PDO, Guzzle and the queue), and exporting to a trace
backend (Grafana Tempo, or AWS X-Ray via the ADOT collector). Grafana would gain
a Tempo datasource and trace-to-logs / trace-to-metrics links so a slow request
in `ticketing-http.json` could jump straight to its span waterfall. The ALB
already injects `X-Amzn-Trace-Id`, which is the natural correlation seed and is
already carried into logs here as `trace_id`.

**What question it would answer.** "This one request was slow / errored — which
hop caused it?" Tracing shows the per-span breakdown across nginx → php-fpm →
MySQL → Redis → outbound mail/webhook, which metrics and logs can only imply.

**Why it is skipped anyway.** Roughly 20 hours of work — app SDK wiring and
auto-instrumentation, the collector deployment and its IRSA (for X-Ray) or Tempo
storage, sampling policy, Grafana datasource + correlation links, and the
ongoing cost of a trace store — for a signal rarely consulted in a
single-environment dev setup. In one environment with one instance of each
service, the queue-depth, latency-by-route, RDS-connection and log signals here
answer nearly every real question. Tracing earns its keep once there are
multiple services, multiple environments, or a latency problem that metrics and
logs cannot localise. Add it then.

## Known gaps and blocked items

| Item | Status | Owner to resolve |
|---|---|---|
| `irsa_role_arns["cloudwatch_exporter"]` for YACE | **Missing from the eks module.** The contract's IRSA map has no CloudWatch-reading key. YACE needs its own role (trust `system:serviceaccount:monitoring:yace`; policy `cloudwatch:GetMetricData/ListMetrics/GetMetricStatistics`, `tag:GetResources`). Placeholder ARN used meanwhile. | Cloud & DevOps Engineer (Terraform) |
| `docs/runbook.md` with the four alert anchors | Not created — outside this engineer's scope. Alert `runbook_url` links depend on it. | Documentation Engineer |
| Redis failed-job driver | Alert 4 assumes Redis-backed failed jobs. Confirm app config. | Application engineer |
| App HTTP histogram + request counter | Required by `ticketing-http.json`. | Application engineer |

## Verification

`helm` (v4.2.3) is installed locally, but these are **upstream charts** not
vendored into this repo, so `helm lint`/`helm template` cannot run without first
`helm repo add`-ing each chart and reaching the network — not done here (no
cluster mutations, and repo pulls were out of scope). What WAS verified locally:
every YAML file parses and every dashboard JSON is valid JSON. See the report /
commit for the exact commands and their real output. No AWS calls were made.
