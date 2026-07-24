<?php

declare(strict_types=1);

use App\Models\Ticket;
use App\Models\User;
use Illuminate\Http\UploadedFile;
use Illuminate\Support\Facades\Storage;

/*
| The container root filesystem is read-only and pods are replaced on every
| rollout, so an attachment written to local disk is both a crash and a data
| loss. Assert the S3 disk explicitly.
*/

it('writes uploads to the s3 disk and never to local', function (): void {
    Storage::fake('s3');
    Storage::fake('local');

    $user = User::factory()->create();
    $ticket = Ticket::factory()->create(['requester_id' => $user->id]);

    $response = $this->actingAs($user)->postJson(
        "/tickets/{$ticket->id}/attachments",
        ['file' => UploadedFile::fake()->image('screenshot.png', 640, 480)],
    );

    $response->assertCreated();

    $attachment = $ticket->attachments()->sole();

    expect($attachment->disk)->toBe('s3')
        ->and($attachment->path)->toStartWith("tickets/{$ticket->reference}/")
        ->and($attachment->filename)->toBe('screenshot.png');

    Storage::disk('s3')->assertExists($attachment->path);
    Storage::disk('local')->assertDirectoryEmpty('/');
});

it('rejects a file above the size limit', function (): void {
    Storage::fake('s3');

    $user = User::factory()->create();
    $ticket = Ticket::factory()->create(['requester_id' => $user->id]);

    $this->actingAs($user)
        ->postJson("/tickets/{$ticket->id}/attachments", [
            'file' => UploadedFile::fake()->create('huge.pdf', 20480, 'application/pdf'),
        ])
        ->assertStatus(422)
        ->assertJsonValidationErrors('file');

    expect($ticket->attachments()->count())->toBe(0);
});
