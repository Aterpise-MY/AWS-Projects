<?php

declare(strict_types=1);

return [

    /*
    |--------------------------------------------------------------------------
    | Session driver: redis
    |--------------------------------------------------------------------------
    |
    | `file` is the Laravel default and is wrong here for two independent
    | reasons:
    |
    |   1. storage/framework/sessions is an emptyDir. Every rollout replaces the
    |      pods and would log every signed-in user out.
    |   2. Even between rollouts, the ALB spreads requests across web pods with
    |      round-robin. A session written on pod A does not exist on pod B, so
    |      users would appear to log out at random.
    |
    | Redis DB 1 is shared by every pod and survives rollouts. `database` would
    | also work but puts a write on RDS for every request, which a
    | db.t4g.micro does not need.
    |
    */

    'driver' => env('SESSION_DRIVER', 'redis'),

    'lifetime' => (int) env('SESSION_LIFETIME', 120),

    'expire_on_close' => env('SESSION_EXPIRE_ON_CLOSE', false),

    'encrypt' => env('SESSION_ENCRYPT', false),

    'files' => storage_path('framework/sessions'),

    'connection' => env('SESSION_CONNECTION', 'session'),

    'table' => 'sessions',

    'store' => env('SESSION_STORE'),

    'lottery' => [2, 100],

    'cookie' => env('SESSION_COOKIE', 'ticketing_session'),

    'path' => env('SESSION_PATH', '/'),

    'domain' => env('SESSION_DOMAIN'),

    // The ALB terminates TLS, so the cookie is only ever set over HTTPS.
    'secure' => env('SESSION_SECURE_COOKIE', true),

    'http_only' => env('SESSION_HTTP_ONLY', true),

    'same_site' => env('SESSION_SAME_SITE', 'lax'),

    'partitioned' => env('SESSION_PARTITIONED_COOKIE', false),

];
