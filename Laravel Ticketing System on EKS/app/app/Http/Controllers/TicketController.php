<?php

declare(strict_types=1);

namespace App\Http\Controllers;

use App\Enums\TicketPriority;
use App\Enums\TicketStatus;
use App\Http\Requests\StoreTicketRequest;
use App\Http\Requests\UpdateTicketRequest;
use App\Jobs\SendTicketNotification;
use App\Models\Ticket;
use App\Support\SlaPolicy;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Str;
use Symfony\Component\HttpFoundation\Response;

class TicketController extends Controller
{
    /**
     * GET /tickets
     */
    public function index(Request $request): Response
    {
        $user = $request->user();

        $tickets = Ticket::query()
            ->with(['requester:id,name,email', 'assignee:id,name,email'])
            ->withCount('comments')
            // Requesters only ever see their own tickets. Staff see everything.
            ->when($user !== null && ! $user->isStaff(), fn ($q) => $q->where('requester_id', $user->getKey()))
            ->when($request->filled('status'), fn ($q) => $q->where('status', $request->string('status')->value()))
            ->when($request->filled('priority'), fn ($q) => $q->where('priority', $request->string('priority')->value()))
            ->when($request->boolean('overdue'), fn ($q) => $q->breachingSla())
            ->latest('id')
            ->paginate(20)
            ->withQueryString();

        if ($request->expectsJson()) {
            return response()->json($tickets);
        }

        return response()->view('tickets.index', [
            'tickets' => $tickets,
            'statuses' => TicketStatus::cases(),
            'priorities' => TicketPriority::cases(),
        ]);
    }

    /**
     * GET /tickets/create
     */
    public function create(): Response
    {
        return response()->view('tickets.create', [
            'priorities' => TicketPriority::cases(),
        ]);
    }

    /**
     * POST /tickets
     */
    public function store(StoreTicketRequest $request): Response
    {
        $priority = $request->enum('priority', TicketPriority::class) ?? TicketPriority::Normal;

        $ticket = DB::transaction(function () use ($request, $priority): Ticket {
            $ticket = Ticket::create([
                // Placeholder: the human-facing reference is derived from the
                // auto-increment id, which does not exist until after INSERT.
                'reference' => 'TMP-'.Str::upper(Str::random(16)),
                'subject' => (string) $request->string('subject'),
                'body' => (string) $request->string('body'),
                'status' => TicketStatus::Open,
                'priority' => $priority,
                'requester_id' => (int) $request->user()?->getKey(),
                'assignee_id' => $request->integer('assignee_id') ?: null,
                'sla_due_at' => SlaPolicy::dueAt($priority),
            ]);

            $ticket->forceFill([
                'reference' => 'TCK-'.str_pad((string) $ticket->getKey(), 6, '0', STR_PAD_LEFT),
            ])->save();

            return $ticket;
        });

        // Queued, never sent inline. See App\Jobs\SendTicketNotification for
        // why: an inline SMTP handshake would hold a php-fpm child for the
        // duration of the request.
        SendTicketNotification::dispatch($ticket, 'created');

        if ($request->expectsJson()) {
            return response()->json(
                $ticket->load(['requester:id,name,email', 'assignee:id,name,email']),
                201,
            );
        }

        return redirect()
            ->route('tickets.show', $ticket)
            ->with('status', "Ticket {$ticket->reference} created.");
    }

    /**
     * GET /tickets/{ticket}
     */
    public function show(Request $request, Ticket $ticket): Response
    {
        $ticket->load([
            'requester:id,name,email',
            'assignee:id,name,email',
            'attachments.uploader:id,name',
            // Three levels of threading; deeper replies are rendered flat.
            'rootComments.author:id,name,role',
            'rootComments.replies.author:id,name,role',
            'rootComments.replies.replies.author:id,name,role',
        ]);

        if ($request->expectsJson()) {
            return response()->json($ticket);
        }

        return response()->view('tickets.show', [
            'ticket' => $ticket,
            'statuses' => TicketStatus::cases(),
            'priorities' => TicketPriority::cases(),
        ]);
    }

    /**
     * PATCH /tickets/{ticket}
     */
    public function update(UpdateTicketRequest $request, Ticket $ticket): Response
    {
        $status = $request->enum('status', TicketStatus::class);
        $priority = $request->enum('priority', TicketPriority::class);
        $changes = [];

        if ($priority !== null && $priority !== $ticket->priority) {
            $changes['priority'] = $priority;
            // Re-basing the deadline on the original creation time keeps an
            // upgrade to `urgent` from silently granting more time than the
            // ticket has already consumed.
            $changes['sla_due_at'] = SlaPolicy::dueAt($priority, $ticket->created_at);
        }

        if ($status !== null && $status !== $ticket->status) {
            $changes['status'] = $status;

            if ($status->isTerminal()) {
                $changes['resolved_at'] = now();
                // A closed ticket has no live SLA; leaving a past due date here
                // would keep it in the escalation query forever.
                $changes['sla_due_at'] = null;
            }
        }

        if ($request->has('assignee_id')) {
            $changes['assignee_id'] = $request->integer('assignee_id') ?: null;
        }

        if ($changes !== []) {
            $ticket->forceFill($changes)->save();

            SendTicketNotification::dispatch(
                $ticket,
                isset($changes['status']) && $status?->isTerminal() ? 'resolved' : 'updated',
            );
        }

        if ($request->expectsJson()) {
            return response()->json($ticket->fresh());
        }

        return redirect()->route('tickets.show', $ticket)->with('status', 'Ticket updated.');
    }
}
