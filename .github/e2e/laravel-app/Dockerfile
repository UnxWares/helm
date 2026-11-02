# Laravel test application of the laravel-generic end-to-end test (.github/workflows/e2e.yaml). Built in CI only and
# never published: it is not one of the images of images/.
#
# - the laravel/laravel skeleton at the commit of its v13.11.0 release, checked against the SHA-256 of the archive;
# - the dependencies of composer.lock, without the dev packages. composer.json is the `require` of the skeleton,
#   resolved for PHP 8.5 (config.platform.php): after changing it or LARAVEL_COMMIT, regenerate the lock with
#   `composer update --no-install` (the build fails while it is out of date);
# - the files of this directory on top of the skeleton: routes, a queued job, a scheduled task, a migration and a
#   static file, that .github/scripts/laravel-generic-e2e.sh uses to check what the chart deploys.
#
# One target per runtime of the chart, both following the image contract of charts/laravel-generic (README,
# "Requirements for your image"): WORKDIR is the application directory, files belong to root and are world-readable
# (the chart runs them as uid 33), nothing is written outside the writable paths of the chart, /bin/sh and cp exist.
#   frankenphp: the official FrankenPHP image, application in /app (the default appPath of the chart);
#   fpm:        the official PHP-FPM Alpine image, application in /var/www/html, behind the nginx sidecar of the chart.
# Both add pdo_pgsql (PostgreSQL release) and pcntl (queue:work finishes the current job on SIGTERM).
#
#   docker build --target frankenphp --tag local/laravel-generic-e2e:frankenphp .github/e2e/laravel-app
#   docker build --target fpm --tag local/laravel-generic-e2e:fpm .github/e2e/laravel-app

FROM docker.io/library/composer:2.11.1@sha256:537fb03057ed901ae06bde7ef25af348903485ae1acc7fc789b80d8bac666f35 AS app
# laravel/laravel v13.11.0
ARG LARAVEL_COMMIT=06d016a364a37430eec9cbc52209adce3d7667ce
ARG LARAVEL_SHA256=0a9c0e0bb361499c08daabcecfc0aab1034e9dae58ecd421230eb4dc2cc27d0b
WORKDIR /src
RUN set -eux; \
    curl -fsSL -o /tmp/laravel.tar.gz "https://github.com/laravel/laravel/archive/${LARAVEL_COMMIT}.tar.gz"; \
    echo "${LARAVEL_SHA256}  /tmp/laravel.tar.gz" > /tmp/laravel.tar.gz.sha256; \
    sha256sum -c /tmp/laravel.tar.gz.sha256; \
    tar -xzf /tmp/laravel.tar.gz --strip-components=1 --no-same-owner
COPY composer.json composer.lock ./
# The packages are downloaded through the GitHub API, which allows 60 anonymous requests an hour for more than 70
# packages: CI passes its token (docker build --secret id=github_token,env=GITHUB_TOKEN). The secret is mounted for
# this step only and stays out of the layers; a local build can do without it.
RUN --mount=type=secret,id=github_token \
    set -eu; \
    if [ -s /run/secrets/github_token ]; then \
        COMPOSER_AUTH=$(printf '{"github-oauth": {"github.com": "%s"}}' "$(cat /run/secrets/github_token)"); \
        export COMPOSER_AUTH; \
    fi; \
    composer validate --no-check-publish; \
    composer install --no-dev --no-scripts --no-autoloader --no-interaction --no-progress
COPY app/ app/
COPY bootstrap/app.php bootstrap/app.php
COPY database/ database/
COPY public/ public/
COPY resources/ resources/
COPY routes/ routes/
# Optimized autoloader, then bootstrap/cache/packages.php (package:discover, run by the post-autoload-dump script).
RUN composer dump-autoload --no-dev --classmap-authoritative --no-interaction

FROM docker.io/dunglas/frankenphp:1.13.4-php8.5.12-trixie@sha256:6f86f003f1478bafa7befe6ec26db5575e703882171f785189de1e222df0e38e AS frankenphp
RUN install-php-extensions pcntl pdo_pgsql
COPY --from=app /src /app
# public/storage -> /app/storage/app/public (the public disk, on the persistent volume of the chart).
RUN php artisan storage:link

FROM docker.io/library/php:8.5.12-fpm-alpine3.24@sha256:4c2818074ec49f6abe46620f3965e0cb75bc3a5f2b417edd1aacaba6f091c40e AS fpm
# The Alpine packages come from the repository of the pinned base image: older versions are dropped from it, so they
# are not pinned.
# hadolint ignore=DL3018
RUN set -eux; \
    apk add --no-cache libpq; \
    apk add --no-cache --virtual .pgsql-build-deps libpq-dev; \
    docker-php-ext-install -j"$(nproc)" pcntl pdo_pgsql; \
    apk del --no-network .pgsql-build-deps
COPY --from=app /src /var/www/html
# public/storage -> /var/www/html/storage/app/public (the public disk, on the persistent volume of the chart).
RUN php artisan storage:link
