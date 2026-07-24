<?php

declare(strict_types=1);

namespace App\Http\Controllers;

use Illuminate\Http\JsonResponse;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Redis;
use Throwable;

/**
 * Readiness probe.
 *
 * Liveness is Laravel 11's built-in `/up` route (configured in
 * bootstrap/app.php) — it answers as long as the framework booted, which is
 * exactly the right question for "should kubelet restart this container".
 * Restarting a pod because RDS is unreachable helps nobody.
 *
 * Readiness is a different question: "should the ALB send this pod traffic".
 * A pod that cannot reach MySQL or Redis can only serve 500s, so it must fall
 * out of the target group until the dependency recovers. Hence this endpoint
 * really connects to both.
 */
class HealthController extends Controller
{
    /**
     * GET /health/ready
     *
     * 200 when both dependencies answer, 503 otherwise, with the failing
     * dependency named in the body so the on-call engineer does not have to
     * exec into the pod to find out which one broke.
     */
    public function ready(): JsonResponse
    {
        $checks = [
            'database' => $this->checkDatabase(),
            'redis' => $this->checkRedis(),
        ];

        $failed = array_keys(array_filter(
            $checks,
            static fn (array $check): bool => $check['status'] !== 'ok',
        ));

        $healthy = $failed === [];

        return response()->json([
            'status' => $healthy ? 'ready' : 'unavailable',
            'failed' => $failed,
            'checks' => $checks,
            'timestamp' => now()->toIso8601String(),
        ], $healthy ? 200 : 503, [
            // Probes must never be answered from a cache, and the ALB should
            // not store this either.
            'Cache-Control' => 'no-store, max-age=0',
        ]);
    }

    /**
     * @return array{status: string, latency_ms?: float, error?: string}
     */
    private function checkDatabase(): array
    {
        $start = microtime(true);

        try {
            DB::select('select 1');

            return [
                'status' => 'ok',
                'latency_ms' => $this->elapsed($start),
            ];
        } catch (Throwable $e) {
            return [
                'status' => 'error',
                'latency_ms' => $this->elapsed($start),
                'error' => $this->summarise($e),
            ];
        }
    }

    /**
     * @return array{status: string, latency_ms?: float, error?: string}
     */
    private function checkRedis(): array
    {
        $start = microtime(true);

        try {
            // Default connection = cache (DB 0). One node backs all three
            // logical DBs, so a single PING is a sufficient liveness signal
            // for sessions and the queue as well.
            $pong = Redis::connection()->ping();

            // phpredis returns true (or "+PONG" on some builds), predis returns
            // a Status object that stringifies to "PONG". Normalise both.
            $ok = $pong === true
                || (is_string($pong) && str_contains(strtoupper($pong), 'PONG'))
                || (is_object($pong) && str_contains(strtoupper((string) $pong), 'PONG'));

            return $ok
                ? ['status' => 'ok', 'latency_ms' => $this->elapsed($start)]
                : ['status' => 'error', 'latency_ms' => $this->elapsed($start), 'error' => 'unexpected PING reply'];
        } catch (Throwable $e) {
            return [
                'status' => 'error',
                'latency_ms' => $this->elapsed($start),
                'error' => $this->summarise($e),
            ];
        }
    }

    private function elapsed(float $start): float
    {
        return round((microtime(true) - $start) * 1000, 2);
    }

    /**
     * Exception messages from PDO and phpredis can contain the host, the user
     * and occasionally the DSN. The probe body is reachable from inside the
     * cluster, so trim it to the class name plus a short message.
     */
    private function summarise(Throwable $e): string
    {
        return sprintf('%s: %s', class_basename($e), mb_substr($e->getMessage(), 0, 120));
    }
}
