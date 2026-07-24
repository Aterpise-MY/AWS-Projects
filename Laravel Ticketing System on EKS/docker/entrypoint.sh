#!/usr/bin/env bash
#
# =============================================================================
# Container entrypoint
#
# Runs the Laravel bootstrap caches AFTER the environment is populated (see the
# long comment in the Dockerfile for why they are not baked at build time),
# then hands off to whatever the pod asked for:
#
#   - no arguments               -> supervisord (web pod: nginx + php-fpm)
#   - `php artisan queue:work …` -> exec'd directly (worker pod)
#   - `php artisan schedule:run` -> exec'd directly (scheduler CronJob)
#   - `php artisan migrate …`    -> exec'd directly (migrate Helm hook)
#
# Must work under readOnlyRootFilesystem: true. The ONLY writable paths are the
# emptyDir mounts declared in the Helm chart:
#   /var/www/storage/framework/{cache,sessions,views}
#   /var/www/storage/logs
#   /var/www/bootstrap/cache
#   /tmp  /var/run  /var/lib/nginx
# Nothing below writes anywhere else.
# =============================================================================

set -euo pipefail

# -u would abort on the first unset optional variable; give the ones we read a
# defined default so the guard clauses below are the thing that decides.
: "${SKIP_BOOTSTRAP_CACHE:=0}"
: "${CONTAINER_ROLE:=web}"

log() {
    # Structured so it lands next to the application's JSON log lines in
    # CloudWatch rather than as opaque plain text.
    printf '{"level":"info","source":"entrypoint","role":"%s","message":"%s"}\n' \
        "${CONTAINER_ROLE}" "$1"
}

build_caches() {
    if [ "${SKIP_BOOTSTRAP_CACHE}" = "1" ]; then
        log "SKIP_BOOTSTRAP_CACHE=1, leaving config uncached"
        return
    fi

    # bootstrap/cache is an emptyDir, so a previous pod's cache never persists;
    # clear defensively anyway in case the same emptyDir is reused on restart.
    log "clearing stale caches"
    php artisan config:clear  >/dev/null 2>&1 || true
    php artisan route:clear   >/dev/null 2>&1 || true
    php artisan view:clear    >/dev/null 2>&1 || true

    # NOW the env vars exist (ConfigMap + Secret), so the cache captures the
    # real DB_HOST / REDIS_PASSWORD / AWS_BUCKET instead of build-time nulls.
    log "caching config, routes and views"
    php artisan config:cache
    php artisan route:cache
    php artisan view:cache
}

# The web pod (and only the web pod) serves HTTP, so only it needs the route and
# view caches strictly. The worker and scheduler still benefit from config:cache
# for faster boot, so every role runs the same build — it is cheap and keeps the
# roles from diverging.
build_caches

if [ "$#" -gt 0 ]; then
    # A worker/scheduler/migrate pod passed an explicit command. exec so the
    # PHP process becomes PID 1 and receives SIGTERM directly — pcntl in the
    # image lets `queue:work` drain the in-flight job during terminationGrace.
    log "exec: $*"
    exec "$@"
fi

log "starting supervisord (nginx + php-fpm)"
exec supervisord -c /etc/supervisor/supervisord.conf
