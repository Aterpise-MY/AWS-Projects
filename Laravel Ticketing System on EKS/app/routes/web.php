<?php

declare(strict_types=1);

use App\Http\Controllers\AttachmentController;
use App\Http\Controllers\CommentController;
use App\Http\Controllers\TicketController;
use Illuminate\Support\Facades\Route;

Route::redirect('/', '/tickets');

Route::middleware('auth')->group(function (): void {
    Route::get('/tickets', [TicketController::class, 'index'])->name('tickets.index');
    Route::get('/tickets/create', [TicketController::class, 'create'])->name('tickets.create');
    Route::post('/tickets', [TicketController::class, 'store'])->name('tickets.store');
    Route::get('/tickets/{ticket}', [TicketController::class, 'show'])->name('tickets.show');
    Route::patch('/tickets/{ticket}', [TicketController::class, 'update'])->name('tickets.update');

    Route::post('/tickets/{ticket}/comments', [CommentController::class, 'store'])
        ->name('tickets.comments.store');
    Route::delete('/tickets/{ticket}/comments/{comment}', [CommentController::class, 'destroy'])
        ->name('tickets.comments.destroy');

    Route::post('/tickets/{ticket}/attachments', [AttachmentController::class, 'store'])
        ->name('tickets.attachments.store');
    Route::get('/tickets/{ticket}/attachments/{attachment}', [AttachmentController::class, 'show'])
        ->name('tickets.attachments.show');
    Route::delete('/tickets/{ticket}/attachments/{attachment}', [AttachmentController::class, 'destroy'])
        ->name('tickets.attachments.destroy');
});
