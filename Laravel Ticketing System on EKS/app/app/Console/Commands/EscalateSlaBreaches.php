<?php

declare(strict_types=1);

namespace App\Console\Commands;

use App\Jobs\SendTicketNotification;
use App\Models\Ticket;
use App\Support\SlaPolicy;
use Illuminate\Console\Command;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Log;

/**
 * Raises the priority of every open ticket whose SLA deadline has passed.
 *
 * This is the workload behind the `scheduler` CronJob in the Helm chart. It is
 * deliberately a console command rather than an HTTP endpoint so it can never
 * be triggered from outside the cluster, and so a long run cannot occupy a
 * php-fpm child.
 */
class EscalateSlaBreaches extends Command
{
    /** @var string */
    protected $signature = 'tickets:escalate-sla
                            {--dry-run : Report what would change without writing}
                            {--chunk=200 : Rows per chunk}';

    /** @var string */
    protected $description = 'Escalate open tickets whose SLA deadline has passed';

    public function handle(): int
    {
        $dryRun = (bool) $this->option('dry-run');
        $chunk = max(1, (int) $this->option('chunk'));
        $now = now();
        $escalated = 0;

        // chunkById, not chunk: the query filters on sla_due_at and the update
        // below changes that column, so an OFFSET-based chunk would skip rows.
        Ticket::query()
            ->breachingSla($now)
            ->orderBy('id')
            ->chunkById($chunk, function ($tickets) use (&$escalated, $dryRun, $now): void {
                foreach ($tickets as $ticket) {
                    $from = $ticket->priority;
                    $to = $from->escalated();

                    if ($dryRun) {
                        $this->line(sprintf(
                            '  would escalate %s  %s -> %s  (due %s)',
                            $ticket->reference,
                            $from->value,
                            $to->value,
                            (string) $ticket->sla_due_at?->toIso8601String(),
                        ));
                        $escalated++;

                        continue;
                    }

                    DB::transaction(function () use ($ticket, $to, $now): void {
                        $ticket->forceFill([
                            'priority' => $to,
                            'escalated_at' => $now,
                            'sla_due_at' => SlaPolicy::nextDueAfterEscalation($to, $now),
                        ])->save();
                    });

                    // Queued, not sent inline: the scheduler pod must finish
                    // fast so the next CronJob run is never skipped by the
                    // concurrencyPolicy.
                    SendTicketNotification::dispatch($ticket, 'escalated');

                    Log::info('ticket.sla.escalated', [
                        'ticket_id' => $ticket->id,
                        'reference' => $ticket->reference,
                        'from' => $from->value,
                        'to' => $to->value,
                    ]);

                    $escalated++;
                }
            });

        $this->info(sprintf(
            '%s %d ticket(s) past SLA at %s',
            $dryRun ? 'Would escalate' : 'Escalated',
            $escalated,
            $now->toIso8601String(),
        ));

        return self::SUCCESS;
    }
}
