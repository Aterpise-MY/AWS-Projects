<?php

declare(strict_types=1);

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::create('attachments', function (Blueprint $table): void {
            $table->id();
            $table->foreignId('ticket_id')->constrained()->cascadeOnDelete();
            $table->foreignId('uploaded_by')->constrained('users')->cascadeOnDelete();

            // Which Laravel disk the object lives on. Always `s3` in the
            // cluster; the column exists so a future migration to a different
            // bucket or disk name does not orphan old rows.
            $table->string('disk', 32)->default('s3');

            // S3 object key, e.g. tickets/TCK-0001/9f3c.../screenshot.png
            $table->string('path', 512);
            $table->string('filename', 255);
            $table->unsignedBigInteger('size');
            $table->string('mime_type', 127);
            $table->timestamps();

            $table->index('ticket_id');
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('attachments');
    }
};
