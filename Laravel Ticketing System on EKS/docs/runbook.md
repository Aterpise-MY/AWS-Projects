# Runbook — Meridian Support Co. Ticketing Platform (dev)

Concrete, copy-pasteable operational procedures for the `ticketing-dev`
environment in `ap-southeast-1` (account `022499047467`). Every command here is
real and matches the scripts and charts in this repository. Architecture context
is in [`architecture.md`](./architecture.md); cost context in [`cost.md`](./cost.md).

Common assumptions for every procedure below:

```bash
export AWS_REGION=ap-southeast-1
export CLUSTER=ticketing-dev
export NS=ticketing
export RELEASE=ticketing
aws eks update-kubeconfig --name "$CLUSTER" --region "$AWS_REGION" --alias "$CLUSTER"
```

## Table of Contents

1. [Before first build](#before-first-build)
2. [Deploy](#deploy)
3. [Roll back](#roll-back)
4. [Scale](#scale)
5. [Rotate a database secret](#rotate-a-database-secret)
6. [Restore RDS from a snapshot](#restore-rds-from-a-snapshot)
7. [Verified values](#verified-values)
8. [Alert response — Queue backlog high](#queue-backlog-high)
9. [Alert response — Pod CrashLoopBackOff](#pod-crashloopbackoff)
10. [Alert response — RDS connections high](#rds-connections-high)
11. [Alert response — Failed jobs increasing](#failed-jobs-increasing)

## Before first build

> IMPORTANT — READ THIS BEFORE THE FIRST IMAGE BUILD OR CI RUN.
> `composer.lock` and `package-lock.json` are NOT committed to `app/`. The
> Dockerfile runs `composer install` and `npm ci`, and **`npm ci` hard-fails
> without a lockfile** (it refuses to resolve versions itself, by design). They
> were deliberately not hand-fabricated — a wrong lockfile is worse than none,
> because it silently pins the wrong transitive versions.

Generate both once, on a machine with network access, then commit them:

```bash
cd app

# PHP lockfile — resolves composer.json against Packagist.
composer install            # writes composer.lock
# (or, without installing the vendor tree locally:)
composer update --lock

# JS lockfile — resolves package.json against the npm registry.
npm install                 # writes package-lock.json

git add composer.lock package-lock.json
git commit -m "chore: add committed lockfiles for reproducible image builds"
```

After this, `docker build` and the CI `ci.yml` / `build-deploy.yml` workflows can
run. Until it is done, every image build fails at the `npm ci` step.

## Deploy

Deploys are image-tag driven. The tag is ALWAYS a full 40-character git SHA, never
`latest` (see [architecture.md](./architecture.md#immutable-ecr-tags-and-the-lifecycle-policy)).

**Normal path (CI).** Merging to `main` runs `.github/workflows/build-deploy.yml`,
which builds, pushes `…:<sha>` to ECR, and runs the Helm upgrade.

**Manual path / full rebuild from nothing:**

```bash
# Rebuilds VPC → EKS → data stores → add-ons → app chart, and prints wall time.
scripts/rebuild.sh --image-tag "$(git rev-parse HEAD)"

# Dry run the infra only:
scripts/rebuild.sh --plan-only
```

**Just the application chart** (infra and add-ons already up):

```bash
SHA="$(git rev-parse HEAD)"
ECR_URL="$(terraform -chdir=terraform/dev output -raw ecr_repository_url)"
IRSA_APP="$(terraform -chdir=terraform/dev output -json irsa_role_arns | jq -r '.app')"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

# Confirm the image exists before deploying — rebuild.sh does this for you.
aws ecr describe-images --repository-name "${ECR_URL##*/}" \
  --image-ids "imageTag=${SHA}" --region "$AWS_REGION" >/dev/null \
  || { echo "image not in ECR — build+push first"; exit 1; }

helm upgrade --install "$RELEASE" helm/ticketing \
  --namespace "$NS" --create-namespace \
  --atomic --timeout 10m --wait \
  --set "image.repository=${ECR_URL}" \
  --set "image.tag=${SHA}" \
  --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=${IRSA_APP}" \
  --set "aws.region=${AWS_REGION}" \
  --set "aws.accountId=${ACCOUNT_ID}"
```

`--atomic` is mandatory: if the release (including the `migrate` pre-upgrade hook
Job) fails or times out, Helm automatically rolls the whole release back to the
last good revision, so you never sit in a half-applied state.

**Verify a deploy:**

```bash
scripts/verify-deployment.sh
helm status "$RELEASE" -n "$NS"
kubectl -n "$NS" get pods
```

## Roll back

Because every image is an immutable full-SHA tag, each Helm revision maps to a
distinct, still-pullable image — this is what makes rollback meaningful.

```bash
# See the revision history and which image each shipped.
helm history "$RELEASE" -n "$NS"

# Roll back to the immediately previous revision, atomically. --atomic means if
# the rollback itself fails to become healthy it is itself rolled back, so you
# cannot get stranded on a broken intermediate state.
helm rollback "$RELEASE" -n "$NS" --wait --timeout 10m --atomic

# Roll back to a specific known-good revision number instead:
helm rollback "$RELEASE" 7 -n "$NS" --wait --timeout 10m --atomic
```

> A rollback re-runs the `migrate` pre-upgrade hook against the older chart. If the
> newer release added a forward-only migration, rolling the *schema* back is NOT
> automatic — restore RDS from the pre-deploy snapshot (see below) if the
> application cannot run against the migrated schema. This is why
> `db-maintenance.yml --tags snapshot` is run before any risky change.

**Verify a rollback:** `helm history "$RELEASE" -n "$NS"` shows a new revision
marking the rollback as deployed, and `kubectl -n "$NS" get pods` shows the pods
back on the previous image (`kubectl -n "$NS" get deploy ticketing-web -o jsonpath='{.spec.template.spec.containers[0].image}'`).

## Scale

**Web tier** is HPA-managed (`helm/ticketing/templates/hpa-web.yaml`). To change
the envelope, edit `values.yaml` (`web.hpa.minReplicas` / `maxReplicas`) and
`helm upgrade`. A temporary manual floor:

```bash
kubectl -n "$NS" scale deployment ticketing-web --replicas=3
# HPA will move it back within its min/max at the next evaluation.
```

**Worker tier** is KEDA-managed on Redis queue length
(`scaledobject-worker.yaml`), not CPU. Do not `kubectl scale` it — KEDA owns the
replica count. Change the envelope in `values.yaml`:

```yaml
worker:
  keda:
    minReplicaCount: 0        # scales to zero when the queue is empty
    maxReplicaCount: 6
    listLength: 20            # target backlog per replica
```

Then `helm upgrade`. Verify KEDA is actually driving it:

```bash
kubectl -n "$NS" get scaledobject ticketing-worker
kubectl -n "$NS" get hpa            # KEDA creates the backing HPA
```

**Nodes** scale via Cluster Autoscaler against the Spot app ASG (min 2 / max 4).
No manual action in normal operation; if you need headroom for a load test, raise
`app_max_size` in `terraform/dev` and `terraform apply`.

## Rotate a database secret

Rotation is a day-2 operation owned by Ansible, run through the `rotate` tag of
`ansible/playbooks/db-maintenance.yml`. It changes the RDS master password, writes
it to Secrets Manager, forces External Secrets to re-sync via the **`ticketing-eso`
SecretStore identity**, and asks Kubernetes for a rolling restart of the dependent
Deployments — in that exact order, so the app is never holding a password RDS has
already rejected for longer than the rollout.

```bash
cd ansible

# ALWAYS snapshot first. This is the artefact you want to still exist afterwards.
ansible-playbook playbooks/db-maintenance.yml --tags snapshot

# Rotate. Destructive — requires explicit confirmation.
ansible-playbook playbooks/db-maintenance.yml --tags rotate \
  -e confirm_rotation=true
```

What the `rotate` play does, and why the order is fixed:

1. Reads the current secret so non-credential fields (`host`, `port`, `dbname`,
   `username`) survive — only `password` is replaced in the JSON document.
2. Generates a new password with `/ " @ \` excluded (those break RDS validation
   and ElastiCache AUTH).
3. Sets the new master password on RDS **first** (`apply_immediately: true`). If
   this fails, Secrets Manager still holds the working credential and nothing is
   down.
4. Writes the new credential to Secrets Manager **second**.
5. Forces an immediate External Secrets reconcile by annotating the `ExternalSecret`
   — the reconcile authenticates through the `ticketing-eso` SA's IRSA role (the
   only identity in this namespace allowed to read Secrets Manager; the app SA is
   S3-only), refreshes the Kubernetes Secret, and the play waits for it to report
   `Ready=True` **before** any pod restarts.
6. Triggers a rolling restart of `ticketing-web` and `ticketing-worker` **last**.
   The `scheduler` CronJob is intentionally excluded — it picks up the new secret
   on its next per-minute invocation.

> The new password is never printed. Read it from Secrets Manager if a human needs
> it: `aws secretsmanager get-secret-value --secret-id ticketing-dev/database
> --query SecretString --output text`.

**Verify a rotation:**

```bash
kubectl -n "$NS" get externalsecret ticketing-app \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}{"\n"}'   # True
kubectl -n "$NS" rollout status deploy/ticketing-web
kubectl -n "$NS" rollout status deploy/ticketing-worker
# App health probe checks DB connectivity end to end:
kubectl -n "$NS" exec deploy/ticketing-web -- curl -fsS localhost/health/ready
```

## Restore RDS from a snapshot

RDS is Single-AZ with `skip_final_snapshot = true`, so the only recovery point is a
manual snapshot — which is exactly why `db-maintenance.yml --tags snapshot` is run
before every risky change. Manual snapshots survive instance deletion and are
tagged `AutoDelete=true`.

```bash
DB_ID=ticketing-dev-mysql

# 1. Find the snapshot to restore from.
aws rds describe-db-snapshots --db-instance-identifier "$DB_ID" \
  --snapshot-type manual --region "$AWS_REGION" \
  --query 'sort_by(DBSnapshots,&SnapshotCreateTime)[].[DBSnapshotIdentifier,SnapshotCreateTime,Status]' \
  --output table

# 2. Quiesce the app so nothing writes during the swap.
kubectl -n "$NS" scale deployment --all --replicas=0
kubectl -n "$NS" patch cronjob -l "app.kubernetes.io/instance=${RELEASE}" \
  -p '{"spec":{"suspend":true}}' --type=merge

# 3. Restore the snapshot to a NEW instance (you cannot restore over a live one).
#    Match subnet group, SG, and instance class to the current instance.
SUBNET_GRP=$(aws rds describe-db-instances --db-instance-identifier "$DB_ID" \
  --query 'DBInstances[0].DBSubnetGroup.DBSubnetGroupName' --output text)
SG_ID=$(aws rds describe-db-instances --db-instance-identifier "$DB_ID" \
  --query 'DBInstances[0].VpcSecurityGroups[0].VpcSecurityGroupId' --output text)

aws rds restore-db-instance-from-db-snapshot \
  --db-instance-identifier "${DB_ID}-restore" \
  --db-snapshot-identifier <SNAPSHOT_ID> \
  --db-subnet-group-name "$SUBNET_GRP" \
  --vpc-security-group-ids "$SG_ID" \
  --db-instance-class db.t4g.micro --no-multi-az --no-publicly-accessible \
  --region "$AWS_REGION"
aws rds wait db-instance-available --db-instance-identifier "${DB_ID}-restore"

# 4. Point the app at the restored endpoint. Update host in Secrets Manager:
NEW_HOST=$(aws rds describe-db-instances --db-instance-identifier "${DB_ID}-restore" \
  --query 'DBInstances[0].Endpoint.Address' --output text)
CUR=$(aws secretsmanager get-secret-value --secret-id ticketing-dev/database \
  --query SecretString --output text)
echo "$CUR" | jq --arg h "$NEW_HOST" '.host=$h' \
  | xargs -0 -I{} aws secretsmanager put-secret-value \
      --secret-id ticketing-dev/database --secret-string {}

# 5. Re-sync External Secrets and bring the app back.
kubectl -n "$NS" annotate externalsecret ticketing-app force-sync="$(date -u +%s)" --overwrite
kubectl -n "$NS" patch cronjob -l "app.kubernetes.io/instance=${RELEASE}" \
  -p '{"spec":{"suspend":false}}' --type=merge
helm upgrade "$RELEASE" helm/ticketing -n "$NS" --reuse-values --wait
```

> The cleaner alternative for a full environment rebuild is to let Terraform own the
> instance: restore the snapshot into a new instance, then `terraform import` it, or
> set the module's `snapshot_identifier` and `terraform apply`. The console/CLI path
> above is the fast recovery; reconcile Terraform state afterwards so the restored
> instance is not orphaned from IaC.

**Verify a restore:** `aws rds describe-db-instances --db-instance-identifier
${DB_ID}-restore --query 'DBInstances[0].DBInstanceStatus'` returns `available`,
and `curl localhost/health/ready` from a web pod passes (it checks DB + Redis).

## Verified values

These are the numbers an operator needs and their verification status. Values
marked MEASURE are recorded on the first real `terraform apply`; the placeholders
are the formula-derived expectations.

| Value | Expected | How to confirm live | Status |
|---|---|---|---|
| RDS `max_connections` | `~85` on `db.t4g.micro` — formula `DBInstanceClassMemory/12582880` (~1 GiB RAM ÷ 12582880) | `mysql -h <host> -u ticketing_admin -p -e "SHOW VARIABLES LIKE 'max_connections';"` (run from the bastion) | MEASURE on first apply and record here; update the `85` literal in `prometheus-rules.yaml` if the parameter group changes it |
| Redis queue key (KEDA `listName`) | `laravel_database_queues:default` | `redis-cli -h <primary> --tls -a <auth> KEYS "*queues*"` from a debug pod | CONFIRMED templated from `redis.prefix` + `queues:` + `redis.queue`, not hardcoded. Verify live; if the live key disagrees with the rendered value, the chart is wrong, not Redis |
| Connection budget | 20 of ~85 (~24%) at baseline; 40 (~47%) at HPA max | `10` fpm children (`pm.max_children`) × `2` web pods = `20`; × `4` pods at HPA max = `40`. Stays under 50% of ~85 | CONFIRMED by arithmetic; re-check after any `pm.max_children` or HPA `maxReplicas` change |
| Rebuild time | `< 30 min` target | `scripts/rebuild.sh` prints total wall time at the end | MEASURE on first real apply and record here |

Connection-budget arithmetic, expanded:

```
  fpm children per web pod : pm.max_children      = 10
  web pods at baseline     : web.hpa.minReplicas  =  2   → 10 × 2 = 20 connections (~24% of 85)
  web pods at HPA ceiling  : web.hpa.maxReplicas  =  4   → 10 × 4 = 40 connections (~47% of 85)
  worker + scheduler add a handful more; the alert fires at 70% (~60), leaving headroom.
```

## Queue backlog high

**Alert:** `TicketingQueueBacklogHigh` — `redis_key_size{key="laravel_database_queues:default"} > 100` for 5m (severity `warning`).

**Means:** the default queue (notifications, mail, escalation emails) has more than
100 pending jobs for over five minutes. Workers are not draining it fast enough.
KEDA should already be scaling workers up; if this fired, KEDA is not winning.

**Respond:**

1. Confirm the real depth and that KEDA sees it:
   ```bash
   kubectl -n "$NS" get scaledobject ticketing-worker
   kubectl -n "$NS" get hpa | grep worker      # current/target replicas
   kubectl -n "$NS" get pods -l app.kubernetes.io/component=worker
   ```
2. If workers are NOT scaling up, the usual cause is the KEDA trigger reading the
   wrong key/DB and silently seeing zero. Verify the live key matches the rendered
   `listName` (see [Verified values](#verified-values)):
   ```bash
   kubectl -n "$NS" get scaledobject ticketing-worker -o jsonpath='{.spec.triggers[0].metadata.listName}{"\n"}'
   # then from a debug pod:  redis-cli --tls -a <auth> -n 2 LLEN laravel_database_queues:default
   ```
   A mismatch means the chart is wrong — fix `redis.prefix`/`redis.queue` and
   `helm upgrade`.
3. If workers ARE scaling but not keeping up: check for a poison job holding a
   worker, and check whether Spot reclaim killed workers:
   ```bash
   kubectl -n "$NS" logs -l app.kubernetes.io/component=worker --tail=100
   kubectl get events -A --field-selector reason=SpotInterruption
   ```
4. Temporary relief — raise the worker ceiling and, if nodes are the constraint,
   the app ASG max:
   ```bash
   helm upgrade "$RELEASE" helm/ticketing -n "$NS" --reuse-values \
     --set worker.keda.maxReplicaCount=8
   ```

**Resolved when:** `redis_key_size{key="laravel_database_queues:default"}` is back
under 100 and the alert clears (≤ 5m). Confirm with the `LLEN` above and
`kubectl -n "$NS" get hpa`.

## Pod CrashLoopBackOff

**Alert:** `TicketingPodCrashLooping` — any container in the namespace in
`CrashLoopBackOff` (`kube_pod_container_status_waiting_reason{reason="CrashLoopBackOff"}`)
for 5m (severity `critical`).

**Means:** a `web`, `worker`, `scheduler`, or `migrate` container has been
restarting in a loop for at least five minutes — long enough that it is not a
single transient rollout restart.

**Respond:**

1. Find the offending pod and why it is waiting:
   ```bash
   kubectl -n "$NS" get pods
   kubectl -n "$NS" describe pod <pod>          # Events + last state
   kubectl -n "$NS" logs <pod> --previous       # the crash, not the restart
   ```
2. Triage by the most common causes on this platform:
   - **Missing writable mount → read-only-rootfs crash.** The containers run
     `readOnlyRootFilesystem: true`; every path in the `emptyDir` list (e.g.
     `/var/www/storage/framework/{cache,sessions,views}`, `/var/www/storage/logs`,
     `/var/www/bootstrap/cache`, `/tmp`, `/var/run`, `/var/lib/nginx`) MUST be
     mounted. A dropped mount crash-loops immediately. Check the Deployment's
     `volumeMounts` against `values.yaml`.
   - **Secret not present → boot fails.** If the secret chain did not run,
     `APP_KEY`/DB/Redis env is missing. Check the `ExternalSecret` is `Ready` and
     the Kubernetes Secret exists:
     ```bash
     kubectl -n "$NS" get externalsecret,secret
     ```
   - **DB/Redis unreachable → readiness never passes.** Check
     `curl localhost/health/ready` output in the logs; cross-reference the
     [RDS connections](#rds-connections-high) alert.
3. If it is a bad image/config from the last deploy, roll back — see
   [Roll back](#roll-back).

**Resolved when:** the pod is `Running` and `Ready`, restart count stops climbing,
and the alert clears:
```bash
kubectl -n "$NS" get pods -o wide
kubectl -n "$NS" get pod <pod> -o jsonpath='{.status.containerStatuses[0].restartCount}{"\n"}'
```

## RDS connections high

**Alert:** `TicketingRDSConnectionsHigh` — `aws_rds_database_connections_maximum > (85 * 0.70)`
(i.e. ~60) for 5m (severity `critical`). The `85` is the measured/derived
`max_connections`; it is a literal because `max_connections` is not itself a
CloudWatch metric.

**Means:** the instance is using over 70% of its connection ceiling. On
`db.t4g.micro` this catches a real failure — a connection leak or unbounded worker
fan-out — long before CPU or memory look unhealthy, and well before users hit
"too many connections" errors.

**Respond:**

1. See who is connected right now (from the bastion, which has the network path):
   ```bash
   mysql -h <rds-host> -u ticketing_admin -p \
     -e "SHOW STATUS LIKE 'Threads_connected';
         SELECT COUNT(*) c, user, host, db FROM information_schema.processlist
         GROUP BY user, host, db ORDER BY c DESC;"
   ```
2. Compare against the budget: baseline should be ~20, HPA-max ~40 (see
   [Verified values](#verified-values)). If it is far above 40, something is
   scaling or leaking:
   ```bash
   kubectl -n "$NS" get hpa                       # web pods beyond max?
   kubectl -n "$NS" get scaledobject ticketing-worker   # workers runaway?
   ```
3. If a worker fan-out is the cause, cap it:
   ```bash
   helm upgrade "$RELEASE" helm/ticketing -n "$NS" --reuse-values \
     --set worker.keda.maxReplicaCount=4
   ```
4. If it is a genuine leak in a bad build, roll back ([Roll back](#roll-back)).
   Do NOT reflexively raise `max_connections` on a `db.t4g.micro` — its ~1 GiB RAM
   is the real limit and more connections will OOM the instance.

**Resolved when:** `aws_rds_database_connections_maximum` is back below ~60 and the
alert clears. Confirm with `SHOW STATUS LIKE 'Threads_connected';` and the RDS
dashboard.

> First-apply task: run `SHOW VARIABLES LIKE 'max_connections';` and record the
> real value in [Verified values](#verified-values). If it is not ~85, update the
> `85` literal in `helm/platform/prometheus-rules.yaml` so the 70% threshold stays
> correct.

## Failed jobs increasing

**Alert:** `TicketingFailedJobsIncreasing` —
`increase(redis_key_size{key="laravel_database_queues:default:failed"}[15m]) > 0`
for 15m (severity `warning`). It alerts on the INCREASE, not the absolute count, so
old historical failures do not keep it stuck on.

**Means:** jobs are landing in the failed set faster than anyone is clearing them —
a bad deploy, a downstream outage (SMTP relay), or a data bug.

**Respond:**

1. Look at what is failing and why:
   ```bash
   kubectl -n "$NS" exec deploy/ticketing-worker -- php artisan queue:failed
   kubectl -n "$NS" logs -l app.kubernetes.io/component=worker --tail=200 | grep -i fail
   ```
   `SendTicketNotification` retries 3 times with `[10, 60, 300]s` backoff before it
   lands in the failed set, so a job here has already exhausted its retries.
2. Identify the common cause:
   - **SMTP down** → every notification fails. Check the relay and the
     `ticketing-dev/smtp` secret. Fix upstream, then retry (step 3).
   - **Bad deploy** → failures start exactly at a rollout. Roll back
     ([Roll back](#roll-back)).
   - **Data bug** (one poison payload) → the same job id repeats; inspect and
     `forget` it rather than retrying.
3. After the root cause is fixed, replay the failed jobs:
   ```bash
   kubectl -n "$NS" exec deploy/ticketing-worker -- php artisan queue:retry all
   # or a single one:
   kubectl -n "$NS" exec deploy/ticketing-worker -- php artisan queue:retry <uuid>
   # abandon a poison job:
   kubectl -n "$NS" exec deploy/ticketing-worker -- php artisan queue:forget <uuid>
   ```

> Metric provenance note: this alert requires the failed set to live in Redis
> (key `laravel_database_queues:default:failed`) so the redis-exporter's
> `check-keys` can see it. If failed jobs are configured to the MySQL `failed_jobs`
> table instead, the expression must be re-pointed at a database exporter — see the
> project `README.md` "Failed jobs" note. Do not silence the alert; fix the source.

**Resolved when:** `increase(redis_key_size{key="laravel_database_queues:default:failed"}[15m])`
returns to 0 (no new failures for 15m) and the failed list is drained
(`php artisan queue:failed` shows nothing outstanding).
