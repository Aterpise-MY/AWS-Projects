<?php

declare(strict_types=1);

namespace App\Http\Controllers;

use App\Http\Requests\StoreAttachmentRequest;
use App\Models\Attachment;
use App\Models\Ticket;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Log;
use Illuminate\Support\Facades\Storage;
use Illuminate\Support\Str;
use RuntimeException;
use Symfony\Component\HttpFoundation\Response;

/**
 * Attachments live in S3 — never on the pod.
 *
 * The container runs with `readOnlyRootFilesystem: true` and only a handful of
 * emptyDir mounts are writable, all of which are wiped when the pod is
 * replaced. A local disk would also mean a file uploaded through web pod A is
 * a 404 when the ALB routes the download to web pod B. `Storage::disk('s3')`
 * is the only correct answer, and it is enforced here rather than left to the
 * FILESYSTEM_DISK env var so a misconfigured ConfigMap cannot silently start
 * writing to the container filesystem.
 */
class AttachmentController extends Controller
{
    /**
     * The one disk this controller is allowed to touch.
     */
    private const DISK = 's3';

    /**
     * POST /tickets/{ticket}/attachments
     */
    public function store(StoreAttachmentRequest $request, Ticket $ticket): Response
    {
        $file = $request->file('file');

        if ($file === null || is_array($file)) {
            throw new RuntimeException('Expected exactly one uploaded file.');
        }

        $original = $file->getClientOriginalName();

        // The client-supplied name is kept only as a display label. The object
        // key is generated so a caller cannot traverse ("../../") or collide
        // with another ticket's objects.
        $key = sprintf(
            'tickets/%s/%s.%s',
            $ticket->reference,
            (string) Str::ulid(),
            $file->getClientOriginalExtension() ?: 'bin',
        );

        // putFileAs streams the temp file into S3 with a multipart upload.
        // Credentials come from the `app` IRSA role via the SDK default
        // provider chain — there are no keys in config/filesystems.php.
        $stored = Storage::disk(self::DISK)->putFileAs(
            dirname($key),
            $file,
            basename($key),
            // Bucket has a full public access block; objects stay private and
            // are served through short-lived pre-signed URLs.
            ['visibility' => 'private']
        );

        if ($stored === false) {
            throw new RuntimeException('Failed to write attachment to S3.');
        }

        $attachment = $ticket->attachments()->create([
            'uploaded_by' => (int) $request->user()?->getKey(),
            'disk' => self::DISK,
            'path' => $stored,
            'filename' => Str::limit($original, 250, ''),
            'size' => $file->getSize() ?: 0,
            'mime_type' => $file->getMimeType() ?? 'application/octet-stream',
        ]);

        Log::info('attachment.stored', [
            'ticket_id' => $ticket->getKey(),
            'attachment_id' => $attachment->getKey(),
            'bytes' => $attachment->size,
        ]);

        if ($request->expectsJson()) {
            return response()->json($attachment, 201);
        }

        return redirect()->route('tickets.show', $ticket)->with('status', 'Attachment uploaded.');
    }

    /**
     * GET /tickets/{ticket}/attachments/{attachment}
     *
     * Redirects to a pre-signed S3 URL instead of streaming the bytes through
     * php-fpm. Streaming a 10 MB download would tie up one of the ten
     * `pm.max_children` slots for the whole transfer.
     */
    public function show(Request $request, Ticket $ticket, Attachment $attachment): Response
    {
        abort_unless($attachment->ticket_id === $ticket->getKey(), 404);

        return redirect()->away($attachment->temporaryUrl(5));
    }

    /**
     * DELETE /tickets/{ticket}/attachments/{attachment}
     */
    public function destroy(Request $request, Ticket $ticket, Attachment $attachment): Response
    {
        abort_unless($attachment->ticket_id === $ticket->getKey(), 404);
        abort_unless(
            $request->user()?->isStaff() === true || $attachment->uploaded_by === $request->user()?->getKey(),
            403,
        );

        // The bucket is versioned with a 7-day noncurrent-version expiry, so
        // this delete is recoverable for a week.
        Storage::disk($attachment->disk)->delete($attachment->path);
        $attachment->delete();

        if ($request->expectsJson()) {
            return response()->json(null, 204);
        }

        return redirect()->route('tickets.show', $ticket)->with('status', 'Attachment deleted.');
    }
}
