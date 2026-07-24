<?php

declare(strict_types=1);

namespace App\Enums;

enum TicketPriority: string
{
    case Low = 'low';
    case Normal = 'normal';
    case High = 'high';
    case Urgent = 'urgent';

    /**
     * Hours allowed before the ticket breaches its SLA.
     *
     * Configurable per environment through config/ticketing.php so the dev
     * cluster can use shorter windows than production without a code change.
     */
    public function slaHours(): int
    {
        /** @var array<string, int> $map */
        $map = config('ticketing.sla_hours', []);

        return (int) ($map[$this->value] ?? 24);
    }

    /**
     * The next priority up. Urgent is the ceiling.
     */
    public function escalated(): self
    {
        return match ($this) {
            self::Low => self::Normal,
            self::Normal => self::High,
            self::High, self::Urgent => self::Urgent,
        };
    }

    public function label(): string
    {
        return ucfirst($this->value);
    }
}
