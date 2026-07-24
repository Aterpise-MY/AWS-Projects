#!/usr/bin/env bash
#
# verify-deployment.sh — post-deploy smoke test.
#
# Five checks, in the order a failure is most likely to occur:
#   1. every pod in the release is Ready
#   2. the `migrate` pre-install/pre-upgrade hook Job reports succeeded
#   3. GET /up returns 200 through the ALB
#   4. a ticket row can be created and is then readable straight from MySQL
#   5. a job pushed onto the Redis queue is consumed by a worker within 30s
#
# Checks 4 and 5 are the ones that matter: 1-3 pass on a deployment whose
# database credentials are wrong and whose worker has silently crash-looped.
#
# Every check runs even if an earlier one fails, so a single run tells you
# everything that is broken. Exit code is non-zero if any check failed.
#
# PHP snippets are piped to `php` on stdin rather than run through
# `artisan tinker`: tinker is a require-dev package and is not present in the
# production image built with `composer install --no-dev`.
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

QUEUE_TIMEOUT=30
POD_TIMEOUT=300
BASE_URL=""
TICKETS_TABLE="tickets"

usage() {
  cat <<'EOF'
Usage: scripts/verify-deployment.sh [options]

Post-deploy smoke test for the ticketing release. Exits non-zero if any check
fails, printing every failure rather than stopping at the first.

Options:
  --namespace <ns>      Kubernetes namespace (default: ticketing)
  --release <name>      Helm release name (default: ticketing)
  --base-url <url>      Override the HTTP base URL
                        (default: the Ingress ALB hostname)
  --queue-timeout <s>   Seconds to wait for a queued job (default: 30)
  --pod-timeout <s>     Seconds to wait for pods to be Ready (default: 300)
  --table <name>        Tickets table name (default: tickets)
  -h, --help            Show this help and exit
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace)     K8S_NAMESPACE="$2"; shift 2 ;;
    --release)       HELM_RELEASE="$2"; shift 2 ;;
    --base-url)      BASE_URL="$2"; shift 2 ;;
    --queue-timeout) QUEUE_TIMEOUT="$2"; shift 2 ;;
    --pod-timeout)   POD_TIMEOUT="$2"; shift 2 ;;
    --table)         TICKETS_TABLE="$2"; shift 2 ;;
    -h|--help)       usage; exit 0 ;;
    *)               usage >&2; die "unknown argument: $1" ;;
  esac
done

SELECTOR="app.kubernetes.io/instance=${HELM_RELEASE}"
FAILURES=0
fail() { log_error "$*"; FAILURES=$(( FAILURES + 1 )); }

# Run a PHP snippet (read from this function's stdin) inside the web pod.
php_in_pod() { kubectl -n "$K8S_NAMESPACE" exec -i "$WEB_POD" -- php; }

log_section "Verifying release ${HELM_RELEASE} in namespace ${K8S_NAMESPACE}"

# ---------------------------------------------------------------------------
# 1. Pods Ready
# ---------------------------------------------------------------------------
log_info "[1/5] waiting for all pods to be Ready (timeout ${POD_TIMEOUT}s)"
if kubectl -n "$K8S_NAMESPACE" wait --for=condition=Ready pod \
     -l "$SELECTOR" --timeout="${POD_TIMEOUT}s" >/dev/null 2>&1; then
  READY_COUNT="$(kubectl -n "$K8S_NAMESPACE" get pods -l "$SELECTOR" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  log_ok "[1/5] ${READY_COUNT} pod(s) Ready"
else
  kubectl -n "$K8S_NAMESPACE" get pods -l "$SELECTOR" -o wide || true
  fail "[1/5] not all pods reached Ready within ${POD_TIMEOUT}s"
fi

# ---------------------------------------------------------------------------
# 2. Migration Job succeeded
# ---------------------------------------------------------------------------
log_info "[2/5] checking the migrate hook Job"
MIGRATE_JOB="$(kubectl -n "$K8S_NAMESPACE" get jobs \
  -l "app.kubernetes.io/component=migrate" \
  -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null || true)"
if [[ -z "$MIGRATE_JOB" ]]; then
  fail "[2/5] no Job labelled app.kubernetes.io/component=migrate found — did the pre-install hook run?"
else
  SUCCEEDED="$(kubectl -n "$K8S_NAMESPACE" get job "$MIGRATE_JOB" -o jsonpath='{.status.succeeded}' 2>/dev/null || echo 0)"
  if [[ "${SUCCEEDED:-0}" -ge 1 ]]; then
    log_ok "[2/5] Job ${MIGRATE_JOB} succeeded"
  else
    kubectl -n "$K8S_NAMESPACE" logs "job/${MIGRATE_JOB}" --tail=40 2>/dev/null || true
    fail "[2/5] Job ${MIGRATE_JOB} has not succeeded (status.succeeded=${SUCCEEDED:-0})"
  fi
fi

# ---------------------------------------------------------------------------
# 3. HTTP /up
# ---------------------------------------------------------------------------
log_info "[3/5] checking HTTP health endpoints"
if [[ -z "$BASE_URL" ]]; then
  ALB_HOST="$(kubectl -n "$K8S_NAMESPACE" get ingress -l "$SELECTOR" \
    -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  [[ -n "$ALB_HOST" ]] && BASE_URL="http://${ALB_HOST}"
fi
if [[ -z "$BASE_URL" ]]; then
  fail "[3/5] the Ingress has no load balancer hostname yet — is the AWS Load Balancer Controller running?"
else
  for path in /up /health/ready; do
    CODE="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 --retry 5 --retry-delay 5 \
      --retry-all-errors "${BASE_URL}${path}" 2>/dev/null || echo 000)"
    if [[ "$CODE" == "200" ]]; then
      log_ok "[3/5] GET ${BASE_URL}${path} -> 200"
    else
      fail "[3/5] GET ${BASE_URL}${path} -> ${CODE} (expected 200)"
    fi
  done
fi

# ---------------------------------------------------------------------------
# 4 + 5 both need a running web pod to exec into.
# ---------------------------------------------------------------------------
WEB_POD="$(kubectl -n "$K8S_NAMESPACE" get pods \
  -l "${SELECTOR},app.kubernetes.io/component=web" \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"

if [[ -z "$WEB_POD" ]]; then
  fail "[4/5] no Running web pod to exec into — skipping the database check"
  fail "[5/5] no Running web pod to exec into — skipping the queue check"
else
  TOKEN="verify-$(date +%s)-$$"

  # -------------------------------------------------------------------------
  # 4. Create a ticket, then read it back with a raw query builder call so the
  #    assertion goes to MySQL and not to an Eloquent identity map or the cache.
  # -------------------------------------------------------------------------
  log_info "[4/5] creating a ticket and reading it back from MySQL (pod ${WEB_POD})"
  set +e
  DB_RESULT="$(php_in_pod <<PHP 2>&1
<?php
require '/var/www/vendor/autoload.php';
\$app = require '/var/www/bootstrap/app.php';
\$app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();
try {
    \$ticket = \App\Models\Ticket::factory()->create();
    \$found  = Illuminate\Support\Facades\DB::table('${TICKETS_TABLE}')->where('id', \$ticket->id)->count();
    Illuminate\Support\Facades\DB::table('${TICKETS_TABLE}')->where('id', \$ticket->id)->delete();
    echo (\$found === 1) ? 'PASS id=' . \$ticket->id : 'FAIL rows=' . \$found;
} catch (Throwable \$e) {
    echo 'FAIL ' . get_class(\$e) . ': ' . \$e->getMessage();
}
PHP
)"
  set -e
  if [[ "$DB_RESULT" == PASS* ]]; then
    log_ok "[4/5] ticket round-tripped through the database (${DB_RESULT})"
  else
    fail "[4/5] ticket create/read failed: ${DB_RESULT}"
  fi

  # -------------------------------------------------------------------------
  # 5. Push a queued closure onto the default Redis queue and wait for a worker
  #    to consume it. The worker signals completion by writing a cache key, so
  #    this proves the whole path: Redis DB 2 (queue) -> worker -> Redis DB 0
  #    (cache). Polling the queue length instead would pass even if the worker
  #    were dead and something else had trimmed the list.
  # -------------------------------------------------------------------------
  log_info "[5/5] dispatching a queued job (must be consumed within ${QUEUE_TIMEOUT}s)"
  set +e
  DISPATCH_RESULT="$(php_in_pod <<PHP 2>&1
<?php
require '/var/www/vendor/autoload.php';
\$app = require '/var/www/bootstrap/app.php';
\$app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();
try {
    \$key = '${TOKEN}';
    dispatch(function () use (\$key) {
        Illuminate\Support\Facades\Cache::put(\$key, 'consumed', 300);
    });
    echo 'QUEUED';
} catch (Throwable \$e) {
    echo 'FAIL ' . get_class(\$e) . ': ' . \$e->getMessage();
}
PHP
)"
  set -e
  if [[ "$DISPATCH_RESULT" != "QUEUED" ]]; then
    fail "[5/5] could not dispatch the job: ${DISPATCH_RESULT}"
  else
    QUEUE_DEADLINE=$(( SECONDS + QUEUE_TIMEOUT ))
    CONSUMED=0
    while (( SECONDS < QUEUE_DEADLINE )); do
      set +e
      STATE="$(php_in_pod <<PHP 2>&1
<?php
require '/var/www/vendor/autoload.php';
\$app = require '/var/www/bootstrap/app.php';
\$app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();
echo Illuminate\Support\Facades\Cache::get('${TOKEN}', 'pending');
PHP
)"
      set -e
      if [[ "$STATE" == "consumed" ]]; then CONSUMED=1; break; fi
      sleep 3
    done
    if (( CONSUMED )); then
      log_ok "[5/5] queued job consumed by a worker within ${QUEUE_TIMEOUT}s"
    else
      kubectl -n "$K8S_NAMESPACE" logs -l "${SELECTOR},app.kubernetes.io/component=worker" --tail=30 2>/dev/null || true
      fail "[5/5] queued job was NOT consumed within ${QUEUE_TIMEOUT}s — check the worker Deployment and REDIS_QUEUE_DB"
    fi
  fi
fi

# ---------------------------------------------------------------------------
log_section "Result"
if (( FAILURES == 0 )); then
  log_ok "all 5 checks passed"
  exit 0
fi
log_error "${FAILURES} check(s) failed"
exit 1
