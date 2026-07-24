<?php

declare(strict_types=1);

namespace App\Models;

use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;
use Illuminate\Support\Facades\Storage;

/**
 * A file stored on the `s3` disk. `path` is the S3 object key — the bytes never
 * touch the pod filesystem, which is read-only apart from a handful of emptyDir
 * mounts.
 *
 * @property int $id
 * @property int $ticket_id
 * @property int $uploaded_by
 * @property string $disk
 * @property string $path
 * @property string $filename
 * @property int $size
 * @property string $mime_type
 */
class Attachment extends Model
{
    /** @var list<string> */
    protected $fillable = [
        'ticket_id',
        'uploaded_by',
        'disk',
        'path',
        'filename',
        'size',
        'mime_type',
    ];

    /**
     * @return array<string, string>
     */
    protected function casts(): array
    {
        return [
            'size' => 'integer',
        ];
    }

    /**
     * @return BelongsTo<Ticket, $this>
     */
    public function ticket(): BelongsTo
    {
        return $this->belongsTo(Ticket::class);
    }

    /**
     * @return BelongsTo<User, $this>
     */
    public function uploader(): BelongsTo
    {
        return $this->belongsTo(User::class, 'uploaded_by');
    }

    /**
     * Pre-signed URL so the browser downloads straight from S3. The bucket has a
     * full public access block, so this is the only way out.
     */
    public function temporaryUrl(int $minutes = 5): string
    {
        return Storage::disk($this->disk)->temporaryUrl(
            $this->path,
            now()->addMinutes($minutes),
        );
    }

    public function humanSize(): string
    {
        $units = ['B', 'KB', 'MB', 'GB'];
        $size = (float) $this->size;
        $unit = 0;

        while ($size >= 1024 && $unit < count($units) - 1) {
            $size /= 1024;
            $unit++;
        }

        return sprintf('%.1f %s', $size, $units[$unit]);
    }
}
