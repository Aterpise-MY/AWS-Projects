@component('mail::message')
# Ticket {{ $ticket->reference }}

**{{ $ticket->subject }}**

@if ($event === 'created')
A new ticket has been opened.
@elseif ($event === 'escalated')
This ticket passed its SLA deadline and was escalated to **{{ $ticket->priority->label() }}**.
@elseif ($event === 'resolved')
This ticket has been marked **{{ $ticket->status->label() }}**.
@else
This ticket has been updated.
@endif

| Field | Value |
|---|---|
| Status | {{ $ticket->status->label() }} |
| Priority | {{ $ticket->priority->label() }} |
| Requester | {{ $ticket->requester->name }} |
| Assignee | {{ $ticket->assignee?->name ?? 'Unassigned' }} |
| SLA due | {{ $ticket->sla_due_at?->toDayDateTimeString() ?? 'n/a' }} |

@component('mail::button', ['url' => $url])
View ticket
@endcomponent

Thanks,<br>
{{ config('app.name') }}
@endcomponent
