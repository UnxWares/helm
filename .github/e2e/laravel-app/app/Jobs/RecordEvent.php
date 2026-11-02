<?php

namespace App\Jobs;

use Illuminate\Contracts\Queue\ShouldQueue;
use Illuminate\Foundation\Queue\Queueable;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Storage;

/**
 * Queued by POST /api/e2e/jobs, run by a queue worker pod: writes a file on the local and the public disks
 * (storage/app, on the persistent volume of the chart) and records which pod ran it, with the cache value the web
 * pod stored for the same token.
 */
class RecordEvent implements ShouldQueue
{
    use Queueable;

    public function __construct(public string $token)
    {
    }

    public function handle(): void
    {
        Storage::disk('local')->put("e2e/{$this->token}.txt", 'written by '.gethostname());
        Storage::disk('public')->put("e2e/{$this->token}.txt", $this->token);

        self::record('job', $this->token, Cache::get("e2e:{$this->token}"));
    }

    /**
     * Records an event of the test (migration, job, schedule) with the pod that produced it and a hash of its
     * APP_KEY (never the key itself).
     */
    public static function record(string $kind, ?string $token = null, ?string $detail = null): void
    {
        DB::table('e2e_events')->insert([
            'kind' => $kind,
            'token' => $token,
            'host' => gethostname(),
            'app_key_sha256' => hash('sha256', (string) config('app.key')),
            'detail' => $detail,
            'created_at' => now(),
        ]);
    }
}
