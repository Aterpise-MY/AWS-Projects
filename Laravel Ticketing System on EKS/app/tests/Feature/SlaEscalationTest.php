<?php

declare(strict_types=1);

use App\Enums\TicketPriority;
use App\Jobs\SendTicketNotification;
use App\Models\Ticket;
use Illuminate\Support\Facades\Queue;

it('escalates only the tickets past their deadline', function (): void {
    Queue::fake();

    $overdue = Ticket::factory()->overdue()->create(['priority' => TicketPriority::Normal]);
    $onTime = Ticket::factory()->create([
        'priority' => TicketPriority::Normal,
        'sla_due_at' => now()->addHours(6),
    ]);
    $closed = Ticket::factory()->closed()->create(['priority' => TicketPriority::Normal]);

    $this->artisan('tickets:escalate-sla')->assertSuccessful();

    expect($overdue->fresh()->priority)->toBe(TicketPriority::High)
        ->and($overdue->fresh()->escalated_at)->not->toBeNull()
        // The deadline is re-armed so the next run does not escalate it again.
        ->and($overdue->fresh()->sla_due_at->isFuture())->toBeTrue()
        ->and($onTime->fresh()->priority)->toBe(TicketPriority::Normal)
        ->and($closed->fresh()->priority)->toBe(TicketPriority::Normal);

    Queue::assertPushed(SendTicketNotification::class, 1);
});

it('caps escalation at urgent', function (): void {
    Queue::fake();

    $ticket = Ticket::factory()->overdue()->create(['priority' => TicketPriority::Urgent]);

    $this->artisan('tickets:escalate-sla')->assertSuccessful();

    expect($ticket->fresh()->priority)->toBe(TicketPriority::Urgent);
});

it('changes nothing on a dry run', function (): void {
    Queue::fake();

    $ticket = Ticket::factory()->overdue()->create(['priority' => TicketPriority::Low]);

    $this->artisan('tickets:escalate-sla', ['--dry-run' => true])->assertSuccessful();

    expect($ticket->fresh()->priority)->toBe(TicketPriority::Low)
        ->and($ticket->fresh()->escalated_at)->toBeNull();

    Queue::assertNothingPushed();
});
