<?php

declare(strict_types=1);

namespace App\Http\Requests;

use Illuminate\Foundation\Http\FormRequest;

class StoreAttachmentRequest extends FormRequest
{
    public function authorize(): bool
    {
        return $this->user() !== null;
    }

    /**
     * `max` is in kilobytes. 10 MB here must stay at or below the smallest of
     * php.ini `upload_max_filesize` / `post_max_size` and the nginx
     * `client_max_body_size`, otherwise the request dies before Laravel ever
     * validates it and the user sees a raw 413.
     *
     * @return array<string, mixed>
     */
    public function rules(): array
    {
        return [
            'file' => [
                'required',
                'file',
                'max:10240',
                'mimetypes:image/png,image/jpeg,image/gif,image/webp,application/pdf,text/plain,text/csv,application/zip',
            ],
        ];
    }
}
