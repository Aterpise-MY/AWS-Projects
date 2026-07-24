<?php

declare(strict_types=1);

namespace App\Http\Requests;

use Illuminate\Foundation\Http\FormRequest;
use Illuminate\Validation\Validator;

class StoreCommentRequest extends FormRequest
{
    public function authorize(): bool
    {
        return $this->user() !== null;
    }

    /**
     * @return array<string, mixed>
     */
    public function rules(): array
    {
        return [
            'body' => ['required', 'string', 'min:1', 'max:20000'],
            'parent_id' => ['nullable', 'integer', 'exists:comments,id'],
            'is_internal' => ['nullable', 'boolean'],
        ];
    }

    public function withValidator(Validator $validator): void
    {
        $validator->after(function (Validator $validator): void {
            $parentId = $this->input('parent_id');

            if ($parentId === null) {
                return;
            }

            // A reply must live on the same ticket as its parent, otherwise a
            // crafted parent_id would graft a thread onto someone else's ticket.
            $ticket = $this->route('ticket');
            $parent = \App\Models\Comment::query()->find($parentId);

            if ($parent === null || $ticket === null || $parent->ticket_id !== $ticket->getKey()) {
                $validator->errors()->add('parent_id', 'The parent comment belongs to a different ticket.');
            }
        });
    }
}
