<?php

declare(strict_types=1);

namespace App\Models;

use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;
use Illuminate\Database\Eloquent\Relations\HasMany;

/**
 * Threaded comment. `parent_id` is a self-referencing FK: null means the comment
 * sits at the root of the thread, otherwise it is a reply to another comment on
 * the same ticket.
 *
 * @property int $id
 * @property int $ticket_id
 * @property int $author_id
 * @property int|null $parent_id
 * @property string $body
 * @property bool $is_internal
 */
class Comment extends Model
{
    /** @var list<string> */
    protected $fillable = [
        'ticket_id',
        'author_id',
        'parent_id',
        'body',
        'is_internal',
    ];

    /**
     * @return array<string, string>
     */
    protected function casts(): array
    {
        return [
            'is_internal' => 'boolean',
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
    public function author(): BelongsTo
    {
        return $this->belongsTo(User::class, 'author_id');
    }

    /**
     * @return BelongsTo<Comment, $this>
     */
    public function parent(): BelongsTo
    {
        return $this->belongsTo(self::class, 'parent_id');
    }

    /**
     * Direct replies. Eager-load `replies.replies` for a deeper tree; the UI
     * caps rendering at three levels.
     *
     * @return HasMany<Comment, $this>
     */
    public function replies(): HasMany
    {
        return $this->hasMany(self::class, 'parent_id');
    }
}
