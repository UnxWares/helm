<?php

// JSON routes of the laravel-generic end-to-end test (.github/scripts/laravel-generic-e2e.sh), under /api/e2e.

use App\Jobs\RecordEvent;
use Illuminate\Contracts\Encryption\DecryptException;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\Crypt;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Route;
use Illuminate\Support\Facades\Storage;

Route::prefix('e2e')->group(function () {
    // What serves the request: PHP SAPI (frankenphp or fpm-fcgi), database, stores, migrations that ran, and a hash
    // of APP_KEY (never the key itself).
    Route::get('info', function () {
        $db = DB::connection();

        return [
            'sapi' => PHP_SAPI,
            'php' => PHP_VERSION,
            'laravel' => app()->version(),
            'host' => gethostname(),
            'app_key_sha256' => hash('sha256', (string) config('app.key')),
            'database' => [
                'driver' => $db->getDriverName(),
                'title' => $db->getDriverTitle(),
                'name' => $db->getDatabaseName(),
                'version' => match ($db->getDriverName()) {
                    'sqlite' => $db->scalar('select sqlite_version()'),
                    'pgsql' => $db->scalar('select version()'),
                    default => null,
                },
            ],
            'stores' => [
                'session' => config('session.driver'),
                'cache' => config('cache.default'),
                'queue' => config('queue.default'),
            ],
            'migrations' => DB::table('migrations')->orderBy('id')->pluck('migration'),
        ];
    });

    Route::post('notes', function (Request $request) {
        $body = (string) $request->input('body');
        $id = DB::table('e2e_notes')->insertGetId([
            'body' => $body,
            'secret' => Crypt::encryptString($body),
            'created_at' => now(),
            'updated_at' => now(),
        ]);

        return response()->json(['id' => $id], 201);
    });

    Route::get('notes/{id}', function (string $id) {
        $note = DB::table('e2e_notes')->find((int) $id);
        abort_if($note === null, 404);
        try {
            $secret = Crypt::decryptString($note->secret);
        } catch (DecryptException) {
            $secret = null;
        }

        return ['id' => $note->id, 'body' => $note->body, 'secret' => $secret];
    })->whereNumber('id');

    Route::put('cache/{key}', function (Request $request, string $key) {
        Cache::put("e2e:{$key}", (string) $request->input('value'), 3600);

        return response()->noContent();
    });

    Route::get('cache/{key}', fn (string $key) => ['value' => Cache::get("e2e:{$key}")]);

    Route::post('jobs', function (Request $request) {
        $token = (string) $request->input('token');
        RecordEvent::dispatch($token);

        return response()->json(['queued' => $token], 202);
    });

    Route::get('events', fn (Request $request) => DB::table('e2e_events')
        ->when($request->query('kind'), fn ($query, $kind) => $query->where('kind', $kind))
        ->when($request->query('token'), fn ($query, $token) => $query->where('token', $token))
        ->orderBy('id')
        ->get());

    // The file the job wrote on the local disk (storage/app/private); the one of the public disk is served by the
    // web server from public/storage.
    Route::get('files/{token}', fn (string $token) => [
        'local' => Storage::disk('local')->get("e2e/{$token}.txt"),
    ]);
});
