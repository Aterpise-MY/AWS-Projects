<?php

declare(strict_types=1);

use App\Http\Controllers\AttachmentController;
use App\Http\Controllers\CommentController;
use App\Http\Controllers\TicketController;
use Illuminate\Support\Facades\Route;

/*
|--------------------------------------------------------------------------
| API routes
|--------------------------------------------------------------------------
|
| Prefixed with /api and running the `api` middleware group (stateless, rate
| limited). Same controllers as the web UI — they branch on
| $request->expectsJson().
|
*/

Route::middleware('auth:sanctum')->group(function (): void {
    Route::get('/tickets', [TicketController::class, 'index']);
    Route::post('/tickets', [TicketController::class, 'store']);
    Route::get('/tickets/{ticket}', [TicketController::class, 'show']);
    Route::patch('/tickets/{ticket}', [TicketController::class, 'update']);

    Route::post('/tickets/{ticket}/comments', [CommentController::class, 'store']);
    Route::delete('/tickets/{ticket}/comments/{comment}', [CommentController::class, 'destroy']);

    Route::post('/tickets/{ticket}/attachments', [AttachmentController::class, 'store']);
    Route::delete('/tickets/{ticket}/attachments/{attachment}', [AttachmentController::class, 'destroy']);
});
