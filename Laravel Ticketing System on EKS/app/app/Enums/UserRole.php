<?php

declare(strict_types=1);

namespace App\Enums;

enum UserRole: string
{
    case Requester = 'requester';
    case Agent = 'agent';
    case Admin = 'admin';

    /**
     * Agents and admins may be assigned tickets and see every ticket;
     * requesters only see their own.
     */
    public function isStaff(): bool
    {
        return in_array($this, [self::Agent, self::Admin], true);
    }
}
