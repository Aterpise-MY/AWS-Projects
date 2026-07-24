<?php

declare(strict_types=1);

namespace App\Providers;

use Illuminate\Database\Eloquent\Model;
use Illuminate\Support\Facades\URL;
use Illuminate\Support\ServiceProvider;

class AppServiceProvider extends ServiceProvider
{
    public function register(): void
    {
    }

    public function boot(): void
    {
        // The ALB terminates TLS and talks HTTP to the pod. trustProxies picks
        // X-Forwarded-Proto up for requests, but queued jobs and the scheduler
        // have no request to read it from, so mail links would come out as
        // http:// without this.
        if (! $this->app->environment('local', 'testing')) {
            URL::forceScheme('https');
        }

        // Fail loudly in dev when a relation is accessed without eager loading;
        // an N+1 on the ticket list is the difference between one query and
        // sixty against a db.t4g.micro.
        Model::preventLazyLoading(! $this->app->isProduction());
        Model::preventSilentlyDiscardingAttributes(! $this->app->isProduction());
    }
}
