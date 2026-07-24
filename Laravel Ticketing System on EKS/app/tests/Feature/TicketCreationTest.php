<?php

declare(strict_types=1);

use App\Enums\TicketPriority;
use App\Enums\TicketStatus;
use App\Jobs\SendTicketNotification;
use App\Models\Ticket;
use App\Models\User;
use Illuminate\Contracts\Queue\ShouldQueue;
use Illuminate\Support\Facades\Queue;

/*
|--------------------------------------------------------------------------
| Ticket creation
|--------------------------------------------------------------------------
|
| The point of these assertions is the infrastructure contract, not the CRUD:
| if the notification stopped being queued, the worker Deployment and the KEDA
| ScaledObject would have nothing to do and nobody would notice until an SMTP
| outage started timing out user requests.
|
*/

it('queues the notification instead of sending it inline', function (): void {
    Queue::fake();

    $user = User::factory()->create();

    $response = $this->actingAs($user)->postJson('/tickets', [
        'subject' => 'Printer on floor 3 is offline',
        'body' => 'The device stopped responding after the overnight patch window.',
        'priority' => 'high',
    ]);

    $response->assertCreated();

    Queue::assertPushed(SendTicketNotification::class, function (SendTicketNotification $job): bool {
        return $job->event === 'created'
            && $job->ticket->subject === 'Printer on floor 3 is offline';
    });

    // The dispatch must be asynchronous. A job class that stopped implementing
    // ShouldQueue would still satisfy assertPushed under Queue::fake(), so
    // assert the contract directly.
    expect(new SendTicketNotification(Ticket::first()))->toBeInstanceOf(ShouldQueue::class);
});

it('stamps an SLA deadline derived from the priority', function (): void {
    Queue::fake();

    $user = User::factory()->create();

    $this->actingAs($user)->postJson('/tickets', [
        'subject' => 'VPN drops every few minutes',
        'body' => 'Reconnects on its own but kills long-running SSH sessions.',
        'priority' => 'urgent',
    ])->assertCreated();

    $ticket = Ticket::sole();

    expect($ticket->status)->toBe(TicketStatus::Open)
        ->and($ticket->priority)->toBe(TicketPriority::Urgent)
        ->and($ticket->sla_due_at)->not->toBeNull()
        // config('ticketing.sla_hours.urgent') defaults to 2.
        ->and($ticket->sla_due_at->diffInMinutes(now()->addHours(2)))->toBeLessThan(2);
});

it('assigns a human reference derived from the id', function (): void {
    Queue::fake();

    $user = User::factory()->create();

    $this->actingAs($user)->postJson('/tickets', [
        'subject' => 'Laptop will not dock',
        'body' => 'External monitors stay black on the new dock firmware.',
    ])->assertCreated();

    $ticket = Ticket::sole();

    expect($ticket->reference)->toBe('TCK-'.str_pad((string) $ticket->id, 6, '0', STR_PAD_LEFT));
});

it('rejects a ticket with no subject', function (): void {
    Queue::fake();

    $user = User::factory()->create();

    $this->actingAs($user)
        ->postJson('/tickets', ['body' => 'Something is broken but I forgot the subject.'])
        ->assertStatus(422)
        ->assertJsonValidationErrors('subject');

    Queue::assertNothingPushed();
});
