#!/usr/bin/env bash
# shellcheck disable=SC2016 # the $variables in single quotes are PHP or jq variables
# End-to-end check of a laravel-generic release running the test application of .github/e2e/laravel-app, through its
# Service:
# - Laravel answers through the runtime of the release (FrankenPHP, or PHP-FPM behind the nginx sidecar, with its
#   headers), the web server serves a static file of the image, and the app container runs as the uid of the chart
#   on a read-only root filesystem;
# - the web pod uses the APP_KEY of the chart Secret, and so do the migrations, the queue worker and the scheduler;
# - the migrations ran where the chart runs them (the init container of the web pod with SQLite, the hook Job
#   otherwise); a note is written to the database and read back with its encrypted copy;
# - a session counter goes up across requests (session store, encrypted cookie, Blade view), and a cache value
#   written by the web pod is read back, also by the queue worker;
# - a queued job runs in a queue worker pod and writes to storage/app (persistent volume): the web pod reads the file
#   back and the web server serves the one of the public disk under /storage/;
# - the scheduler runs its every-minute task (CronJob or schedule:work);
# - with the fpm runtime and a NetworkPolicy, another pod reaches nginx but not PHP-FPM.
#
# Run it again with "after-reinstall" once the release was uninstalled and installed again: the APP_KEY, the note
# (still decrypted), the session, the files and the database must have survived (kept Secret and PVC).
#
# usage: laravel-generic-e2e.sh <namespace> <release> [after-reinstall]
set -euo pipefail

NAMESPACE=$1
RELEASE=$2
PHASE=${3:-first}
# One local port per release: the script runs once per release, and a port-forward that is still stopping must not
# answer for the next release.
PORT=$((15480 + $(printf '%s' "$RELEASE" | cksum | cut -d' ' -f1) % 500))
BASE="http://127.0.0.1:$PORT"
STATIC="laravel-generic end-to-end test: static file of the image"
# Scratch files stay in a fresh temporary directory: nothing is deleted.
WORK=$(mktemp -d)
JAR=$WORK/cookies
cleanup() {
  if [ -n "${FORWARD_PID:-}" ]; then
    # The forward exits on TERM (status 143): neither this nor kill may fail the script under set -e.
    kill "$FORWARD_PID" 2>/dev/null || true
    wait "$FORWARD_PID" 2>/dev/null || true
  fi
  true
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }
k() { kubectl -n "$NAMESPACE" "$@"; }
names() { # kind, component: names of the release's resources of that component
  k get "$1" -l "app.kubernetes.io/instance=$RELEASE,app.kubernetes.io/component=$2" -o jsonpath='{.items[*].metadata.name}'
}
api() { # method, path under /api/e2e, [JSON body]: prints the body, then the status on the last line
  curl -sS -X "$1" -H 'accept: application/json' -H 'content-type: application/json' ${3:+--data "$3"} \
    -w '\n%{http_code}' "$BASE/api/e2e$2"
}
expect_status() { # expected status, description; reads "body\nstatus" on stdin, prints the body
  local out status
  out=$(cat)
  status=${out##*$'\n'}
  [ "$status" = "$1" ] || fail "$2: HTTP $status, expected $1: ${out%$'\n'*}"
  printf '%s\n' "${out%$'\n'*}"
}
session() { # GET /e2e/session with the cookie jar: prints the counter of the session
  curl -sSf -b "$JAR" -c "$JAR" "$BASE/e2e/session" >"$WORK/session.html" || fail "/e2e/session does not answer"
  sed -n 's/.*data-count="\([0-9]*\)".*/\1/p' "$WORK/session.html"
}

web=$(names deploy web)
[ -n "$web" ] || fail "the release $RELEASE has no web Deployment"
fullname=$web
k get deploy "$web" -o json >"$WORK/web.json"
app=$(jq -c '.spec.template.spec.containers[] | select(.name == "app")' "$WORK/web.json")
image=$(jq -r .image <<<"$app")
env_of() { jq -r --arg name "$1" '.env[] | select(.name == $name) | .value // empty' <<<"$app"; }
connection=$(env_of DB_CONNECTION)
if jq -e '.spec.template.spec.containers[] | select(.name == "nginx")' "$WORK/web.json" >/dev/null; then
  runtime=fpm
  sapi_expected=fpm-fcgi
else
  runtime=frankenphp
  sapi_expected=frankenphp
fi
read -r key_secret key_name < <(jq -r '.env[] | select(.name == "APP_KEY") | .valueFrom.secretKeyRef | "\(.name) \(.key)"' <<<"$app")
app_key=$(k get secret "$key_secret" -o json | jq -r --arg key "$key_name" '.data[$key] // empty' | base64 -d)
key_hash=$(printf '%s' "$app_key" | sha256sum | cut -d' ' -f1)
state=$RELEASE-e2e

service=$(names svc web)
service_port=$(k get svc "$service" -o jsonpath='{.spec.ports[0].port}')
k port-forward "svc/$service" "$PORT:$service_port" >"$WORK/forward.log" 2>&1 &
FORWARD_PID=$!
for _ in $(seq 60); do
  curl -sf -o /dev/null "$BASE/up" && break
  sleep 1
done
kill -0 "$FORWARD_PID" 2>/dev/null || fail "port-forward to $service: $(cat "$WORK/forward.log")"
curl -sSf -o /dev/null "$BASE/up" || fail "/up does not answer through the Service $service"

# --- Runtime --------------------------------------------------------------------------------------------------------
info=$(api GET /info | expect_status 200 "/api/e2e/info")
sapi=$(jq -r .sapi <<<"$info")
[ "$sapi" = "$sapi_expected" ] || fail "PHP runs as '$sapi', expected '$sapi_expected' with the $runtime runtime"
ok "Laravel $(jq -r .laravel <<<"$info") answers /up and its routes through the Service, PHP $(jq -r .php <<<"$info") ($sapi)"

if [ "$runtime" = fpm ]; then
  headers=$(curl -sS -D - -o /dev/null "$BASE/api/e2e/info" | tr -d '\r') || fail "no answer from /api/e2e/info"
  grep -qi '^x-frame-options: SAMEORIGIN$' <<<"$headers" || fail "no X-Frame-Options header from nginx: $headers"
  grep -qi '^server: nginx$' <<<"$headers" || fail "nginx does not hide its version (server_tokens off): $headers"
  if grep -qi '^x-powered-by' <<<"$headers"; then
    fail "the X-Powered-By header of PHP reaches the client: $headers"
  fi
  ok "nginx passes PHP requests to PHP-FPM with the headers of the chart (X-Frame-Options, no version, no X-Powered-By)"
fi

static=$(curl -sS -o "$WORK/static.txt" -w '%{http_code} %{content_type}' "$BASE/e2e.txt") || fail "no answer from /e2e.txt"
[ "${static%% *}" = 200 ] && [ "$(cat "$WORK/static.txt")" = "$STATIC" ] ||
  fail "public/e2e.txt of the image is not served: $static $(head -c 200 "$WORK/static.txt")"
case ${static#* } in text/plain*) ;; *) fail "public/e2e.txt is served as '${static#* }'" ;; esac
ok "the $runtime web server serves the static files of public/ (text/plain)"

pod=$(k get pods -l "app.kubernetes.io/instance=$RELEASE,app.kubernetes.io/component=web" \
  --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')
# uid, then the mount options of / (shell builtins only: the image may lack awk).
identity=$(k exec "$pod" -c app -- sh -c 'id -u; while read -r _ mnt _ opts _; do [ "$mnt" != / ] || echo "$opts"; done </proc/mounts') ||
  fail "cannot run sh in the app container of $pod"
uid=$(jq -r '.spec.template.spec.securityContext.runAsUser' "$WORK/web.json")
[ "$(head -n 1 <<<"$identity")" = "$uid" ] || fail "the app container runs as uid $(head -n 1 <<<"$identity"), expected $uid"
case ,$(tail -n 1 <<<"$identity"), in *,ro,*) ;; *) fail "the root filesystem of the app container is not read-only: $identity" ;; esac
ok "the app container runs as uid $uid on a read-only root filesystem"

# --- APP_KEY --------------------------------------------------------------------------------------------------------
case $app_key in base64:*) ;; *) fail "APP_KEY of the Secret $key_secret does not start with base64:" ;; esac
[ "$(printf '%s' "${app_key#base64:}" | base64 -d | wc -c)" -eq 32 ] || fail "APP_KEY of the Secret $key_secret is not 32 bytes"
[ "$(jq -r .app_key_sha256 <<<"$info")" = "$key_hash" ] || fail "the web pod does not use the APP_KEY of the Secret $key_secret"
ok "the web pod uses the APP_KEY of the Secret $key_secret (base64:, 32 random bytes)"

# --- Database -------------------------------------------------------------------------------------------------------
driver=$(jq -r .database.driver <<<"$info")
[ "$driver" = "$connection" ] || fail "Laravel uses the $driver connection, the chart set DB_CONNECTION=$connection"
database=$(jq -r .database.title <<<"$info")
if [ "$driver" = sqlite ]; then
  file=$(jq -r .database.name <<<"$info")
  mounts=$(k exec "$pod" -c app -- sh -c 'while read -r _ mnt _; do echo "$mnt"; done </proc/mounts') ||
    fail "cannot read the mounts of the app container of $pod"
  grep -qxF "$(dirname "$file")" <<<"$mounts" || fail "the directory of the SQLite file $file is not a volume of the pod"
  database="$database ($file, on its own volume)"
fi
jq -e '.migrations | any(. == "2026_11_02_000000_create_e2e_tables")' <<<"$info" >/dev/null ||
  fail "the migration of the test application did not run: $(jq -c .migrations <<<"$info")"
migration=$(api GET "/events?kind=migration" | expect_status 200 "migration events")
[ "$(jq length <<<"$migration")" = 1 ] || fail "expected the migrations to run once, got: $migration"
migrated_by=$(jq -r '.[0].host' <<<"$migration")
[ "$(jq -r '.[0].app_key_sha256' <<<"$migration")" = "$key_hash" ] || fail "the migrations ran with another APP_KEY"

if [ "$PHASE" = after-reinstall ]; then
  stored() { k get secret "$state" -o json | jq -r --arg key "$1" '.data[$key]' | base64 -d; }
  [ "$(stored app-key-sha256)" = "$key_hash" ] || fail "APP_KEY changed with the reinstall"
  ok "the reinstall kept the APP_KEY of the first install (Secret $key_secret)"
  [ "$migrated_by" = "$(stored migrated-by)" ] ||
    fail "the migrations ran again in $migrated_by, the first install ran them in $(stored migrated-by)"
  ok "the $database database of the first install is still there (migrations not run again)"
  note=$(api GET "/notes/$(stored note-id)" | expect_status 200 "the note of the first install")
  [ "$(jq -r .secret <<<"$note")" = "$(stored note-body)" ] || fail "the note of the first install does not decrypt: $note"
  ok "the note written before the reinstall reads back and decrypts"
  stored cookies >"$JAR"
  count=$(session)
  [ "$count" = $(($(stored session-count) + 1)) ] || fail "the session of the first install is lost (counter: '$count')"
  ok "the session opened before the reinstall goes on (counter $count)"
  token=$(stored token)
  [ "$(api GET "/files/$token" | expect_status 200 "the file of the first install" | jq -r .local)" = "$(stored file)" ] ||
    fail "the file written to storage/app before the reinstall is gone"
  [ "$(curl -sS "$BASE/storage/e2e/$token.txt")" = "$token" ] || fail "the public file of the first install is not served"
  ok "the files written to storage/app before the reinstall are still there (persistent volume)"
  echo "All end-to-end checks passed"
  exit 0
fi

if [ "$driver" = sqlite ]; then
  # The init container of the (single) web pod migrates before Laravel starts.
  [ "$migrated_by" = "$pod" ] || fail "the migrations ran in $migrated_by, not in the init container of the web pod $pod"
  ok "the migrations ran in the init container of the web pod, with the same APP_KEY"
else
  case $migrated_by in "$fullname-migrations-"*) ;; *) fail "the migrations ran in $migrated_by, not in the hook Job" ;; esac
  if k get job "$fullname-migrations" >/dev/null 2>&1 || k get secret "$fullname-migrations" >/dev/null 2>&1; then
    fail "the migrations Job or its copy of the Secret is still there after it succeeded"
  fi
  ok "the migrations ran in the hook Job with the same APP_KEY; the Job and its copy of the Secret are gone"
fi

body="note $(date +%s) $RANDOM: été, 東京, \"quoted\""
created=$(api POST /notes "$(jq -cn --arg body "$body" '{body: $body}')" | expect_status 201 "note creation")
note_id=$(jq -r .id <<<"$created")
note=$(api GET "/notes/$note_id" | expect_status 200 "note read back")
[ "$(jq -r .body <<<"$note")" = "$body" ] || fail "the note reads back differently: $note"
[ "$(jq -r .secret <<<"$note")" = "$body" ] || fail "the encrypted copy of the note does not decrypt: $note"
ok "a note is written to the $database database and read back, with its encrypted copy"

# --- Session and cache ----------------------------------------------------------------------------------------------
[ "$(session)" = 1 ] || fail "a new session does not start at 1: $(head -c 300 "$WORK/session.html")"
grep -qF "<title>$(env_of APP_NAME) end-to-end test</title>" "$WORK/session.html" ||
  fail "the Blade view does not show APP_NAME=$(env_of APP_NAME): $(head -c 300 "$WORK/session.html")"
[ "$(session)" = 2 ] || fail "the session counter does not go up: the session is not kept"
grep -q -- '-session' "$JAR" || fail "no session cookie was set"
ok "a session counter goes up across requests ($(jq -r .stores.session <<<"$info") session store, encrypted cookie, Blade view)"

token="e2e-$(date +%s)-$RANDOM"
api PUT "/cache/$token" "$(jq -cn --arg value "cached $token" '{value: $value}')" | expect_status 204 "cache write" >/dev/null
[ "$(api GET "/cache/$token" | expect_status 200 "cache read" | jq -r .value)" = "cached $token" ] ||
  fail "the cache value cannot be read back"
ok "a value is written to the $(jq -r .stores.cache <<<"$info") cache and read back"

# --- Queue ----------------------------------------------------------------------------------------------------------
api POST /jobs "$(jq -cn --arg token "$token" '{token: $token}')" | expect_status 202 "job dispatch" >/dev/null
job=""
for _ in $(seq 60); do
  job=$(api GET "/events?kind=job&token=$token" | expect_status 200 "job events" | jq -c '.[0] // empty')
  [ -n "$job" ] && break
  sleep 2
done
[ -n "$job" ] || fail "the queued job did not run within 2 minutes"
worker=$(jq -r .host <<<"$job")
case " $(names pod queue-worker) " in *" $worker "*) ;; *) fail "the job ran in $worker, not in a queue worker pod" ;; esac
[ "$(jq -r .app_key_sha256 <<<"$job")" = "$key_hash" ] || fail "the queue worker does not use the APP_KEY of the Secret"
[ "$(jq -r .detail <<<"$job")" = "cached $token" ] || fail "the queue worker does not read the cache of the web pod: $job"
ok "a queued job ($(jq -r .stores.queue <<<"$info") queue) runs in a queue worker pod, with the same APP_KEY and cache"

file=$(api GET "/files/$token" | expect_status 200 "files of the job" | jq -r .local)
[ "$file" = "written by $worker" ] || fail "the web pod does not read the file the job wrote to storage/app: '$file'"
public=$(curl -sS -o "$WORK/public.txt" -w '%{http_code}' "$BASE/storage/e2e/$token.txt") || fail "no answer from /storage/"
[ "$public" = 200 ] && [ "$(cat "$WORK/public.txt")" = "$token" ] ||
  fail "the file of the public disk is not served at /storage/e2e/$token.txt: $public $(head -c 200 "$WORK/public.txt")"
ok "the web pod reads the files the job wrote to storage/app, and serves the one of the public disk under /storage/"

# --- Scheduler ------------------------------------------------------------------------------------------------------
if k get cronjob "$fullname-scheduler" >/dev/null 2>&1; then mode="CronJob running schedule:run"; else mode="schedule:work Deployment"; fi
scheduled=""
for _ in $(seq 40); do
  scheduled=$(api GET "/events?kind=schedule" | expect_status 200 "schedule events" | jq -c 'last // empty')
  [ -n "$scheduled" ] && break
  sleep 5
done
[ -n "$scheduled" ] || fail "the scheduler ran no task within 200 seconds ($mode)"
scheduler=$(jq -r .host <<<"$scheduled")
case $scheduler in "$fullname-scheduler-"*) ;; *) fail "the scheduled task ran in $scheduler, not in a scheduler pod" ;; esac
[ "$(jq -r .app_key_sha256 <<<"$scheduled")" = "$key_hash" ] || fail "the scheduler does not use the APP_KEY of the Secret"
ok "the scheduler runs its every-minute task ($mode, same APP_KEY)"

# --- NetworkPolicy --------------------------------------------------------------------------------------------------
if [ "$runtime" = fpm ] && k get networkpolicy "$fullname" >/dev/null 2>&1; then
  pod_ip=$(k get pod "$pod" -o jsonpath='{.status.podIP}')
  http_port=$(jq -r '.spec.template.spec.containers[] | select(.name == "nginx") | .ports[] | select(.name == "http") | .containerPort' "$WORK/web.json")
  fpm_port=$(jq -r '.ports[] | select(.name == "fastcgi") | .containerPort' <<<"$app")
  # A pod outside the release (image of the release, restricted Pod Security profile) opens TCP connections.
  probe=$RELEASE-e2e-probe
  overrides=$(jq -cn --arg name "$probe" '{spec: {automountServiceAccountToken: false, enableServiceLinks: false,
    securityContext: {runAsNonRoot: true, runAsUser: 65534, runAsGroup: 65534, seccompProfile: {type: "RuntimeDefault"}},
    containers: [{name: $name, securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true,
      capabilities: {drop: ["ALL"]}}}]}}')
  connect='foreach (array_slice($argv, 1) as $target) {
    [$host, $port] = explode(":", $target);
    echo $port, "=", @fsockopen($host, (int) $port, $errno, $error, 5) ? "open" : "closed", " ";
  }'
  k delete pod "$probe" --ignore-not-found >/dev/null
  k run "$probe" --image "$image" --image-pull-policy IfNotPresent --restart Never --labels app.kubernetes.io/name=e2e-probe \
    --override-type strategic --overrides "$overrides" --command -- php -r "$connect" "$pod_ip:$http_port" "$pod_ip:$fpm_port" >/dev/null
  phase=""
  for _ in $(seq 120); do
    phase=$(k get pod "$probe" -o jsonpath='{.status.phase}')
    case $phase in Succeeded | Failed) break ;; esac
    sleep 1
  done
  result=$(k logs "$probe")
  k delete pod "$probe" --wait=false >/dev/null
  [ "$phase" = Succeeded ] || fail "the probe pod ended in phase '$phase': $result"
  [ "$result" = "$http_port=open $fpm_port=closed " ] ||
    fail "from another pod, expected nginx open and PHP-FPM closed, got: $result"
  ok "another pod reaches nginx on port $http_port but not PHP-FPM on port $fpm_port (NetworkPolicy)"
fi

# Kept for the after-reinstall run, outside the release, so that helm uninstall leaves it.
printf '%s' "$key_hash" >"$WORK/app-key-sha256"
printf '%s' "$migrated_by" >"$WORK/migrated-by"
printf '%s' "$note_id" >"$WORK/note-id"
printf '%s' "$body" >"$WORK/note-body"
count=$(session)
printf '%s' "$count" >"$WORK/session-count"
printf '%s' "$token" >"$WORK/token"
printf '%s' "$file" >"$WORK/file"
k create secret generic "$state" --from-file="$WORK/app-key-sha256" --from-file="$WORK/migrated-by" \
  --from-file="$WORK/note-id" --from-file="$WORK/note-body" --from-file="$WORK/session-count" \
  --from-file="$WORK/token" --from-file="$WORK/file" --from-file="cookies=$JAR" \
  --dry-run=client -o yaml | k apply -f - >/dev/null

echo "All end-to-end checks passed"
