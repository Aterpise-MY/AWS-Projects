<?php

declare(strict_types=1);

namespace App\Http\Controllers;

use App\Http\Requests\StoreCommentRequest;
use App\Jobs\SendTicketNotification;
use App\Models\Comment;
use App\Models\Ticket;
use Illuminate\Http\Request;
use Symfony\Component\HttpFoundation\Response;

class CommentController extends Controller
{
    /**
     * POST /tickets/{ticket}/comments
     */
    public function store(StoreCommentRequest $request, Ticket $ticket): Response
    {
        $user = $request->user();

        $comment = $ticket->comments()->create([
            'author_id' => (int) $user?->getKey(),
            'parent_id' => $request->integer('parent_id') ?: null,
            'body' => (string) $request->string('body'),
            // Only staff can write internal notes; a requester posting
            // is_internal=1 would otherwise hide their own comment from
            // themselves in the UI.
            'is_internal' => $user?->isStaff() === true && $request->boolean('is_internal'),
        ]);

        // Public replies notify the other party; internal notes stay silent.
        if (! $comment->is_internal) {
            SendTicketNotification::dispatch($ticket, 'commented');
        }

        if ($request->expectsJson()) {
            return response()->json($comment->load('author:id,name,role'), 201);
        }

        return redirect()
            ->route('tickets.show', $ticket)
            ->with('status', 'Comment posted.');
    }

    /**
     * DELETE /tickets/{ticket}/comments/{comment}
     *
     * Deleting a parent takes its replies with it — the FK is
     * ON DELETE CASCADE, so the database does the subtree removal.
     */
    public function destroy(Request $request, Ticket $ticket, Comment $comment): Response
    {
        abort_unless($comment->ticket_id === $ticket->getKey(), 404);
        abort_unless(
            $request->user()?->isStaff() === true || $comment->author_id === $request->user()?->getKey(),
            403,
        );

        $comment->delete();

        if ($request->expectsJson()) {
            return response()->json(null, 204);
        }

        return redirect()->route('tickets.show', $ticket)->with('status', 'Comment deleted.');
    }
}
