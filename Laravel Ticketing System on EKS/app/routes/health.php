<?php

declare(strict_types=1);

use App\Http\Controllers\HealthController;
use Illuminate\Support\Facades\Route;

/*
|--------------------------------------------------------------------------
| Health routes
|--------------------------------------------------------------------------
|
| Loaded from bootstrap/app.php with an empty middleware stack: no session, no
| CSRF, no rate limiter. Probes hit these every few seconds from kubelet and
| the ALB target group, so they must be cheap and must not mutate state.
|
| Liveness  -> GET /up            (registered by the framework)
| Readiness -> GET /health/ready  (this file)
|
*/

Route::get('/health/ready', [HealthController::class, 'ready'])
    ->name('health.ready');
