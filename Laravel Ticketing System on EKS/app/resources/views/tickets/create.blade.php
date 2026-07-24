@extends('layouts.app')

@section('title', 'New ticket')

@section('content')
    <h1 class="mb-6 text-xl font-semibold">Open a ticket</h1>

    <form method="POST" action="{{ route('tickets.store') }}" class="max-w-2xl space-y-5">
        @csrf

        <label class="block">
            <span class="text-sm text-slate-600">Subject</span>
            <input type="text" name="subject" value="{{ old('subject') }}" required minlength="5" maxlength="255"
                   class="mt-1 block w-full rounded border-slate-300">
        </label>

        <label class="block">
            <span class="text-sm text-slate-600">Description</span>
            <textarea name="body" rows="8" required minlength="10"
                      class="mt-1 block w-full rounded border-slate-300">{{ old('body') }}</textarea>
        </label>

        <label class="block max-w-xs">
            <span class="text-sm text-slate-600">Priority</span>
            <select name="priority" class="mt-1 block w-full rounded border-slate-300">
                @foreach ($priorities as $priority)
                    <option value="{{ $priority->value }}" @selected(old('priority', 'normal') === $priority->value)>
                        {{ $priority->label() }} — {{ $priority->slaHours() }}h SLA
                    </option>
                @endforeach
            </select>
        </label>

        <button type="submit" class="rounded bg-slate-900 px-4 py-2 text-sm text-white">Create ticket</button>
    </form>
@endsection
