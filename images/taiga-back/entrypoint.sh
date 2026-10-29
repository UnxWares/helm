#!/bin/sh
# Same steps as the taigaio/taiga-back entrypoint, without chown and gosu: the image already runs as a
# non-root user. Extra arguments go to gunicorn.
set -eu

echo "Executing pending migrations"
python manage.py migrate
echo "Load default templates"
python manage.py loaddata initial_project_templates
echo "Starting Taiga API..."
exec gunicorn taiga.wsgi:application \
    --name taiga_api \
    --bind 0.0.0.0:8000 \
    --workers 3 \
    --worker-tmp-dir /dev/shm \
    --log-level=info \
    --access-logfile - \
    "$@"
