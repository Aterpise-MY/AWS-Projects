<!DOCTYPE html>
<html lang="{{ str_replace('_', '-', app()->getLocale()) }}" class="h-full bg-slate-50">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="csrf-token" content="{{ csrf_token() }}">
    <title>@yield('title', 'Tickets') &middot; {{ config('app.name') }}</title>
    @vite(['resources/css/app.css', 'resources/js/app.js'])
</head>
<body class="h-full text-slate-800 antialiased">
    <header class="border-b border-slate-200 bg-white">
        <div class="mx-auto flex max-w-5xl items-center justify-between px-4 py-4">
            <a href="{{ route('tickets.index') }}" class="text-lg font-semibold">{{ config('app.name') }}</a>
            <nav class="flex items-center gap-4 text-sm">
                <a href="{{ route('tickets.index') }}" class="hover:underline">All tickets</a>
                <a href="{{ route('tickets.create') }}" class="rounded bg-slate-900 px-3 py-1.5 text-white">New ticket</a>
                <span class="text-slate-500">{{ auth()->user()?->name }}</span>
            </nav>
        </div>
    </header>

    <main class="mx-auto max-w-5xl px-4 py-8">
        @if (session('status'))
            <div class="mb-6 rounded border border-emerald-200 bg-emerald-50 px-4 py-3 text-sm text-emerald-800">
                {{ session('status') }}
            </div>
        @endif

        @if ($errors->any())
            <div class="mb-6 rounded border border-red-200 bg-red-50 px-4 py-3 text-sm text-red-800">
                <ul class="list-disc pl-5">
                    @foreach ($errors->all() as $error)
                        <li>{{ $error }}</li>
                    @endforeach
                </ul>
            </div>
        @endif

        @yield('content')
    </main>

    <footer class="mx-auto max-w-5xl px-4 py-8 text-xs text-slate-400">
        {{-- Useful when a bug only reproduces on one replica. --}}
        pod {{ gethostname() }}
    </footer>
</body>
</html>
