#!/usr/bin/env bash
# shellcheck disable=SC2016 # the $names in single quotes are jq variables
# End-to-end check of a fresh cloudreve release, through its Service: the first account signs up and becomes
# administrator, logs in, uploads a file, finds it in the listing, downloads the same content back, and gets a
# thumbnail generated for an uploaded image.
#
# usage: cloudreve-e2e.sh <namespace> <release>
set -euo pipefail

NAMESPACE=$1
RELEASE=$2
PORT=15212
API="http://127.0.0.1:$PORT/api/v4"
# Scratch files stay in a fresh temporary directory: nothing is deleted.
WORK=$(mktemp -d)
cleanup() { [ -n "${FORWARD_PID:-}" ] && kill "$FORWARD_PID" 2>/dev/null || true; }
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }
# Cloudreve answers 200 with {"code": <non-zero>} on errors: check the code, return the data.
api() {
  local response
  response=$(curl -sS "$@")
  [ "$(jq -r .code <<<"$response")" = 0 ] || fail "API error on $*: $response"
  jq -c .data <<<"$response"
}
# Signed URLs carry the site URL: keep their path, through the port-forward.
local_url() { echo "http://127.0.0.1:$PORT/${1#*://*/}"; }

service=$(kubectl -n "$NAMESPACE" get svc -l "app.kubernetes.io/instance=$RELEASE" -o jsonpath='{.items[0].metadata.name}')
port=$(kubectl -n "$NAMESPACE" get svc "$service" -o jsonpath='{.spec.ports[0].port}')
kubectl -n "$NAMESPACE" port-forward "svc/$service" "$PORT:$port" >"$WORK/forward.log" 2>&1 &
FORWARD_PID=$!
for _ in $(seq 60); do
  curl -sf "$API/site/ping" >/dev/null && break
  sleep 1
done
[ "$(api "$API/site/ping" | jq -r .)" != "" ] || fail "no answer on /api/v4/site/ping"
ok "the API answers ($(api "$API/site/ping" | jq -r .))"

email=e2e-admin@example.test
password="E2e-$(head -c 12 /dev/urandom | base64 | tr -d '/+=')"
json() { jq -n "$@"; }
api -X POST -H 'content-type: application/json' "$API/user" \
  -d "$(json --arg e "$email" --arg p "$password" '{email: $e, password: $p, language: "en-US"}')" >/dev/null
session=$(api -X POST -H 'content-type: application/json' "$API/session/token" \
  -d "$(json --arg e "$email" --arg p "$password" '{email: $e, password: $p}')")
[ "$(jq -r .user.group.name <<<"$session")" = Admin ] || fail "the first account is not in the Admin group: $session"
ok "the first account signs up, logs in and is administrator"
auth=(-H "Authorization: Bearer $(jq -r .token.access_token <<<"$session")")

upload() { # local file, remote name, mime type
  local size upload_session
  size=$(stat -c %s "$1")
  upload_session=$(api -X PUT "${auth[@]}" -H 'content-type: application/json' "$API/file/upload" \
    -d "$(json --arg uri "cloudreve://my/$2" --argjson size "$size" --arg mime "$3" \
      '{uri: $uri, size: $size, last_modified: 1700000000000, mime_type: $mime}')")
  api -X POST "${auth[@]}" -H 'content-type: application/octet-stream' --data-binary "@$1" \
    "$API/file/upload/$(jq -r .session_id <<<"$upload_session")/0" >/dev/null
}

printf 'end-to-end content %s\n' "$(date +%s%N)" >"$WORK/hello.txt"
upload "$WORK/hello.txt" hello.txt text/plain
listing=$(api "${auth[@]}" "$API/file?uri=cloudreve%3A%2F%2Fmy%2F&page=0&page_size=50")
[ "$(jq -r '.files[] | select(.name == "hello.txt") | .size' <<<"$listing")" = "$(stat -c %s "$WORK/hello.txt")" ] ||
  fail "hello.txt is missing from the listing or has the wrong size: $listing"
ok "an uploaded file is listed with its size"

url=$(api -X POST "${auth[@]}" -H 'content-type: application/json' "$API/file/url" \
  -d '{"uris": ["cloudreve://my/hello.txt"], "download": true}' | jq -r '.urls[0].url')
curl -sSf -o "$WORK/download.bin" "$(local_url "$url")"
cmp -s "$WORK/hello.txt" "$WORK/download.bin" || fail "the downloaded file differs from the uploaded one"
ok "the file downloads back unchanged"

python3 - "$WORK/image.png" <<'EOF'
import struct, sys, zlib
w = h = 64
raw = b"".join(b"\x00" + b"".join(bytes([(x * 4) % 256, (y * 4) % 256, 128]) for x in range(w)) for y in range(h))
chunk = lambda t, d: struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
with open(sys.argv[1], "wb") as f:
    f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))
EOF
upload "$WORK/image.png" image.png image/png
thumb=""
for _ in $(seq 30); do
  thumb=$(curl -sS "${auth[@]}" "$API/file/thumb?uri=cloudreve%3A%2F%2Fmy%2Fimage.png" | jq -r '.data.url // empty')
  [ -n "$thumb" ] && break
  sleep 2
done
[ -n "$thumb" ] || fail "no thumbnail was generated"
curl -sSf -o "$WORK/thumb.bin" "$(local_url "$thumb")"
head -c 8 "$WORK/thumb.bin" | od -An -tx1 | grep -qE '89 50 4e 47|ff d8 ff|52 49 46 46' || fail "the thumbnail is not an image"
ok "a thumbnail is generated for an uploaded image"

echo "All end-to-end checks passed"
