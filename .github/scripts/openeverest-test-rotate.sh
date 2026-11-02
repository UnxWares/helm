#!/usr/bin/env bash
# Second pass of the openeverest-database-tools end-to-end test: give the application users new passwords and delete
# the finished Jobs, so that the next `helm upgrade` runs them again on databases and users that already exist.
#
# usage: openeverest-test-rotate.sh
set -euo pipefail

NS=everest-databases
for name in laravel-app-db wordpress-db appdb-user; do
  password=$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | head -c 24)"'\"\\;"
  kubectl -n "$NS" patch secret "$name" --type=merge \
    -p "$(jq -n --arg p "$password" '{stringData: {password: $p}}')" >/dev/null
  echo "new password for $name"
done
kubectl -n "$NS" delete jobs --all
