<?php

use Illuminate\Http\Request;
use Illuminate\Support\Facades\Route;

Route::get('/', function () {
    return view('welcome');
});

// A counter kept in the session (database store by default, behind the encrypted session cookie), rendered by a
// Blade view (compiled into storage/framework/views).
Route::get('/e2e/session', function (Request $request) {
    $count = $request->session()->get('e2e-count', 0) + 1;
    $request->session()->put('e2e-count', $count);

    return view('e2e', ['count' => $count]);
});
