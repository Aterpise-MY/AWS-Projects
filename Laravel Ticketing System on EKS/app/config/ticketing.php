<?php

declare(strict_types=1);

/*
|--------------------------------------------------------------------------
| Ticketing domain settings
|--------------------------------------------------------------------------
|
| Hours from creation to SLA breach, per priority. Read by
| App\Enums\TicketPriority::slaHours() and applied by App\Support\SlaPolicy.
| Kept in config rather than in the enum so the dev cluster can shorten the
| windows for a demo without a code change or an image rebuild.
|
*/

return [

    'sla_hours' => [
        'low' => (int) env('SLA_HOURS_LOW', 72),
        'normal' => (int) env('SLA_HOURS_NORMAL', 24),
        'high' => (int) env('SLA_HOURS_HIGH', 8),
        'urgent' => (int) env('SLA_HOURS_URGENT', 2),
    ],

    'attachments' => [
        // Kilobytes. Must not exceed php.ini upload_max_filesize or the nginx
        // client_max_body_size, both set to 12M in docker/.
        'max_kilobytes' => (int) env('ATTACHMENT_MAX_KB', 10240),
        'presigned_url_minutes' => (int) env('ATTACHMENT_URL_MINUTES', 5),
    ],

];
