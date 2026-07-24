<?php

declare(strict_types=1);

return [

    'name' => env('APP_NAME', 'Ticketing'),

    'env' => env('APP_ENV', 'production'),

    'debug' => (bool) env('APP_DEBUG', false),

    'url' => env('APP_URL', 'http://localhost'),

    'timezone' => env('APP_TIMEZONE', 'UTC'),

    'locale' => env('APP_LOCALE', 'en'),
    'fallback_locale' => env('APP_FALLBACK_LOCALE', 'en'),
    'faker_locale' => env('APP_FAKER_LOCALE', 'en_US'),

    /*
    | Supplied from AWS Secrets Manager (ticketing-dev/app-key) through
    | External Secrets Operator. Rotating it invalidates every session cookie
    | and every encrypted column, so it is created once by Terraform and then
    | left alone.
    */
    'cipher' => 'AES-256-CBC',
    'key' => env('APP_KEY'),
    'previous_keys' => array_filter(explode(',', (string) env('APP_PREVIOUS_KEYS', ''))),

    'maintenance' => [
        // `cache` not `file`: the maintenance flag has to be visible to every
        // pod at once, and storage/framework is per-pod emptyDir.
        'driver' => env('APP_MAINTENANCE_DRIVER', 'cache'),
        'store' => env('APP_MAINTENANCE_STORE', 'redis'),
    ],

];
