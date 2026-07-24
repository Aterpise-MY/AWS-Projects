<?php

declare(strict_types=1);

namespace App\Models;

use App\Enums\TicketPriority;
use App\Enums\TicketStatus;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Database\Eloquent\Factories\HasFactory;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;
use Illuminate\Database\Eloquent\Relations\HasMany;
use Illuminate\Support\Carbon;

/**
 * @property int $id
 * @property string $reference
 * @property string $subject
 * @property string $body
 * @property TicketStatus $status
 * @property TicketPriority $priority
 * @property int $requester_id
 * @property int|null $assignee_id
 * @property Carbon|null $sla_due_at
 * @property Carbon|null $escalated_at
 * @property Carbon|null $resolved_at
 */
class Ticket extends Model
{
    /** @use HasFactory<\Database\Factories\TicketFactory> */
    use HasFactory;

    /** @var list<string> */
    protected $fillable = [
        'reference',
        'subject',
        'body',
        'status',
        'priority',
        'requester_id',
        'assignee_id',
        'sla_due_at',
        'escalated_at',
        'resolved_at',
    ];

    /**
     * @return array<string, string>
     */
    protected function casts(): array
    {
        return [
            'status' => TicketStatus::class,
            'priority' => TicketPriority::class,
            'sla_due_at' => 'datetime',
            'escalated_at' => 'datetime',
            'resolved_at' => 'datetime',
        ];
    }

    /**
     * @return BelongsTo<User, $this>
     */
    public function requester(): BelongsTo
    {
        return $this->belongsTo(User::class, 'requester_id');
    }

    /**
     * @return BelongsTo<User, $this>
     */
    public function assignee(): BelongsTo
    {
        return $this->belongsTo(User::class, 'assignee_id');
    }

    /**
     * Every comment on the ticket, flat. Use `rootComments` for the tree.
     *
     * @return HasMany<Comment, $this>
     */
    public function comments(): HasMany
    {
        return $this->hasMany(Comment::class);
    }

    /**
     * Top-level comments only; each one carries its own `replies`.
     *
     * @return HasMany<Comment, $this>
     */
    public function rootComments(): HasMany
    {
        return $this->hasMany(Comment::class)->whereNull('parent_id');
    }

    /**
     * @return HasMany<Attachment, $this>
     */
    public function attachments(): HasMany
    {
        return $this->hasMany(Attachment::class);
    }

    /**
     * Tickets that are still open and whose SLA deadline has passed.
     *
     * @param  Builder<Ticket>  $query
     * @return Builder<Ticket>
     */
    public function scopeBreachingSla(Builder $query, ?Carbon $now = null): Builder
    {
        return $query
            ->whereIn('status', array_column(TicketStatus::openStates(), 'value'))
            ->whereNotNull('sla_due_at')
            ->where('sla_due_at', '<=', $now ?? now());
    }

    public function isOverdue(?Carbon $now = null): bool
    {
        if ($this->sla_due_at === null || $this->status->isTerminal()) {
            return false;
        }

        return $this->sla_due_at->lessThanOrEqualTo($now ?? now());
    }
}
