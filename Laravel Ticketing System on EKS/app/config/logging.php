<?php

declare(strict_types=1);

use Monolog\Formatter\JsonFormatter;
use Monolog\Handler\StreamHandler;
use Monolog\Processor\PsrLogMessageProcessor;

return [

    /*
    |--------------------------------------------------------------------------
    | Default channel: stderr
    |--------------------------------------------------------------------------
    |
    | Not `stack`, not `single`, not `daily`.
    |
    | The container runs with readOnlyRootFilesystem: true. Writing to
    | storage/logs/laravel.log would either fail outright or land on an emptyDir
    | that is destroyed with the pod, and nothing would ever collect it. Fluent
    | Bit (DaemonSet, `fluent_bit` IRSA role) tails the container stdout/stderr
    | stream out of /var/log/containers and ships it to CloudWatch Logs.
    |
    | The JSON formatter matters just as much as the destination: CloudWatch
    | Logs Insights can only filter on `ticket_id` or `level` if the line is a
    | JSON object rather than Laravel's default single-line text format.
    |
    */

    'default' => env('LOG_CHANNEL', 'stderr'),

    'deprecations' => [
        'channel' => env('LOG_DEPRECATIONS_CHANNEL', 'null'),
        'trace' => env('LOG_DEPRECATIONS_TRACE', false),
    ],

    'channels' => [

        'stderr' => [
            'driver' => 'monolog',
            'level' => env('LOG_LEVEL', 'info'),
            'handler' => StreamHandler::class,
            'formatter' => env('LOG_STDERR_FORMATTER', JsonFormatter::class),
            'formatter_with' => [
                // One JSON object per line. Multi-line output would be split
                // into separate CloudWatch events and become unparseable.
                'batchMode' => JsonFormatter::BATCH_MODE_NEWLINES,
                'appendNewline' => true,
            ],
            'with' => [
                'stream' => 'php://stderr',
            ],
            'processors' => [PsrLogMessageProcessor::class],
        ],

        // Local development only.
        'single' => [
            'driver' => 'single',
            'path' => storage_path('logs/laravel.log'),
            'level' => env('LOG_LEVEL', 'debug'),
            'replace_placeholders' => true,
        ],

        'null' => [
            'driver' => 'monolog',
            'handler' => Monolog\Handler\NullHandler::class,
        ],

        'emergency' => [
            'path' => storage_path('logs/laravel.log'),
        ],

    ],

];
