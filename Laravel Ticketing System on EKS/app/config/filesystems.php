<?php

declare(strict_types=1);

return [

    'default' => env('FILESYSTEM_DISK', 's3'),

    'disks' => [

        // Present for artisan/test convenience only. Nothing user-facing may
        // write here: the container root filesystem is read-only and the pod's
        // storage is an emptyDir that disappears on restart.
        'local' => [
            'driver' => 'local',
            'root' => storage_path('app'),
            'serve' => true,
            'throw' => false,
        ],

        /*
        |----------------------------------------------------------------------
        | s3 — ticket attachments
        |----------------------------------------------------------------------
        |
        | Note what is NOT here: `key` and `secret`.
        |
        | The pod's ServiceAccount `ticketing` is annotated with the `app` IRSA
        | role ARN. The EKS pod identity webhook injects AWS_ROLE_ARN and
        | AWS_WEB_IDENTITY_TOKEN_FILE, and the AWS SDK's default provider chain
        | picks those up on its own. Passing null/empty key and secret would
        | make the SDK use static credentials of "" and every PutObject would
        | come back 403 SignatureDoesNotMatch — so the keys are omitted
        | entirely, not set to null.
        |
        | The IRSA role is scoped to s3:GetObject/PutObject/DeleteObject/
        | ListBucket on this bucket only.
        |
        */
        's3' => [
            'driver' => 's3',
            'region' => env('AWS_DEFAULT_REGION', 'ap-southeast-1'),
            'bucket' => env('AWS_BUCKET'),
            'url' => env('AWS_URL'),
            'endpoint' => env('AWS_ENDPOINT'),
            'use_path_style_endpoint' => env('AWS_USE_PATH_STYLE_ENDPOINT', false),
            // Objects stay private; downloads go through pre-signed URLs.
            'visibility' => 'private',
            // Surface S3 errors as exceptions instead of a silent `false`,
            // which would otherwise leave an attachment row pointing at an
            // object that was never written.
            'throw' => true,
        ],

    ],

    // The public symlink is intentionally not created: `php artisan
    // storage:link` writes into public/, which is read-only in the container.
    'links' => [],

];
