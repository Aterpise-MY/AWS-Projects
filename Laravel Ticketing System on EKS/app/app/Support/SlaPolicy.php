<?php

declare(strict_types=1);

namespace App\Support;

use App\Enums\TicketPriority;
use Illuminate\Support\Carbon;

/**
 * Single place where "when is this ticket due" is decided, so the controller,
 * the escalation command and the tests cannot drift apart.
 */
final class SlaPolicy
{
    public static function dueAt(TicketPriority $priority, ?Carbon $from = null): Carbon
    {
        return ($from ?? now())->copy()->addHours($priority->slaHours());
    }

    /**
     * A breach re-arms the clock at the escalated priority rather than leaving
     * `sla_due_at` in the past. Without this the ticket would be re-escalated
     * on every 15-minute run until somebody touched it.
     */
    public static function nextDueAfterEscalation(TicketPriority $escalated, ?Carbon $from = null): Carbon
    {
        return self::dueAt($escalated, $from);
    }
}
