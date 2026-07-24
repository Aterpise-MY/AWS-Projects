<?php

declare(strict_types=1);

use Illuminate\Foundation\Application;
use Illuminate\Foundation\Configuration\Exceptions;
use Illuminate\Foundation\Configuration\Middleware;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Route;

return Application::configure(basePath: dirname(__DIR__))
    ->withRouting(
        web: __DIR__.'/../routes/web.php',
        api: __DIR__.'/../routes/api.php',
        commands: __DIR__.'/../routes/console.php',
        // Laravel 11 ships a liveness endpoint. `/up` boots the framework and
        // fires DiagnosingHealth, nothing more — exactly what kubelet should
        // use to decide whether to restart the container. Readiness is a
        // separate, dependency-checking route (see routes/health.php).
        health: '/up',
        then: function (): void {
            // Deliberately no middleware group. If the probe ran through `web`
            // it would start a session on every request, and with a 10-second
            // readiness period across four pods that is ~34,000 junk session
            // keys a day in Redis DB 1. It also must not be rate limited.
            Route::middleware([])
                ->group(base_path('routes/health.php'));
        },
    )
    ->withMiddleware(function (Middleware $middleware): void {
        // Pods sit behind an internet-facing ALB in a private subnet. The ALB's
        // node IPs are dynamic and not knowable at deploy time, so the proxy
        // list cannot be enumerated. Trusting all proxies is safe here because
        // the pod's only ingress is the ALB target group — nothing else can
        // reach port 8080 — so no client can forge X-Forwarded-For.
        // Without this, url() generates http:// links behind an HTTPS
        // listener and every redirect downgrades the scheme.
        $middleware->trustProxies(at: '*');

        $middleware->trustHosts(at: static fn (): array => [
            parse_url((string) config('app.url'), PHP_URL_HOST) ?: 'localhost',
        ], subdomains: true);

        // The ALB health checker and the API clients do not carry a CSRF token.
        $middleware->validateCsrfTokens(except: [
            'api/*',
        ]);
    })
    ->withExceptions(function (Exceptions $exceptions): void {
        // Structured JSON on stderr is what Fluent Bit ships to CloudWatch;
        // adding the request id makes a 500 traceable back to an ALB access
        // log line.
        $exceptions->context(static fn (): array => [
            'request_id' => request()->headers->get('X-Amzn-Trace-Id'),
            'pod' => gethostname(),
        ]);

        $exceptions->shouldRenderJsonWhen(
            static fn (Request $request): bool => $request->is('api/*') || $request->expectsJson()
        );
    })
    ->create();
