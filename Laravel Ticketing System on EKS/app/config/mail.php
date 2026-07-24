<?php

declare(strict_types=1);

return [

    'default' => env('MAIL_MAILER', 'smtp'),

    'mailers' => [

        'smtp' => [
            'transport' => 'smtp',
            'scheme' => env('MAIL_SCHEME'),
            'url' => env('MAIL_URL'),
            'host' => env('MAIL_HOST', 'localhost'),
            'port' => (int) env('MAIL_PORT', 587),
            'username' => env('MAIL_USERNAME'),
            'password' => env('MAIL_PASSWORD'),
            'encryption' => env('MAIL_ENCRYPTION', 'tls'),
            // Bounded so a hung relay cannot outlive
            // SendTicketNotification::$timeout and get the worker killed
            // mid-send with no record of what happened.
            'timeout' => 15,
            'local_domain' => env('MAIL_EHLO_DOMAIN'),
        ],

        'log' => [
            'transport' => 'log',
            'channel' => env('MAIL_LOG_CHANNEL', 'stderr'),
        ],

        'array' => [
            'transport' => 'array',
        ],

        'failover' => [
            'transport' => 'failover',
            'mailers' => ['smtp', 'log'],
        ],

    ],

    'from' => [
        'address' => env('MAIL_FROM_ADDRESS', 'ticketing@example.com'),
        'name' => env('MAIL_FROM_NAME', 'Ticketing'),
    ],

];
