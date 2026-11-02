#!/usr/bin/env bash
# shellcheck disable=SC2016 # the $names in single quotes are jq variables
# End-to-end check of a fresh kener release, through its Service: the first account signs up (and only the first
# one), logs in, creates an API key, creates an HTTP monitor through the REST API and puts it on a status page;
# the monitor then runs from the background queue (bundled Valkey) and the status page and badge show it UP. Also
# checks that the API refuses requests without a valid key, that Valkey refuses commands without its password and,
# when the release has NetworkPolicies, that another pod reaches Kener but not Valkey.
#
# Run it again with "after-reinstall" once the release was uninstalled and installed again: the account, the API key
# and the monitor must have survived (kept PVC and Secret).
#
# usage: kener-e2e.sh <namespace> <release> [after-reinstall]
set -euo pipefail

NAMESPACE=$1
RELEASE=$2
PHASE=${3:-first}
PORT=15214
# Scratch files stay in a fresh temporary directory: nothing is deleted.
WORK=$(mktemp -d)
JAR=$WORK/cookies
cleanup() {
  [ -n "${FORWARD_PID:-}" ] && kill "$FORWARD_PID" 2>/dev/null
  [ -n "${PROBE:-}" ] && kubectl -n "$NAMESPACE" delete pod "$PROBE" --wait=false >/dev/null 2>&1
  true
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }
k() { kubectl -n "$NAMESPACE" "$@"; }
component() { # kind, component: name of the release's resource
  k get "$1" -l "app.kubernetes.io/instance=$RELEASE,app.kubernetes.io/component=$2" -o jsonpath='{.items[0].metadata.name}'
}
kener=$(component deploy web)
env_of() { k get deploy "$kener" -o jsonpath="{.spec.template.spec.containers[0].env[?(@.name==\"$1\")].value}"; }
# SvelteKit refuses form posts whose Origin is not ORIGIN; the base path is compiled into the image.
ORIGIN=$(env_of ORIGIN)
BASE="http://127.0.0.1:$PORT$(env_of KENER_BASE_PATH)"
# Form action of the sign-in page, answered in JSON like the web application does.
form() { # action, then name=value fields
  local action=$1 field fields=()
  shift
  for field in "$@"; do fields+=(--data-urlencode "$field"); done
  curl -sS -b "$JAR" -c "$JAR" -H "Origin: $ORIGIN" -H 'accept: application/json' "${fields[@]}" \
    "$BASE/account/signin?/$action"
}
api() { # method, path, [JSON body]: REST API with the key
  curl -sS -X "$1" -H "authorization: Bearer $KEY" -H 'content-type: application/json' ${3:+--data "$3"} \
    -w '\n%{http_code}' "$BASE/api/v4$2"
}
expect_status() { # expected status, description; reads "body\nstatus" on stdin, prints the body
  local out status
  out=$(cat)
  status=${out##*$'\n'}
  [ "$status" = "$1" ] || fail "$2: HTTP $status, expected $1: ${out%$'\n'*}"
  printf '%s\n' "${out%$'\n'*}"
}

service=$(component svc web)
service_port=$(k get svc "$service" -o jsonpath='{.spec.ports[0].port}')
kubectl -n "$NAMESPACE" port-forward "svc/$service" "$PORT:$service_port" >"$WORK/forward.log" 2>&1 &
FORWARD_PID=$!
for _ in $(seq 60); do
  curl -sf "$BASE/healthcheck" >/dev/null && break
  sleep 1
done
kill -0 "$FORWARD_PID" 2>/dev/null || fail "port-forward to $service: $(cat "$WORK/forward.log")"
health=$(curl -sS "$BASE/healthcheck?strict=1")
[ "$(jq -r '.db and .redis' <<<"$health")" = true ] || fail "the strict health check reports a dependency down: $health"
ok "Kener answers and reaches its database and Redis ($health)"

state=$RELEASE-e2e
tag=e2e-self
if [ "$PHASE" = after-reinstall ]; then
  stored() { k get secret "$state" -o "jsonpath={.data.$1}" | base64 -d; }
  email=$(stored email)
  KEY=$(stored api-key)
  [ "$(form login "email=$email" "password=$(stored password)" | jq -r .type)" = redirect ] ||
    fail "the account does not log in after the reinstall"
  ok "the account logs in again with the same password (database kept)"
  [ "$(api GET "/monitors/$tag" | expect_status 200 "the monitor with the old API key" | jq -r .monitor.tag)" = "$tag" ] ||
    fail "the monitor is not found with the old API key"
  ok "the API key created before the reinstall still works (KENER_SECRET_KEY kept)"
  echo "All end-to-end checks passed"
  exit 0
fi

email=e2e-admin@example.test
password="E2e-$(head -c 12 /dev/urandom | base64 | tr -d '/+=')"
signup=$(form signup "name=E2E admin" "email=$email" "password=$password")
[ "$(jq -r .type <<<"$signup")" = redirect ] || fail "sign-up of the first account: $signup"
second=$(: >"$JAR"; form signup "name=Intruder" "email=intruder@example.test" "password=$password")
[ "$(jq -r .type <<<"$second")" = failure ] || fail "a second account could sign up from the public page: $second"
ok "the first account signs up, a second one is refused"

: >"$JAR"
[ "$(form login "email=$email" "password=wrong-$password" | jq -r .type)" = failure ] || fail "a wrong password logs in"
login=$(form login "email=$email" "password=$password")
[ "$(jq -r .type <<<"$login")" = redirect ] || fail "login: $login"
grep -q 'kener-user' "$JAR" || fail "login set no session cookie"
ok "the account logs in, not with a wrong password"

KEY=$(curl -sS -b "$JAR" -H "Origin: $ORIGIN" -H 'content-type: application/json' \
  --data '{"action": "createNewApiKey", "data": {"name": "e2e"}}' "$BASE/manage/api" | jq -r '.apiKey // empty')
[ -n "$KEY" ] || fail "no API key was created"
for path in /api/v4/monitors /%61pi/v4/monitors; do
  code=$(curl -sS -o /dev/null -w '%{http_code}' "$BASE$path")
  [ "$code" = 401 ] || [ "$code" = 404 ] || fail "$path answers $code without an API key"
done
code=$(curl -sS -o /dev/null -w '%{http_code}' -H "authorization: Bearer wrong-$KEY" "$BASE/api/v4/monitors")
[ "$code" = 401 ] || fail "the API answers $code with a wrong key"
ok "an API key is created; the API refuses requests without a valid key"

# The monitor probes Kener itself, through its Service: it runs every minute in the background queue.
monitor=$(jq -n --arg tag "$tag" --arg url "http://$service:$service_port$(env_of KENER_BASE_PATH)/healthcheck" \
  '{tag: $tag, name: "E2E self check", monitor_type: "API", cron: "* * * * *",
    type_data: {url: $url, method: "GET", timeout: 5000, headers: [], body: ""}}')
api POST /monitors "$monitor" | expect_status 201 "monitor creation" >/dev/null
page=$(jq -n --arg tag "$tag" '{page_path: "e2e", page_title: "E2E", page_header: "E2E status", monitors: [$tag]}')
api POST /pages "$page" | expect_status 201 "status page creation" >/dev/null
ok "a monitor and a status page are created through the REST API"

status=""
for _ in $(seq 36); do
  now=$(date +%s)
  status=$(api GET "/monitors/$tag/data?start_ts=$((now - 600))&end_ts=$((now + 60))" | expect_status 200 "monitor data" |
    jq -r '[.data[] | select(.type == "REALTIME")] | last | .status // empty')
  [ -n "$status" ] && break
  sleep 5
done
[ "$status" = UP ] || fail "the monitor did not record an UP check within 3 minutes (last: ${status:-none})"
ok "the monitor ran from the queue and recorded UP"

curl -sSf "$BASE/e2e" >"$WORK/page.html"
if ! grep -qF "monitorTags:[\"$tag\"]" "$WORK/page.html" || ! grep -q "All Systems Operational" "$WORK/page.html"; then
  fail "the status page does not list the monitor as operational"
fi
curl -sSf "$BASE/monitors/$tag" >"$WORK/monitor.html"
grep -q "E2E self check" "$WORK/monitor.html" || fail "the monitor page does not answer"
curl -sSf "$BASE/badge/$tag/status" >"$WORK/badge.svg"
grep -q "E2E self check: Operational" "$WORK/badge.svg" || fail "the status badge does not say Operational"
ok "the public status page lists the monitor as operational, its page and badge answer"

valkey=$(component deploy redis 2>/dev/null || true)
if [ -n "$valkey" ]; then
  noauth=$(k exec "deploy/$valkey" -- sh -c 'env -u VALKEYCLI_AUTH valkey-cli -h 127.0.0.1 ping' 2>&1 || true)
  grep -q NOAUTH <<<"$noauth" || fail "Valkey answers without its password: $noauth"
  ok "Valkey refuses commands without its password"
fi

if [ -n "$valkey" ] && [ -n "$(k get networkpolicy -l "app.kubernetes.io/instance=$RELEASE" -o name)" ]; then
  # TCP connection test with Node.js, present in every Kener image: exit 0 when it connects.
  connect='const s = require("net").connect(+process.argv[2], process.argv[1]);
    s.setTimeout(5000, () => process.exit(2)); s.on("connect", () => process.exit(0)); s.on("error", () => process.exit(1));'
  valkey_service=$(component svc redis)
  valkey_port=$(k get svc "$valkey_service" -o jsonpath='{.spec.ports[0].port}')
  k exec "deploy/$kener" -- node -e "$connect" "$valkey_service" "$valkey_port" || fail "Kener cannot reach Valkey"
  PROBE=$RELEASE-e2e-probe
  k run "$PROBE" --image="$(k get deploy "$kener" -o jsonpath='{.spec.template.spec.containers[0].image}')" \
    --restart=Never --labels=app.kubernetes.io/name=e2e-probe --command -- sleep 300 >/dev/null
  k wait --for=condition=Ready "pod/$PROBE" --timeout=120s >/dev/null
  k exec "$PROBE" -- node -e "$connect" "$service" "$service_port" || fail "another pod cannot reach Kener"
  if k exec "$PROBE" -- node -e "$connect" "$valkey_service" "$valkey_port" 2>/dev/null; then
    fail "another pod reaches Valkey despite the NetworkPolicy"
  fi
  ok "another pod reaches Kener but not Valkey (NetworkPolicy)"
fi

# Kept for the after-reinstall run, outside the release, so that helm uninstall leaves it.
printf '%s' "$email" >"$WORK/email"
printf '%s' "$password" >"$WORK/password"
printf '%s' "$KEY" >"$WORK/api-key"
k create secret generic "$state" --from-file="$WORK/email" --from-file="$WORK/password" \
  --from-file="$WORK/api-key" --dry-run=client -o yaml | k apply -f - >/dev/null

echo "All end-to-end checks passed"
