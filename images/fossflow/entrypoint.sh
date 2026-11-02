#!/bin/sh
# FossFLOW in one container, without root and with a read-only root filesystem: nginx serves the web app on port
# 8080 and proxies /api/ to the storage backend, which only listens on 127.0.0.1:3001 and is started when
# ENABLE_SERVER_STORAGE=true (the default). The container stops when the backend exits, so that Kubernetes restarts
# it (a dead nginx fails the probes); SIGTERM stops both gracefully.
set -eu

# The upstream image builds an htpasswd file from these with `openssl passwd -bcrypt`, which OpenSSL 3 removed.
# Refuse them rather than start without the protection they ask for.
if [ -n "${HTTP_AUTH_USER:-}${HTTP_AUTH_PASSWORD:-}" ]; then
    echo "HTTP_AUTH_USER and HTTP_AUTH_PASSWORD are not supported by this image:" \
        "put authentication in front of FossFLOW (ingress, SSO proxy)" >&2
    exit 1
fi

# The nginx pid and temporary files, the only writes outside the storage directory.
mkdir -p /tmp/nginx

if [ "${ENABLE_SERVER_STORAGE:-true}" != true ]; then
    echo "Server storage disabled: diagrams stay in the browser, backend not started"
    exec nginx -e stderr -g 'daemon off;'
fi

nginx -e stderr -g 'daemon off;' &
web=$!
cd /app/packages/fossflow-backend
node server.js &
backend=$!
trap 'kill -QUIT "$web" 2>/dev/null || true; kill -TERM "$backend" 2>/dev/null || true' TERM INT

status=0
wait "$backend" || status=$?
kill -QUIT "$web" 2>/dev/null || true
wait || true
exit "$status"
