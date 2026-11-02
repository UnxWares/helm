#!/usr/bin/env bash
# shellcheck disable=SC2016 # the $names in single quotes are jq variables or expand in the container's shell
# End-to-end check of a fresh taiga release, through its gateway Service, as the browser uses it: the front serves its
# configuration, a superuser created with manage.py logs in through the API, creates a project and a user story and
# reads them back, an attachment is uploaded and served back through taiga-protected (and refused without its
# signed token), a project export is downloaded, and a websocket client subscribed on /events receives the change of
# the user story. Then the Celery beat scheduler runs once, in its own pod, and, when the release has its
# NetworkPolicies, a pod outside the release reaches the gateway and nothing else.
#
# usage: taiga-e2e.sh <namespace> <release>
set -euo pipefail

NAMESPACE=$1
RELEASE=$2
PORT=15213
BASE="http://127.0.0.1:$PORT"
API="$BASE/api/v1"
# Scratch files stay in a fresh temporary directory: nothing is deleted.
WORK=$(mktemp -d)
cleanup() {
  if [ -n "${WS_PID:-}" ]; then kill "$WS_PID" 2>/dev/null || true; fi
  if [ -n "${FORWARD_PID:-}" ]; then kill "$FORWARD_PID" 2>/dev/null || true; fi
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }
k() { kubectl -n "$NAMESPACE" "$@"; }
# Name of the object of a component of the release.
name() {
  k get "$1" -l "app.kubernetes.io/instance=$RELEASE,app.kubernetes.io/component=$2" -o jsonpath='{.items[0].metadata.name}'
}
# The API answers JSON; on an HTTP error, fail with the answer.
api() {
  local response
  response=$(curl -sS -w '\n%{http_code}' "${auth[@]}" "$@")
  case "${response##*$'\n'}" in
    2??) printf '%s' "${response%$'\n'*}" ;;
    *) fail "HTTP ${response##*$'\n'} on $*: ${response%$'\n'*}" ;;
  esac
}
# Absolute URLs carry the public domain: keep their path and query, through the port-forward.
local_url() { local url=${1%%#*}; echo "$BASE/${url#*://*/}"; }
auth=()

gateway=$(name svc gateway)
backend=$(name deploy backend)
frontend=$(name deploy frontend)
k port-forward "svc/$gateway" "$PORT:$(k get svc "$gateway" -o jsonpath='{.spec.ports[0].port}')" >"$WORK/forward.log" 2>&1 &
FORWARD_PID=$!
for _ in $(seq 60); do
  curl -sf "$API/" >/dev/null && break
  sleep 1
done
curl -sSf "$API/" | jq -e .projects >/dev/null || fail "no API answer on /api/v1/ through the gateway"
ok "the API answers through the gateway"

# --- Front -----------------------------------------------------------------------------------------------------------
env_of() { k get deploy "$frontend" -o jsonpath="{.spec.template.spec.containers[0].env[?(@.name==\"$1\")].value}"; }
taiga_url=$(env_of TAIGA_URL)$(env_of TAIGA_SUBPATH)
events_url=$(env_of TAIGA_WEBSOCKETS_URL)$(env_of TAIGA_SUBPATH)/events
conf=$(curl -sSf "$BASE/conf.json")
[ "$(jq -r .api <<<"$conf")" = "$taiga_url/api/v1/" ] || fail "conf.json does not point to $taiga_url/api/v1/: $conf"
[ "$(jq -r .eventsUrl <<<"$conf")" = "$events_url" ] || fail "conf.json does not point to $events_url: $conf"
curl -sSf -o "$WORK/index.html" "$BASE/"
grep -q '<base href="/">' "$WORK/index.html" || fail "the front page is not the Taiga front"
ok "the front serves its page and its configuration (API $taiga_url/api/v1/, events $events_url)"

# --- Superuser, login ------------------------------------------------------------------------------------------------
username="e2e-admin-$(date +%s)"
password="E2e-$(head -c 12 /dev/urandom | base64 | tr -d '/+=')"
# The password goes through stdin, never on a command line.
k exec -i "deploy/$backend" -c backend -- sh -c '
  IFS= read -r DJANGO_SUPERUSER_PASSWORD; export DJANGO_SUPERUSER_PASSWORD
  exec python manage.py createsuperuser --noinput --username "$1" --email "$2"
' sh "$username" "$username@example.test" <<<"$password" >/dev/null
ok "a superuser is created with manage.py createsuperuser"

json() { jq -n "$@"; }
code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST -H 'content-type: application/json' "$API/auth" \
  -d "$(json --arg u "$username" '{type: "normal", username: $u, password: "not-the-password"}')")
[ "$code" = 401 ] || fail "a wrong password got HTTP $code instead of 401"
session=$(api -X POST -H 'content-type: application/json' "$API/auth" \
  -d "$(json --arg u "$username" --arg p "$password" '{type: "normal", username: $u, password: $p}')")
token=$(jq -r '.auth_token // empty' <<<"$session")
[ -n "$token" ] || fail "no auth_token in the login answer: $session"
auth=(-H "Authorization: Bearer $token")
me=$(api "$API/users/me")
[ "$(jq -r .username <<<"$me")" = "$username" ] && [ "$(jq -r .email <<<"$me")" = "$username@example.test" ] ||
  fail "the token does not belong to the superuser: $me"
ok "the superuser logs in through the API (a wrong password is refused) and gets a token"

# --- Project, user story ---------------------------------------------------------------------------------------------
project_name="End-to-end $(date +%s)"
project=$(api -X POST -H 'content-type: application/json' "$API/projects" \
  -d "$(json --arg n "$project_name" '{name: $n, description: "Created by the end-to-end test"}')")
project_id=$(jq -r .id <<<"$project")
[ "$(api "$API/projects/$project_id" | jq -r .name)" = "$project_name" ] || fail "the project does not read back: $project"
ok "a project is created and read back (id $project_id)"

# A websocket client on /events, as the front opens it: authenticated with the token, subscribed to the user stories
# of the project. It prints "ready" once subscribed, then the first event it receives.
python3 - "127.0.0.1" "$PORT" "$token" "changes.project.$project_id.userstories" >"$WORK/ws.log" 2>&1 <<'EOF' &
import base64, json, os, socket, struct, sys, time

host, port, token, routing_key = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
sock = socket.create_connection((host, port), timeout=60)
key = base64.b64encode(os.urandom(16)).decode()
sock.sendall((f"GET /events HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
              f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
answer = b""
while b"\r\n\r\n" not in answer:
    chunk = sock.recv(4096)
    if not chunk:
        sys.exit("connection closed during the handshake")
    answer += chunk
if b" 101 " not in answer.split(b"\r\n")[0]:
    sys.exit("no websocket upgrade: " + answer.split(b"\r\n")[0].decode())
pending = answer.split(b"\r\n\r\n", 1)[1]

def send(message):
    payload, mask = json.dumps(message).encode(), os.urandom(4)
    header = bytes([0x81]) + (bytes([0x80 | len(payload)]) if len(payload) < 126 else bytes([0xFE]) + struct.pack(">H", len(payload)))
    sock.sendall(header + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))

def read(n):
    global pending
    while len(pending) < n:
        chunk = sock.recv(65536)
        if not chunk:
            sys.exit("connection closed by the server")
        pending += chunk
    data, pending = pending[:n], pending[n:]
    return data

def receive():
    first, second = read(2)
    length = second & 0x7F
    if length == 126:
        length = struct.unpack(">H", read(2))[0]
    elif length == 127:
        length = struct.unpack(">Q", read(8))[0]
    payload = read(length)
    if first & 0x0F == 0x8:
        sys.exit("connection closed by the server")
    return json.loads(payload) if first & 0x0F == 0x1 else None

send({"cmd": "auth", "data": {"token": token, "sessionId": "e2e-websocket"}})
send({"cmd": "subscribe", "routing_key": routing_key})
send({"cmd": "ping"})
while (receive() or {}).get("cmd") != "pong":
    pass
time.sleep(2)  # the subscription binds its queue asynchronously
print("ready", flush=True)
while True:
    message = receive()
    if message and message.get("routing_key") == routing_key:
        print(json.dumps(message), flush=True)
        break
EOF
WS_PID=$!
for _ in $(seq 30); do
  grep -q '^ready' "$WORK/ws.log" && break
  kill -0 "$WS_PID" 2>/dev/null || fail "the websocket client stopped: $(cat "$WORK/ws.log")"
  sleep 1
done
grep -q '^ready' "$WORK/ws.log" || fail "the websocket client did not subscribe: $(cat "$WORK/ws.log")"

story=$(api -X POST -H 'content-type: application/json' "$API/userstories" \
  -d "$(json --argjson p "$project_id" '{project: $p, subject: "Checked end to end"}')")
story_id=$(jq -r .id <<<"$story")
[ "$(api "$API/userstories/$story_id" | jq -r .subject)" = "Checked end to end" ] || fail "the user story does not read back"
[ "$(api "$API/userstories?project=$project_id" | jq --argjson id "$story_id" '[.[] | select(.id == $id)] | length')" = 1 ] ||
  fail "the user story is not in the list of the project"
ok "a user story is created, read back and listed (id $story_id)"

for _ in $(seq 30); do
  kill -0 "$WS_PID" 2>/dev/null || break
  sleep 1
done
event=$(grep '^{' "$WORK/ws.log" || true)
[ "$(jq -r .data.pk <<<"${event:-null}")" = "$story_id" ] || fail "no event for the user story on the websocket: $(cat "$WORK/ws.log")"
ok "the websocket client receives the change of the user story (backend -> events broker -> taiga-events -> gateway)"

# --- Attachment ------------------------------------------------------------------------------------------------------
printf 'end-to-end attachment %s\n' "$(date +%s%N)" >"$WORK/attachment.txt"
attachment=$(api -X POST "$API/userstories/attachments" -F "project=$project_id" -F "object_id=$story_id" \
  -F "attached_file=@$WORK/attachment.txt")
url=$(jq -r .url <<<"$attachment")
[ "$(jq -r .size <<<"$attachment")" = "$(stat -c %s "$WORK/attachment.txt")" ] || fail "wrong attachment size: $attachment"
curl -sSf -o "$WORK/download.bin" "$(local_url "$url")"
cmp -s "$WORK/attachment.txt" "$WORK/download.bin" || fail "the downloaded attachment differs from the uploaded one"
ok "an attachment is uploaded and downloaded back unchanged through taiga-protected"
plain=$(local_url "$url")
code=$(curl -sS -o /dev/null -w '%{http_code}' "${plain%%\?*}")
[ "$code" = 403 ] || fail "the attachment without its token got HTTP $code instead of 403"
code=$(curl -sS -o /dev/null -w '%{http_code}' "${plain%%\?*}?token=forged:token")
[ "$code" = 403 ] || fail "the attachment with a forged token got HTTP $code instead of 403"
ok "the attachment is refused without its token or with a forged one"

# --- Project export --------------------------------------------------------------------------------------------------
# The worker writes the export to the media volume as exports/<project id>/<slug>-<task id>.json, and the e-mail
# links to it under /media/exports/, which the gateway serves from the volume.
slug=$(api "$API/projects/$project_id" | jq -r .slug)
export_id=$(api "$API/exporter/$project_id" | jq -r .export_id)
[ -n "$export_id" ] && [ "$export_id" != null ] || fail "the export request returned no export id"
# The file appears as soon as the worker starts writing it: wait until it is complete JSON.
code=000
for _ in $(seq 60); do
  code=$(curl -sS -o "$WORK/export.json" -w '%{http_code}' "$BASE/media/exports/$project_id/$slug-$export_id.json")
  if [ "$code" = 200 ] && jq -e . "$WORK/export.json" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
[ "$code" = 200 ] || fail "the project export is not served on /media/exports/ (HTTP $code)"
[ "$(jq -r .slug "$WORK/export.json" 2>/dev/null)" = "$slug" ] ||
  fail "the export is not the project's: $(head -c 200 "$WORK/export.json")"
ok "a project export is written by the worker and downloaded through the gateway"

# --- Celery beat -----------------------------------------------------------------------------------------------------
# The beat pod sends the periodic tasks and the workers run them. The bulk email task is due every 120 seconds after
# a scheduler starts: with one scheduler, the workers receive at most one per period since the beat pod started; a
# scheduler in each worker (two in this test) would send it once more per worker.
beat=$(name pod async-beat)
grep -q 'celery beat v' <<<"$(k logs "$beat")" || fail "the beat pod runs no beat scheduler"
started=$(k get pod "$beat" -o jsonpath='{.status.containerStatuses[0].state.running.startedAt}')
[ -n "$started" ] || fail "the beat pod is not running"
workers=$(k get pods -l "app.kubernetes.io/instance=$RELEASE,app.kubernetes.io/component=async" -o name)
received() {
  local count=0 pod
  for pod in $workers; do
    count=$((count + $(grep -c 'Task taiga.projects.notifications.tasks.send_bulk_email\[.*\] received' \
      <<<"$(k logs "$pod" --since-time="$started")" || true)))
  done
  echo "$count"
}
for _ in $(seq 50); do
  [ "$(received)" -ge 1 ] && break
  sleep 5
done
count=$(received)
periods=$((($(date -u +%s) - $(date -u -d "$started" +%s)) / 120))
[ "$count" -ge 1 ] || fail "no worker received the periodic task in $((periods * 2)) minutes"
[ "$count" -le $((periods + 1)) ] || fail "the periodic task was received $count times in $periods periods: more than one scheduler runs"
ok "one beat scheduler, in its own pod, sends the periodic tasks: $count received by $(wc -w <<<"$workers") worker pod(s) in $periods period(s) of 120 s"

# --- NetworkPolicies -------------------------------------------------------------------------------------------------
if [ -n "$(k get networkpolicy -l "app.kubernetes.io/instance=$RELEASE" -o name)" ]; then
  # A pod that is not part of the release tries every Service of the release: only the gateway answers.
  targets=("$gateway:$(k get svc "$gateway" -o jsonpath='{.spec.ports[0].port}'):open")
  for component in frontend backend protected events async-rabbitmq events-rabbitmq db; do
    service=$(name svc "$component" 2>/dev/null || true)
    [ -n "$service" ] || continue
    for port in $(k get svc "$service" -o jsonpath='{.spec.ports[*].port}'); do
      targets+=("$service:$port:closed")
    done
  done
  result=$(k run "$RELEASE-e2e-netpol" --rm -i --quiet --restart=Never --image="$(k get deploy "$backend" -o jsonpath='{.spec.template.spec.containers[0].image}')" \
    --overrides='{"spec": {"automountServiceAccountToken": false, "securityContext": {"runAsNonRoot": true, "runAsUser": 999, "seccompProfile": {"type": "RuntimeDefault"}}}}' \
    --command -- python3 -c '
import socket, sys
for target in sys.argv[1:]:
    host, port, expected = target.split(":")
    try:
        socket.create_connection((host, int(port)), timeout=5).close()
        state = "open"
    except OSError:
        state = "closed"
    print(f"{host}:{port} {state} (expected {expected})")
' "${targets[@]}")
  grep -q 'closed (expected open)\|open (expected closed)' <<<"$result" && fail "unexpected reachability from outside the release:
$result"
  [ "$(grep -c 'expected' <<<"$result")" = "${#targets[@]}" ] || fail "the probe pod did not test every Service: $result"
  ok "from a pod outside the release, only the gateway answers ($(grep -c 'closed (expected closed)' <<<"$result") Service ports closed)"
fi

echo "All end-to-end checks passed"
