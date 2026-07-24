<?php

declare(strict_types=1);

namespace Database\Factories;

use App\Enums\TicketPriority;
use App\Enums\TicketStatus;
use App\Models\Ticket;
use App\Models\User;
use App\Support\SlaPolicy;
use Illuminate\Database\Eloquent\Factories\Factory;
use Illuminate\Support\Str;

/**
 * @extends Factory<Ticket>
 */
class TicketFactory extends Factory
{
    protected $model = Ticket::class;

    /**
     * @return array<string, mixed>
     */
    public function definition(): array
    {
        $priority = fake()->randomElement(TicketPriority::cases());

        return [
            'reference' => 'TCK-'.Str::upper(Str::random(8)),
            'subject' => fake()->sentence(6),
            'body' => fake()->paragraphs(3, true),
            'status' => TicketStatus::Open,
            'priority' => $priority,
            'requester_id' => User::factory(),
            'assignee_id' => null,
            'sla_due_at' => SlaPolicy::dueAt($priority),
        ];
    }

    /**
     * A ticket whose deadline is already in the past — the input for
     * EscalateSlaBreaches.
     */
    public function overdue(): static
    {
        return $this->state(fn (): array => [
            'status' => TicketStatus::Open,
            'sla_due_at' => now()->subHour(),
        ]);
    }

    public function closed(): static
    {
        return $this->state(fn (): array => [
            'status' => TicketStatus::Closed,
            'resolved_at' => now(),
            'sla_due_at' => null,
        ]);
    }
}
