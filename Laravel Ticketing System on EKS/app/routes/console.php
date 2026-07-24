<?php

declare(strict_types=1);

use App\Console\Commands\EscalateSlaBreaches;
use Illuminate\Foundation\Inspiring;
use Illuminate\Support\Facades\Artisan;
use Illuminate\Support\Facades\Schedule;

Artisan::command('inspire', function (): void {
    $this->comment(Inspiring::quote());
})->purpose('Display an inspiring quote');

/*
|--------------------------------------------------------------------------
| Scheduled work
|--------------------------------------------------------------------------
|
| The `scheduler` CronJob in the Helm chart runs `php artisan schedule:run`
| once a minute. Everything below decides what actually fires on any given
| minute — the cadence lives here, in the application, not in the CronJob
| spec, so changing it does not require a Helm upgrade.
|
*/

Schedule::command(EscalateSlaBreaches::class)
    ->everyFifteenMinutes()

    // The CronJob's concurrencyPolicy stops two *scheduler* pods overlapping,
    // but it cannot stop a slow run from a previous minute overlapping the
    // next one, and it does not apply if the command is ever run by hand.
    // withoutOverlapping takes a lock in the Redis cache store (DB 0), which
    // every pod shares, so the guarantee holds cluster-wide.
    //
    // The 30-minute expiry is the safety valve: if the pod holding the lock is
    // OOM-killed or evicted mid-run it never releases it, and without a TTL
    // escalation would silently stop forever.
    ->withoutOverlapping(30)

    // Nothing tails a file in this container — the root filesystem is
    // read-only and Fluent Bit reads stdout.
    ->appendOutputTo('php://stdout')

    ->runInBackground()
    ->description('Escalate open tickets past their SLA deadline');

// Failed notification payloads are kept for a week, then pruned so the
// failed_jobs table does not grow unbounded on a 20 GB RDS volume.
Schedule::command('queue:prune-failed', ['--hours=168'])
    ->daily()
    ->withoutOverlapping(30);
