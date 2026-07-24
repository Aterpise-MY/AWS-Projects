<?php

declare(strict_types=1);

use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Redis;
use RuntimeException;

/*
|--------------------------------------------------------------------------
| Readiness probe
|--------------------------------------------------------------------------
|
| A readiness endpoint that returns 200 unconditionally is worse than none at
| all: the ALB keeps a pod in the target group while every request 500s. These
| tests pin the failure behaviour so a future refactor cannot quietly turn the
| probe into a static "ok".
|
*/

function fakeRedisPing(mixed $reply): void
{
    $connection = Mockery::mock();
    $connection->shouldReceive('ping')->andReturn($reply);

    Redis::shouldReceive('connection')->andReturn($connection);
}

it('returns 200 when the database and redis both answer', function (): void {
    fakeRedisPing('+PONG');

    $response = $this->getJson('/health/ready');

    $response->assertOk()
        ->assertJsonPath('status', 'ready')
        ->assertJsonPath('failed', [])
        ->assertJsonPath('checks.database.status', 'ok')
        ->assertJsonPath('checks.redis.status', 'ok');
});

it('returns 503 and names redis when the ping fails', function (): void {
    $connection = Mockery::mock();
    $connection->shouldReceive('ping')->andThrow(new RuntimeException('Connection refused'));
    Redis::shouldReceive('connection')->andReturn($connection);

    $response = $this->getJson('/health/ready');

    $response->assertStatus(503)
        ->assertJsonPath('status', 'unavailable')
        ->assertJsonPath('failed', ['redis'])
        ->assertJsonPath('checks.database.status', 'ok')
        ->assertJsonPath('checks.redis.status', 'error');
});

it('returns 503 and names the database when the query fails', function (): void {
    fakeRedisPing(true);

    DB::shouldReceive('select')
        ->with('select 1')
        ->andThrow(new RuntimeException('SQLSTATE[HY000] [2002] Connection timed out'));

    $this->getJson('/health/ready')
        ->assertStatus(503)
        ->assertJsonPath('failed', ['database'])
        ->assertJsonPath('checks.database.status', 'error');
});

it('is not cacheable and needs no session', function (): void {
    fakeRedisPing(true);

    $response = $this->getJson('/health/ready');

    $response->assertOk();
    expect($response->headers->get('Cache-Control'))->toContain('no-store');

    // The route is registered outside the `web` group, so no session cookie is
    // issued. Probes hitting this every few seconds must not create sessions.
    expect($response->headers->getCookies())->toBeEmpty();
});
