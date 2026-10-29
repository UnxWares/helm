#!/bin/sh
# Same Celery worker (with beat) as the taigaio/taiga-back async entrypoint, without chown and gosu. The
# beat schedule goes to /tmp, so the root filesystem can stay read-only. Extra arguments go to Celery.
set -eu

echo "Starting Celery..."
exec celery -A taiga.celery worker -B \
    --concurrency 4 \
    --schedule /tmp/celerybeat-schedule \
    -l INFO \
    "$@"
