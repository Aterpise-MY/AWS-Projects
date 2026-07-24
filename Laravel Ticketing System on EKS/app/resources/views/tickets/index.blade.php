@extends('layouts.app')

@section('title', 'Tickets')

@section('content')
    <form method="GET" action="{{ route('tickets.index') }}" class="mb-6 flex flex-wrap items-end gap-3">
        <label class="text-sm">
            <span class="block text-slate-500">Status</span>
            <select name="status" class="mt-1 rounded border-slate-300 text-sm">
                <option value="">Any</option>
                @foreach ($statuses as $status)
                    <option value="{{ $status->value }}" @selected(request('status') === $status->value)>
                        {{ $status->label() }}
                    </option>
                @endforeach
            </select>
        </label>

        <label class="text-sm">
            <span class="block text-slate-500">Priority</span>
            <select name="priority" class="mt-1 rounded border-slate-300 text-sm">
                <option value="">Any</option>
                @foreach ($priorities as $priority)
                    <option value="{{ $priority->value }}" @selected(request('priority') === $priority->value)>
                        {{ $priority->label() }}
                    </option>
                @endforeach
            </select>
        </label>

        <label class="flex items-center gap-2 text-sm">
            <input type="checkbox" name="overdue" value="1" @checked(request()->boolean('overdue')) class="rounded border-slate-300">
            Past SLA only
        </label>

        <button type="submit" class="rounded bg-slate-900 px-3 py-1.5 text-sm text-white">Filter</button>
    </form>

    <div class="overflow-x-auto rounded border border-slate-200 bg-white">
        <table class="min-w-full divide-y divide-slate-200 text-sm">
            <thead class="bg-slate-50 text-left text-xs uppercase tracking-wide text-slate-500">
                <tr>
                    <th class="px-4 py-3">Reference</th>
                    <th class="px-4 py-3">Subject</th>
                    <th class="px-4 py-3">Status</th>
                    <th class="px-4 py-3">Priority</th>
                    <th class="px-4 py-3">Assignee</th>
                    <th class="px-4 py-3">SLA due</th>
                </tr>
            </thead>
            <tbody class="divide-y divide-slate-100">
                @forelse ($tickets as $ticket)
                    <tr class="{{ $ticket->isOverdue() ? 'bg-red-50' : '' }}">
                        <td class="px-4 py-3 font-mono text-xs">
                            <a href="{{ route('tickets.show', $ticket) }}" class="text-sky-700 hover:underline">
                                {{ $ticket->reference }}
                            </a>
                        </td>
                        <td class="px-4 py-3">
                            {{ $ticket->subject }}
                            <span class="ml-1 text-xs text-slate-400">({{ $ticket->comments_count }})</span>
                        </td>
                        <td class="px-4 py-3">{{ $ticket->status->label() }}</td>
                        <td class="px-4 py-3">{{ $ticket->priority->label() }}</td>
                        <td class="px-4 py-3 text-slate-500">{{ $ticket->assignee?->name ?? 'Unassigned' }}</td>
                        <td class="px-4 py-3 text-slate-500">
                            {{ $ticket->sla_due_at?->diffForHumans() ?? '—' }}
                        </td>
                    </tr>
                @empty
                    <tr>
                        <td colspan="6" class="px-4 py-8 text-center text-slate-400">No tickets match this filter.</td>
                    </tr>
                @endforelse
            </tbody>
        </table>
    </div>

    <div class="mt-6">{{ $tickets->links() }}</div>
@endsection
