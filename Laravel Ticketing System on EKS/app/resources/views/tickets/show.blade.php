@extends('layouts.app')

@section('title', $ticket->reference)

@section('content')
    <div class="mb-8 rounded border border-slate-200 bg-white p-6">
        <div class="flex items-start justify-between gap-6">
            <div>
                <p class="font-mono text-xs text-slate-400">{{ $ticket->reference }}</p>
                <h1 class="mt-1 text-xl font-semibold">{{ $ticket->subject }}</h1>
                <p class="mt-2 text-sm text-slate-500">
                    Opened by {{ $ticket->requester->name }} {{ $ticket->created_at?->diffForHumans() }}
                </p>
            </div>

            <div class="text-right text-sm">
                <p>{{ $ticket->status->label() }} &middot; {{ $ticket->priority->label() }}</p>
                <p class="mt-1 {{ $ticket->isOverdue() ? 'text-red-600' : 'text-slate-500' }}">
                    SLA {{ $ticket->sla_due_at?->diffForHumans() ?? 'n/a' }}
                </p>
                @if ($ticket->escalated_at)
                    <p class="mt-1 text-xs text-amber-600">
                        Escalated {{ $ticket->escalated_at->diffForHumans() }}
                    </p>
                @endif
            </div>
        </div>

        <div class="prose prose-sm mt-6 max-w-none whitespace-pre-line">{{ $ticket->body }}</div>
    </div>

    @if (auth()->user()?->isStaff())
        <form method="POST" action="{{ route('tickets.update', $ticket) }}"
              class="mb-8 flex flex-wrap items-end gap-3 rounded border border-slate-200 bg-white p-4">
            @csrf
            @method('PATCH')

            <label class="text-sm">
                <span class="block text-slate-500">Status</span>
                <select name="status" class="mt-1 rounded border-slate-300 text-sm">
                    @foreach ($statuses as $status)
                        <option value="{{ $status->value }}" @selected($ticket->status === $status)>{{ $status->label() }}</option>
                    @endforeach
                </select>
            </label>

            <label class="text-sm">
                <span class="block text-slate-500">Priority</span>
                <select name="priority" class="mt-1 rounded border-slate-300 text-sm">
                    @foreach ($priorities as $priority)
                        <option value="{{ $priority->value }}" @selected($ticket->priority === $priority)>{{ $priority->label() }}</option>
                    @endforeach
                </select>
            </label>

            <button type="submit" class="rounded bg-slate-900 px-3 py-1.5 text-sm text-white">Update</button>
        </form>
    @endif

    <section class="mb-8">
        <h2 class="mb-3 text-sm font-semibold uppercase tracking-wide text-slate-500">Attachments</h2>

        <ul class="mb-4 space-y-2 text-sm">
            @forelse ($ticket->attachments as $attachment)
                <li class="flex items-center justify-between rounded border border-slate-200 bg-white px-4 py-2">
                    <a href="{{ route('tickets.attachments.show', [$ticket, $attachment]) }}" class="text-sky-700 hover:underline">
                        {{ $attachment->filename }}
                    </a>
                    <span class="text-xs text-slate-400">
                        {{ $attachment->humanSize() }} &middot; {{ $attachment->uploader->name }}
                    </span>
                </li>
            @empty
                <li class="text-slate-400">No attachments.</li>
            @endforelse
        </ul>

        {{-- Uploads go straight to S3 from the controller; nothing is written to the pod. --}}
        <form method="POST" action="{{ route('tickets.attachments.store', $ticket) }}"
              enctype="multipart/form-data" class="flex items-center gap-3">
            @csrf
            <input type="file" name="file" required class="text-sm">
            <button type="submit" class="rounded border border-slate-300 px-3 py-1.5 text-sm">Upload</button>
        </form>
    </section>

    <section>
        <h2 class="mb-3 text-sm font-semibold uppercase tracking-wide text-slate-500">Conversation</h2>

        <div class="space-y-4">
            @forelse ($ticket->rootComments as $comment)
                @include('tickets.partials.comment', ['comment' => $comment, 'ticket' => $ticket, 'depth' => 0])
            @empty
                <p class="text-sm text-slate-400">No comments yet.</p>
            @endforelse
        </div>

        <form method="POST" action="{{ route('tickets.comments.store', $ticket) }}" class="mt-6 space-y-3">
            @csrf
            <textarea name="body" rows="4" required class="block w-full rounded border-slate-300" placeholder="Add a reply"></textarea>

            @if (auth()->user()?->isStaff())
                <label class="flex items-center gap-2 text-sm text-slate-600">
                    <input type="checkbox" name="is_internal" value="1" class="rounded border-slate-300">
                    Internal note (not e-mailed to the requester)
                </label>
            @endif

            <button type="submit" class="rounded bg-slate-900 px-4 py-2 text-sm text-white">Post</button>
        </form>
    </section>
@endsection
