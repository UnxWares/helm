<?php

use App\Jobs\RecordEvent;
use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        // Notes written and read back through the web pod, with an encrypted copy (APP_KEY).
        Schema::create('e2e_notes', function (Blueprint $table) {
            $table->id();
            $table->text('body');
            $table->text('secret');
            $table->timestamps();
        });

        // What ran where: the migrations, the queued jobs and the scheduled task.
        Schema::create('e2e_events', function (Blueprint $table) {
            $table->id();
            $table->string('kind');
            $table->string('token')->nullable();
            $table->string('host');
            $table->string('app_key_sha256', 64);
            $table->text('detail')->nullable();
            $table->timestamp('created_at')->nullable();
        });

        // The pod running the migrations: the hook Job, or with SQLite the init container of the web pod.
        RecordEvent::record('migration');
    }

    public function down(): void
    {
        Schema::dropIfExists('e2e_events');
        Schema::dropIfExists('e2e_notes');
    }
};
