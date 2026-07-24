<?php

declare(strict_types=1);

namespace Database\Seeders;

use App\Models\Ticket;
use App\Models\User;
use Illuminate\Database\Seeder;

class DatabaseSeeder extends Seeder
{
    public function run(): void
    {
        $admin = User::factory()->admin()->create([
            'name' => 'Ops Admin',
            'email' => 'admin@example.com',
        ]);

        $agents = User::factory()->agent()->count(3)->create();
        $requesters = User::factory()->count(10)->create();

        Ticket::factory()
            ->count(40)
            ->recycle($requesters)
            ->create()
            ->each(function (Ticket $ticket) use ($agents): void {
                if (fake()->boolean(60)) {
                    $ticket->forceFill(['assignee_id' => $agents->random()->getKey()])->save();
                }
            });

        // A handful already past due so `tickets:escalate-sla --dry-run` has
        // something to report on a fresh database.
        Ticket::factory()->overdue()->count(5)->recycle($requesters)->create();

        $this->command?->info("Seeded. Admin login: {$admin->email} / password");
    }
}
