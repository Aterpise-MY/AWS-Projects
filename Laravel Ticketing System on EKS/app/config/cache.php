<?php

declare(strict_types=1);

return [

    'default' => env('CACHE_STORE', 'redis'),

    'stores' => [

        'array' => [
            'driver' => 'array',
            'serialize' => false,
        ],

        'redis' => [
            'driver' => 'redis',
            // `cache` entry in config/database.php -> DB index 0.
            'connection' => env('REDIS_CACHE_CONNECTION', 'cache'),
            // Schedule::withoutOverlapping() takes its lock through the cache
            // store. Pointing it at the same shared Redis is what makes the
            // lock cluster-wide rather than per-pod.
            'lock_connection' => env('REDIS_CACHE_LOCK_CONNECTION', 'default'),
        ],

        'file' => [
            'driver' => 'file',
            'path' => storage_path('framework/cache/data'),
            'lock_path' => storage_path('framework/cache/data'),
        ],

    ],

    'prefix' => env('CACHE_PREFIX', 'ticketing_cache'),

];
