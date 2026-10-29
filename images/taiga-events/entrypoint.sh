#!/bin/sh
# Same environment as taigaio/taiga-events (RABBITMQ_USER, RABBITMQ_PASS, TAIGA_EVENTS_RABBITMQ_HOST,
# TAIGA_SECRET_KEY, or RABBITMQ_URL and SECRET directly). The settings are exported instead of being
# written to a .env file, so the root filesystem can stay read-only.
set -eu

: "${TAIGA_EVENTS_RABBITMQ_HOST:=taiga-events-rabbitmq}"
# taiga-events appends "?heartbeat=60" to the URL: the trailing "#" turns it into a fragment, so that
# frameMax (RabbitMQ 4.1+ refuses frames below 8192 bytes) and heartbeat are kept as query parameters.
export RABBITMQ_URL="${RABBITMQ_URL:-amqp://${RABBITMQ_USER:-}:${RABBITMQ_PASS:-}@${TAIGA_EVENTS_RABBITMQ_HOST}:5672/taiga?frameMax=131072&heartbeat=60#}"
export SECRET="${SECRET:-${TAIGA_SECRET_KEY:-}}"
export WEB_SOCKET_SERVER_PORT="${WEB_SOCKET_SERVER_PORT:-8888}"
export APP_PORT="${APP_PORT:-3023}"
export NODE_ENV=production

echo "Starting Taiga events"
exec node /taiga-events/src/index.js "$@"
