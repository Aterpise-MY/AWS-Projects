<?php

declare(strict_types=1);

return [

    'default' => env('QUEUE_CONNECTION', 'redis'),

    'connections' => [

        // Only used by tests that need a job to run inline.
        'sync' => [
            'driver' => 'sync',
        ],

        'redis' => [
            'driver' => 'redis',
            // Points at the `queue` entry in config/database.php -> DB index 2.
            'connection' => env('REDIS_QUEUE_CONNECTION', 'queue'),
            'queue' => env('REDIS_QUEUE', 'default'),

            // Must stay ABOVE the longest job timeout
            // (SendTicketNotification::$timeout = 60). If retry_after fires
            // while a job is still running, the queue hands the same payload to
            // a second worker and the customer gets two e-mails.
            'retry_after' => (int) env('QUEUE_RETRY_AFTER', 90),

            // BLPOP blocks for 5s instead of polling in a hot loop. On a spot
            // t4g.medium this is the difference between an idle worker burning
            // CPU and one sitting at effectively zero.
            'block_for' => 5,

            'after_commit' => true,
        ],

    ],

    'batching' => [
        'database' => env('DB_CONNECTION', 'mysql'),
        'table' => 'job_batches',
    ],

    /*
    |--------------------------------------------------------------------------
    | Failed jobs
    |--------------------------------------------------------------------------
    |
    | Failures go to MySQL, not Redis. ElastiCache here has
    | snapshot_retention_limit = 0, so a node replacement loses everything in
    | Redis — acceptable for a cache, not acceptable for the record of a
    | notification that never reached a customer.
    |
    */
    'failed' => [
        'driver' => env('QUEUE_FAILED_DRIVER', 'database-uuids'),
        'database' => env('DB_CONNECTION', 'mysql'),
        'table' => 'failed_jobs',
    ],

];
