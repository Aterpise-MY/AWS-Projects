<?php

declare(strict_types=1);

namespace App\Mail;

use App\Models\Ticket;
use Illuminate\Bus\Queueable;
use Illuminate\Mail\Mailable;
use Illuminate\Mail\Mailables\Content;
use Illuminate\Mail\Mailables\Envelope;
use Illuminate\Queue\SerializesModels;

class TicketNotificationMail extends Mailable
{
    use Queueable;
    use SerializesModels;

    public function __construct(
        public readonly Ticket $ticket,
        public readonly string $event,
    ) {
    }

    public function envelope(): Envelope
    {
        $verb = match ($this->event) {
            'created' => 'opened',
            'escalated' => 'escalated',
            'resolved' => 'resolved',
            default => 'updated',
        };

        return new Envelope(
            subject: sprintf('[%s] Ticket %s: %s', $this->ticket->reference, $verb, $this->ticket->subject),
        );
    }

    public function content(): Content
    {
        return new Content(
            markdown: 'mail.ticket-notification',
            with: [
                'ticket' => $this->ticket,
                'event' => $this->event,
                'url' => route('tickets.show', $this->ticket),
            ],
        );
    }
}
