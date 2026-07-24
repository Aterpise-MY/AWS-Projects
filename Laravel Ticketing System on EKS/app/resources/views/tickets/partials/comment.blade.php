{{--
    Recursive partial for the threaded comment tree.
    `depth` guards the recursion: TicketController only eager-loads three
    levels, so rendering deeper would fire a query per node.
--}}
<div class="rounded border border-slate-200 bg-white p-4 {{ $comment->is_internal ? 'border-amber-200 bg-amber-50' : '' }}"
     style="margin-left: {{ min($depth, 3) * 1.5 }}rem">
    <div class="flex items-center justify-between text-xs text-slate-500">
        <span>
            <strong class="text-slate-700">{{ $comment->author->name }}</strong>
            &middot; {{ $comment->created_at?->diffForHumans() }}
            @if ($comment->is_internal)
                <span class="ml-2 rounded bg-amber-200 px-1.5 py-0.5 text-amber-900">internal</span>
            @endif
        </span>

        @if (auth()->user()?->isStaff() || $comment->author_id === auth()->id())
            <form method="POST" action="{{ route('tickets.comments.destroy', [$ticket, $comment]) }}">
                @csrf
                @method('DELETE')
                <button type="submit" class="text-slate-400 hover:text-red-600">delete</button>
            </form>
        @endif
    </div>

    <p class="mt-2 whitespace-pre-line text-sm">{{ $comment->body }}</p>
</div>

@if ($depth < 3)
    @foreach ($comment->replies as $reply)
        <div class="mt-3">
            @include('tickets.partials.comment', ['comment' => $reply, 'ticket' => $ticket, 'depth' => $depth + 1])
        </div>
    @endforeach
@endif
