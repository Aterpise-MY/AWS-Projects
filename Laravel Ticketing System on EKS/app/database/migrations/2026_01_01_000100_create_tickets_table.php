<?php

declare(strict_types=1);

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::create('tickets', function (Blueprint $table): void {
            $table->id();
            // Human-facing handle, e.g. TCK-000042. Written in a second UPDATE
            // inside the create transaction because it is derived from the
            // auto-increment id; sized for the temporary placeholder value too.
            $table->string('reference', 24)->unique();
            $table->string('subject', 255);
            $table->text('body');
            $table->enum('status', ['open', 'in_progress', 'resolved', 'closed'])->default('open');
            $table->enum('priority', ['low', 'normal', 'high', 'urgent'])->default('normal');

            $table->foreignId('requester_id')->constrained('users')->cascadeOnDelete();
            $table->foreignId('assignee_id')->nullable()->constrained('users')->nullOnDelete();

            $table->timestamp('sla_due_at')->nullable();
            $table->timestamp('escalated_at')->nullable();
            $table->timestamp('resolved_at')->nullable();
            $table->timestamps();

            // EscalateSlaBreaches runs every 15 minutes and scans
            // "open states where sla_due_at <= now". Without this composite
            // index that is a full table scan four times an hour.
            $table->index(['status', 'sla_due_at'], 'tickets_status_sla_due_at_index');
            $table->index(['assignee_id', 'status']);
            $table->index(['requester_id', 'created_at']);
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('tickets');
    }
};
