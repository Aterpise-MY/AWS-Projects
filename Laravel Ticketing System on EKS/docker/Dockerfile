# syntax=docker/dockerfile:1.7
#
# =============================================================================
# Ticketing platform runtime image
#
# Build context is the `app/` directory; this file lives in `docker/`, so:
#   docker buildx build --platform linux/arm64 -f docker/Dockerfile app
#
# arm64 ONLY. Every node group in the contract is Graviton (t4g.small /
# t4g.medium), so an amd64 layer would never be schedulable. Building a
# multi-arch manifest would double build time and ECR storage for an image
# nothing can pull.
# =============================================================================


# -----------------------------------------------------------------------------
# Stage 1 — vendor: PHP dependencies
#
# Only composer.json and composer.lock are copied before `composer install`.
# That is the whole point of this stage: the dependency layer's cache key is
# those two files and nothing else, so editing a controller does not re-resolve
# and re-download 60 packages. The application source arrives afterwards, and
# only the autoloader is regenerated.
# -----------------------------------------------------------------------------
FROM --platform=linux/arm64 composer:2.8 AS vendor

WORKDIR /app

# composer.lock MUST be committed. `composer install` refuses to run without it,
# which is deliberate: an image built from an unpinned composer.json is not
# reproducible, and a patch release of a dependency could differ between the
# image CI tested and the image that reaches the cluster.
COPY composer.json composer.lock ./

# --no-scripts: post-autoload-dump runs `artisan package:discover`, which needs
#   the application source that has not been copied yet.
# --no-autoloader: the optimized classmap is built below, after the source lands.
# BuildKit cache mount keeps composer's download cache across builds without
# baking it into a layer.
RUN --mount=type=cache,target=/tmp/composer-cache,sharing=locked \
    COMPOSER_CACHE_DIR=/tmp/composer-cache \
    composer install \
        --no-dev \
        --no-interaction \
        --no-progress \
        --prefer-dist \
        --no-scripts \
        --no-autoloader

# Source changes invalidate from here down, not from `composer install`.
COPY . .

# classmap-authoritative removes the PSR-4 filesystem probe from every class
# load. Safe because nothing in this application generates classes at runtime.
RUN composer dump-autoload \
        --no-dev \
        --optimize \
        --classmap-authoritative \
    && composer check-platform-reqs --no-dev


# -----------------------------------------------------------------------------
# Stage 2 — assets: compiled CSS/JS
#
# Same caching discipline: package.json + package-lock.json first, `npm ci`,
# then the source. A Blade-only change never re-installs node_modules, and
# node_modules never reaches the runtime image at all.
# -----------------------------------------------------------------------------
FROM --platform=linux/arm64 node:20-alpine AS assets

WORKDIR /app

# `npm ci` (not `npm install`) — it installs exactly the lock file and fails if
# package.json and the lock have drifted, instead of silently updating.
COPY package.json package-lock.json ./

RUN --mount=type=cache,target=/root/.npm,sharing=locked \
    npm ci --no-audit --no-fund

# Vite needs the Blade templates for the Tailwind content scan and the entry
# points under resources/.
COPY vite.config.js tailwind.config.js postcss.config.js ./
COPY resources ./resources

RUN npm run build


# -----------------------------------------------------------------------------
# Stage 3 — runtime: php-fpm + nginx + supervisor
# -----------------------------------------------------------------------------
FROM --platform=linux/arm64 php:8.3-fpm-alpine3.20 AS runtime

# hadolint ignore=DL3018
# apk versions are deliberately unpinned. Alpine's repository only keeps the
# current version of each package for a given release branch, so pinning
# `nginx=1.26.2-r0` breaks the build the day Alpine publishes -r1. The Alpine
# minor version in the FROM tag (3.20) is the pin that matters.
RUN set -eux; \
    apk add --no-cache \
        bash \
        nginx \
        supervisor \
        tzdata \
        icu-libs \
        libpng \
        libjpeg-turbo \
        freetype \
    ; \
    # Build toolchain lives in a virtual package so it can be removed in the
    # same layer — otherwise gcc and friends stay in the image forever.
    apk add --no-cache --virtual .build-deps \
        $PHPIZE_DEPS \
        icu-dev \
        libpng-dev \
        libjpeg-turbo-dev \
        freetype-dev \
        linux-headers \
    ; \
    docker-php-ext-configure gd --with-freetype --with-jpeg; \
    docker-php-ext-install -j"$(nproc)" \
        pdo_mysql \
        opcache \
        bcmath \
        pcntl \
        intl \
        gd \
    ; \
    # phpredis, not predis: the extension is C, so serialization and the TLS
    # handshake to ElastiCache cost a fraction of the userland client. The
    # worker opens a Redis connection on every BLPOP cycle, so this is not
    # micro-optimisation.
    pecl install redis-6.1.0; \
    docker-php-ext-enable redis; \
    # pcntl is required by `queue:work` for SIGTERM handling. Without it the
    # worker cannot finish the in-flight job during the pod's grace period and
    # every rollout risks a half-processed notification.
    apk del --no-network .build-deps; \
    rm -rf /tmp/pear /usr/local/lib/php/doc

# Non-root, UID/GID 1000.
#
# The pod sets runAsNonRoot: true, runAsUser: 1000 and fsGroup: 1000. UID 1000
# is chosen rather than the image's built-in www-data (UID 82) so that the
# emptyDir volumes — which Kubernetes chgrp's to fsGroup — line up with the
# process identity. A mismatch shows up as nginx failing to create its temp
# directories, which reads like a config error but is a permissions one.
RUN set -eux; \
    addgroup -g 1000 -S app; \
    adduser -u 1000 -S -G app -h /var/www -s /sbin/nologin app

COPY docker/php/php.ini /usr/local/etc/php/conf.d/zz-app.ini
COPY docker/php/opcache.ini /usr/local/etc/php/conf.d/zz-opcache.ini
COPY docker/php/fpm-pool.conf /usr/local/etc/php-fpm.d/zz-www.conf
COPY docker/nginx/default.conf /etc/nginx/http.d/default.conf
COPY docker/supervisor/supervisord.conf /etc/supervisor/supervisord.conf
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh

RUN set -eux; \
    # The stock pool config would otherwise be merged with ours and re-declare
    # [www] with pm = dynamic.
    rm -f /usr/local/etc/php-fpm.d/www.conf.default /usr/local/etc/php-fpm.d/www.conf; \
    chmod +x /usr/local/bin/entrypoint.sh; \
    # Directories that must exist before the read-only root filesystem and the
    # emptyDir mounts take effect. The mounts land on top of these paths; the
    # ownership here is what a plain `docker run` (no Kubernetes) needs.
    mkdir -p \
        /var/www/storage/framework/cache/data \
        /var/www/storage/framework/sessions \
        /var/www/storage/framework/views \
        /var/www/storage/logs \
        /var/www/bootstrap/cache \
        /var/lib/nginx/tmp \
        /var/run \
    ; \
    chown -R app:app /var/www /var/lib/nginx /var/run

WORKDIR /var/www

# --chown on COPY, not a later `chown -R`: a recursive chown on ~15k vendor
# files creates a second full-size layer.
COPY --chown=app:app --from=vendor /app /var/www
COPY --chown=app:app --from=assets /app/public/build /var/www/public/build

# =============================================================================
# WHY `php artisan config:cache` IS NOT RUN HERE
#
# This is the single most common way to build a broken Laravel container.
#
# `config:cache` evaluates every config/*.php file once and writes the resulting
# array to bootstrap/cache/config.php. Those files are full of env() calls:
# DB_HOST, REDIS_PASSWORD, AWS_BUCKET, APP_KEY. At BUILD time none of those
# variables exist — they come from the ConfigMap and from the Kubernetes Secret
# that External Secrets materialises out of AWS Secrets Manager, both of which
# only exist at POD START.
#
# So the build would happily write a cache full of nulls and empty strings. And
# because Laravel short-circuits env() once a config cache is present — env()
# returns null outside of config files by design — the correct values injected
# at runtime would be IGNORED. The symptom is a container that starts cleanly
# and then fails every database connection with "Access denied for user ''@'...'",
# pointing at credentials that are demonstrably correct in the Secret.
#
# Worse, baking secrets into the image would put the RDS password and the Redis
# AUTH token in an ECR layer, readable by anyone with pull access.
#
# The cache is therefore built in docker/entrypoint.sh, after the environment
# is populated, into bootstrap/cache — which is an emptyDir, hence writable
# despite readOnlyRootFilesystem: true.
#
# The cost is ~150 ms of startup per pod, which the startup probe absorbs.
# =============================================================================

USER 1000:1000

EXPOSE 8080

# Liveness from Docker's point of view. Kubernetes ignores HEALTHCHECK and uses
# the probes in the Deployment instead, but this keeps `docker run` and any
# local compose workflow honest.
#
# /up is Laravel's built-in liveness route. Deliberately NOT /health/ready:
# that endpoint checks RDS and ElastiCache, neither of which exists when
# somebody runs this image locally.
HEALTHCHECK --interval=30s --timeout=3s --start-period=20s --retries=3 \
    CMD wget --quiet --tries=1 --spider http://127.0.0.1:8080/up || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

# No CMD. entrypoint.sh execs supervisord when it receives no arguments, and
# execs the arguments instead when the worker or scheduler pod passes
# `php artisan queue:work` / `php artisan schedule:run`.
