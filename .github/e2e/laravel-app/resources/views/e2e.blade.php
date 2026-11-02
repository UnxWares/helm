<!DOCTYPE html>
<html lang="en">
    <head>
        <meta charset="utf-8">
        <title>{{ config('app.name') }} end-to-end test</title>
    </head>
    <body>
        <p>Requests in this session: <span data-count="{{ $count }}">{{ $count }}</span></p>
    </body>
</html>
