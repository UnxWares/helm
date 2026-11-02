<?php

use App\Jobs\RecordEvent;
use Illuminate\Foundation\Inspiring;
use Illuminate\Support\Facades\Artisan;
use Illuminate\Support\Facades\Schedule;

Artisan::command('inspire', function () {
    $this->comment(Inspiring::quote());
})->purpose('Display an inspiring quote');

// Recorded by the scheduler of the chart (the CronJob running schedule:run, or the schedule:work Deployment).
Schedule::call(fn () => RecordEvent::record('schedule'))->name('e2e-schedule')->everyMinute();
