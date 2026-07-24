<?php

declare(strict_types=1);

namespace App\Jobs;

use App\Mail\TicketNotificationMail;
use App\Models\Ticket;
use Illuminate\Bus\Queueable;
use Illuminate\Contracts\Queue\ShouldQueue;
use Illuminate\Foundation\Bus\Dispatchable;
use Illuminate\Queue\InteractsWithQueue;
use Illuminate\Queue\SerializesModels;
use Illuminate\Support\Facades\Log;
use Illuminate\Support\Facades\Mail;
use Throwable;

/**
 * Outbound e-mail for a ticket event.
 *
 * This is the reason the deployment has a separate `worker` Deployment and a
 * Redis queue at all. SMTP handshakes take hundreds of milliseconds to several
 * seconds and fail in ways an HTTP request should not care about; doing it
 * inline would hold a php-fpm child open for the whole exchange. With only
 * `pm.max_children = 10` per web pod, a slow mail relay would exhaust the pool
 * and the readiness probe would start failing on a healthy application.
 *
 * The queue depth of `laravel_database_queues:default` is also what KEDA scales
 * the worker Deployment on, so this job is the load signal.
 */
class SendTicketNotification implements ShouldQueue
{
    use Dispatchable;
    use InteractsWithQueue;
    use Queueable;
    use SerializesModels;

    /**
     * Redis is not a durable broker. Three attempts with a backoff covers a
     * transient SMTP failure; anything beyond that belongs in `failed_jobs`
     * where a human can look at it.
     */
    public int $tries = 3;

    /** @var array<int, int> */
    public array $backoff = [10, 60, 300];

    /**
     * Must stay below queue.connections.redis.retry_after (90s), otherwise the
     * queue releases the job back while this attempt is still running and the
     * e-mail goes out twice.
     */
    public int $timeout = 60;

    public function __construct(
        public readonly Ticket $ticket,
        public readonly string $event = 'created',
    ) {
        $this->onQueue('default');
    }

    public function handle(): void
    {
        $this->ticket->loadMissing(['requester', 'assignee']);

        $recipients = collect([
            $this->ticket->requester?->email,
            $this->ticket->assignee?->email,
        ])->filter()->unique()->values();

        if ($recipients->isEmpty()) {
            Log::warning('ticket.notification.no_recipients', [
                'ticket_id' => $this->ticket->id,
                'event' => $this->event,
            ]);

            return;
        }

        foreach ($recipients as $recipient) {
            Mail::to($recipient)->send(
                new TicketNotificationMail($this->ticket, $this->event)
            );
        }

        Log::info('ticket.notification.sent', [
            'ticket_id' => $this->ticket->id,
            'reference' => $this->ticket->reference,
            'event' => $this->event,
            'recipients' => $recipients->count(),
        ]);
    }

    public function failed(Throwable $exception): void
    {
        Log::error('ticket.notification.failed', [
            'ticket_id' => $this->ticket->id,
            'event' => $this->event,
            'exception' => $exception->getMessage(),
        ]);
    }

    /**
     * Tags surface in Horizon and in the job payload; handy when grepping
     * CloudWatch Logs Insights for one ticket's worker output.
     *
     * @return array<int, string>
     */
    public function tags(): array
    {
        return ['ticket:'.$this->ticket->id, 'event:'.$this->event];
    }
}
