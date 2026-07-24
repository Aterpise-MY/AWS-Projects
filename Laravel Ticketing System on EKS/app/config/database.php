<?php

declare(strict_types=1);

use Illuminate\Support\Str;

return [

    'default' => env('DB_CONNECTION', 'mysql'),

    'connections' => [

        // Used by `php artisan test` locally and in CI, where no RDS instance
        // exists. Never used in the cluster.
        'sqlite' => [
            'driver' => 'sqlite',
            'url' => env('DB_URL'),
            'database' => env('DB_DATABASE', database_path('database.sqlite')),
            'prefix' => '',
            'foreign_key_constraints' => env('DB_FOREIGN_KEYS', true),
        ],

        'mysql' => [
            'driver' => 'mysql',
            'url' => env('DB_URL'),
            'host' => env('DB_HOST', '127.0.0.1'),
            'port' => env('DB_PORT', '3306'),
            'database' => env('DB_DATABASE', 'ticketing'),
            'username' => env('DB_USERNAME', 'ticketing_admin'),
            'password' => env('DB_PASSWORD', ''),
            'unix_socket' => env('DB_SOCKET', ''),
            'charset' => env('DB_CHARSET', 'utf8mb4'),
            'collation' => env('DB_COLLATION', 'utf8mb4_unicode_ci'),
            'prefix' => '',
            'prefix_indexes' => true,
            'strict' => true,
            'engine' => 'InnoDB',

            // Persistent connections are deliberately OFF.
            //
            // db.t4g.micro's default max_connections is small (the engine
            // formula gives roughly 85 on 1 GiB). php-fpm runs
            // pm = ondemand with pm.max_children = 10, so two web pods can
            // hold at most 20 sockets, plus workers and the scheduler.
            // PDO::ATTR_PERSISTENT would pin one connection per fpm child for
            // the child's whole life and blow that budget the moment the
            // Cluster Autoscaler adds a node.
            'options' => extension_loaded('pdo_mysql') ? array_filter([
                PDO::MYSQL_ATTR_SSL_CA => env('MYSQL_ATTR_SSL_CA'),
                PDO::ATTR_PERSISTENT => false,
                // Fail fast rather than letting a request hang for the default
                // OS timeout when RDS is unreachable — the readiness probe
                // needs an answer inside its own timeout.
                PDO::ATTR_TIMEOUT => 5,
            ]) : [],
        ],

    ],

    'migrations' => [
        'table' => 'migrations',
        'update_date_on_publish' => true,
    ],

    /*
    |--------------------------------------------------------------------------
    | Redis — one ElastiCache node, three logical databases
    |--------------------------------------------------------------------------
    |
    | Contract-mandated index assignment:
    |
    |   ┌───────┬──────────┬──────────────────────────────────────────────┐
    |   │ Index │ Role     │ Consumer                                     │
    |   ├───────┼──────────┼──────────────────────────────────────────────┤
    |   │   0   │ Cache    │ config/cache.php, schedule withoutOverlapping│
    |   │   1   │ Sessions │ config/session.php                           │
    |   │   2   │ Queue    │ config/queue.php, worker Deployment, KEDA    │
    |   └───────┴──────────┴──────────────────────────────────────────────┘
    |
    | Splitting by index is what makes `php artisan cache:clear` safe: it issues
    | FLUSHDB against index 0 only, so it cannot log every user out or drop
    | queued notifications on the floor.
    |
    | transit_encryption_enabled = true on the replication group, hence
    | REDIS_SCHEME=tls. The AUTH token arrives as REDIS_PASSWORD from the
    | ticketing-dev/redis-auth secret.
    |
    */

    'redis' => [

        'client' => env('REDIS_CLIENT', 'phpredis'),

        'options' => [
            'cluster' => env('REDIS_CLUSTER', 'redis'),
            // Prefix is load-bearing beyond tidiness: the KEDA ScaledObject
            // watches the list key `{prefix}queues:{queue}`, so changing this
            // without changing the chart's redis.prefix stops autoscaling.
            'prefix' => env('REDIS_PREFIX', Str::slug((string) env('APP_NAME', 'laravel'), '_').'_database_'),
        ],

        'default' => [
            'url' => env('REDIS_URL'),
            'scheme' => env('REDIS_SCHEME', 'tcp'),
            'host' => env('REDIS_HOST', '127.0.0.1'),
            'username' => env('REDIS_USERNAME'),
            'password' => env('REDIS_PASSWORD'),
            'port' => env('REDIS_PORT', '6379'),
            'database' => env('REDIS_DB', '0'),
            'read_timeout' => 5,
            'timeout' => 5,
        ],

        'cache' => [
            'url' => env('REDIS_URL'),
            'scheme' => env('REDIS_SCHEME', 'tcp'),
            'host' => env('REDIS_HOST', '127.0.0.1'),
            'username' => env('REDIS_USERNAME'),
            'password' => env('REDIS_PASSWORD'),
            'port' => env('REDIS_PORT', '6379'),
            'database' => env('REDIS_CACHE_DB', '0'),
            'read_timeout' => 5,
            'timeout' => 5,
        ],

        'session' => [
            'url' => env('REDIS_URL'),
            'scheme' => env('REDIS_SCHEME', 'tcp'),
            'host' => env('REDIS_HOST', '127.0.0.1'),
            'username' => env('REDIS_USERNAME'),
            'password' => env('REDIS_PASSWORD'),
            'port' => env('REDIS_PORT', '6379'),
            'database' => env('REDIS_SESSION_DB', '1'),
            'read_timeout' => 5,
            'timeout' => 5,
        ],

        'queue' => [
            'url' => env('REDIS_URL'),
            'scheme' => env('REDIS_SCHEME', 'tcp'),
            'host' => env('REDIS_HOST', '127.0.0.1'),
            'username' => env('REDIS_USERNAME'),
            'password' => env('REDIS_PASSWORD'),
            'port' => env('REDIS_PORT', '6379'),
            'database' => env('REDIS_QUEUE_DB', '2'),
            // BLPOP holds the socket open for up to `block_for` seconds; the
            // read timeout must exceed it or every idle poll throws.
            'read_timeout' => 60,
            'timeout' => 5,
        ],

    ],

];
