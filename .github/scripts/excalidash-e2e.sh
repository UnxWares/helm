#!/usr/bin/env bash
# shellcheck disable=SC2016 # the $names in single quotes are jq variables
# End-to-end check of a fresh excalidash release, through the frontend Service like a browser: authentication is
# turned on at onboarding, the first administrator registers with the one-time setup code of the backend logs, logs
# in, creates a drawing, finds it in the listing, exports everything as an .excalidash archive and gets the archive
# accepted by the import check (staged in /app/uploads, writable although the root filesystem is read-only). It also
# checks that cookies get the Secure flag behind a proxy that terminates TLS (backend.trustProxy), and, when the
# release has a NetworkPolicy, that another pod reaches the frontend but not the backend.
#
# Run it again with "after-reinstall" once the release was uninstalled and installed again: the account, its drawing
# and its session must have survived (kept PVC and Secret).
#
# usage: excalidash-e2e.sh <namespace> <release> [after-reinstall]
set -euo pipefail

NAMESPACE=$1
RELEASE=$2
PHASE=${3:-first}
PORT=15213
API="http://127.0.0.1:$PORT/api"
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
# JSON request with the session cookies and a fresh CSRF token, like the web application.
api() { # method, path, [JSON body], [extra curl arguments...]
  local method=$1 path=$2 body=${3:-} token
  shift 2; [ $# -gt 0 ] && shift
  token=$(curl -sSf -b "$JAR" -c "$JAR" "$API/csrf-token" | jq -r .token)
  curl -sS -b "$JAR" -c "$JAR" -X "$method" -H "x-csrf-token: $token" -H 'content-type: application/json' \
    ${body:+--data "$body"} -w '\n%{http_code}' "$@" "$API$path"
}
# Splits the output of api: body on stdout, fails unless the status is the expected one.
expect_status() { # expected status, description; reads the api output on stdin
  local out status
  out=$(cat)
  status=${out##*$'\n'}
  [ "$status" = "$1" ] || fail "$2: HTTP $status, expected $1: ${out%$'\n'*}"
  printf '%s\n' "${out%$'\n'*}"
}

frontend=$(component svc frontend)
backend=$(component svc backend)
frontend_port=$(k get svc "$frontend" -o jsonpath='{.spec.ports[0].port}')
backend_port=$(k get svc "$backend" -o jsonpath='{.spec.ports[0].port}')
kubectl -n "$NAMESPACE" port-forward "svc/$frontend" "$PORT:$frontend_port" >"$WORK/forward.log" 2>&1 &
FORWARD_PID=$!
for _ in $(seq 60); do
  curl -sf "$API/health" >/dev/null && break
  sleep 1
done
kill -0 "$FORWARD_PID" 2>/dev/null || fail "port-forward to $frontend: $(cat "$WORK/forward.log")"
[ "$(curl -sSf "$API/health" | jq -r .database)" = ok ] || fail "/api/health does not report the database"
ok "the frontend proxies /api/health to the backend, which reaches its database"

state=$RELEASE-e2e
if [ "$PHASE" = after-reinstall ]; then
  stored() { k get secret "$state" -o "jsonpath={.data.$1}" | base64 -d; }
  email=$(stored email)
  password=$(stored password)
  drawing=$(stored drawing)
  stored cookies >"$JAR"
  me=$(api GET /auth/me | expect_status 200 "the session from before the reinstall")
  [ "$(jq -r .user.email <<<"$me")" = "$email" ] || fail "the old session is not the administrator's: $me"
  ok "the session from before the reinstall is still valid (JWT secret kept)"
  : >"$JAR"
  api POST /auth/login "$(jq -n --arg e "$email" --arg p "$password" '{email: $e, password: $p}')" |
    expect_status 200 "login after the reinstall" >/dev/null
  ok "the administrator logs in again with the same password (database kept)"
  [ "$(api GET "/drawings/$drawing" | expect_status 200 "the drawing after the reinstall" | jq -r .name)" = "e2e drawing" ] ||
    fail "the drawing created before the reinstall is gone"
  ok "the drawing created before the reinstall is still there"
  echo "All end-to-end checks passed"
  exit 0
fi

status=$(curl -sSf "$API/auth/status")
[ "$(jq -r .authMode <<<"$status")" = local ] || fail "this test drives the local authentication mode: $status"
[ "$(jq -r .authOnboardingRequired <<<"$status")" = true ] || fail "a fresh release should ask for the onboarding choice: $status"
api POST /auth/onboarding-choice '{"enableAuth": true}' | expect_status 200 "onboarding choice" >/dev/null
ok "authentication is turned on at onboarding"

code=""
for _ in $(seq 30); do
  code=$(k logs "deploy/$(component deploy backend)" -c backend |
    grep -oE 'One-time admin setup code \([a-z_]+\): [A-Z0-9]{4}-[A-Z0-9]{4}' | tail -1 | awk '{print $NF}')
  [ -n "$code" ] && break
  sleep 1
done
[ -n "$code" ] || fail "no setup code in the backend logs"
ok "the backend logs a one-time setup code"

email=e2e-admin@example.test
password="E2e-$(head -c 12 /dev/urandom | base64 | tr -d '/+=')!7a"
credentials=$(jq -n --arg e "$email" --arg p "$password" '{email: $e, password: $p}')
api POST /auth/register "$(jq --arg c WRNG-CODE '. + {name: "E2E admin", setupCode: $c}' <<<"$credentials")" |
  expect_status 401 "registration with a wrong setup code" >/dev/null
api POST /auth/register "$(jq --arg c "$code" '. + {name: "E2E admin", setupCode: $c}' <<<"$credentials")" |
  expect_status 201 "registration with the setup code" >/dev/null
ok "the first administrator registers with the setup code, not without it"

: >"$JAR"
api POST /auth/login "$credentials" | expect_status 200 "login" >/dev/null
[ "$(api GET /auth/me | expect_status 200 "/auth/me" | jq -r .user.role)" = ADMIN ] || fail "the first account is not ADMIN"
ok "the administrator logs in"

# Plain HTTP through the port-forward: no Secure flag, or the browser would drop the cookies. Behind a proxy that
# terminates TLS and says so in X-Forwarded-Proto, the backend (trustProxy) must set it.
plain=$(api POST /auth/login "$credentials" -c /dev/null -D - -o /dev/null | grep -i '^set-cookie:' || true)
tls=$(api POST /auth/login "$credentials" -c /dev/null -D - -o /dev/null -H 'x-forwarded-proto: https' |
  grep -i '^set-cookie:' || true)
redact() { sed -E 's/^([^=]*)=[^;]*/\1=<value>/' <<<"$1"; }
if [ -z "$plain" ] || grep -qi '; *secure' <<<"$plain"; then
  fail "cookies over plain HTTP: $(redact "$plain")"
fi
if [ -z "$tls" ] || grep -vqi '; *secure' <<<"$tls"; then
  fail "cookies behind a TLS proxy lack the Secure flag: $(redact "$tls")"
fi
ok "cookies are Secure behind a TLS proxy, and not over plain HTTP"

api POST /drawings '{"name": "broken", "elements": "not a list"}' | expect_status 400 "an invalid drawing" >/dev/null
scene='{"name": "e2e drawing", "appState": {"viewBackgroundColor": "#ffffff"}, "elements": [
  {"id": "e2e-rect", "type": "rectangle", "x": 10, "y": 20, "width": 200, "height": 100, "angle": 0,
   "strokeColor": "#1e1e1e", "backgroundColor": "transparent", "fillStyle": "solid", "strokeWidth": 2,
   "seed": 1, "version": 1, "versionNonce": 1, "isDeleted": false, "opacity": 100, "groupIds": []}]}'
drawing=$(api POST /drawings "$scene" | expect_status 200 "drawing creation" | jq -r .id)
[ -n "$drawing" ] && [ "$drawing" != null ] || fail "the created drawing has no id"
listing=$(api GET /drawings | expect_status 200 "listing")
[ "$(jq -r --arg id "$drawing" '.drawings[] | select(.id == $id) | .name' <<<"$listing")" = "e2e drawing" ] ||
  fail "the drawing is missing from the listing: $listing"
[ "$(api GET "/drawings/$drawing" | expect_status 200 "drawing" | jq -r '.elements[0].id')" = e2e-rect ] ||
  fail "the drawing does not read back with its element"
ok "an invalid drawing is refused, a valid one is created, listed and read back"

api GET /export/excalidash "" -o "$WORK/export.excalidash" | expect_status 200 "export" >/dev/null
python3 - "$WORK/export.excalidash" <<'EOF' || fail "the export is not an archive with the drawing"
import json, sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as archive:
    manifest = json.loads(archive.read("excalidash.manifest.json"))
    names = [d.get("name") for d in manifest["drawings"]]
    assert "e2e drawing" in names, names
    for d in manifest["drawings"]:
        archive.getinfo(d["filePath"])
EOF
token=$(curl -sSf -b "$JAR" -c "$JAR" "$API/csrf-token" | jq -r .token)
verify=$(curl -sS -b "$JAR" -H "x-csrf-token: $token" -F "archive=@$WORK/export.excalidash" "$API/import/excalidash/verify")
[ "$(jq -r '.valid and .drawings == 1' <<<"$verify")" = true ] || fail "the import check refuses the export: $verify"
ok "the export is an .excalidash archive that the import check accepts (staged in /app/uploads)"

if [ -n "$(k get networkpolicy -l "app.kubernetes.io/instance=$RELEASE" -o name)" ]; then
  PROBE=$RELEASE-e2e-probe
  k run "$PROBE" --image="$(k get deploy "$(component deploy frontend)" -o jsonpath='{.spec.template.spec.containers[0].image}')" \
    --restart=Never --labels=app.kubernetes.io/name=e2e-probe --command -- sleep 300 >/dev/null
  k wait --for=condition=Ready "pod/$PROBE" --timeout=120s >/dev/null
  k exec "$PROBE" -- wget -qO /dev/null -T 5 "http://$frontend:$frontend_port/" ||
    fail "another pod cannot reach the frontend"
  if k exec "$PROBE" -- wget -qO /dev/null -T 5 "http://$backend:$backend_port/health" 2>/dev/null; then
    fail "another pod reaches the backend despite the NetworkPolicy"
  fi
  ok "another pod reaches the frontend but not the backend (NetworkPolicy)"
fi

# Kept for the after-reinstall run, outside the release, so that helm uninstall leaves it.
printf '%s' "$email" >"$WORK/email"
printf '%s' "$password" >"$WORK/password"
printf '%s' "$drawing" >"$WORK/drawing"
k create secret generic "$state" --from-file="$WORK/email" --from-file="$WORK/password" \
  --from-file="$WORK/drawing" --from-file=cookies="$JAR" --dry-run=client -o yaml | k apply -f - >/dev/null

echo "All end-to-end checks passed"
