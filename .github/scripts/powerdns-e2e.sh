#!/usr/bin/env bash
# shellcheck disable=SC2016 # the $names in single quotes are jq variables
# End-to-end check of a powerdns release: the REST API refuses a missing or wrong key, creates a zone with its
# records and changes one; the authoritative server answers them over UDP and TCP, from another pod, and still
# answers after a restart (the zones are in the database); with the recursor, the same records resolve through it.
# Also checked: the server runs as uid 953 without any capability, the DNS Services only carry DNS, and with the
# NetworkPolicy a pod outside networkPolicy.apiAllowedFrom cannot reach the API. Each run creates its own zone,
# e2e-<timestamp>.example.test (the recursor of ci/default-values.yaml forwards example.test). The client pods
# stop by themselves after 10 minutes: nothing is deleted.
#
# usage: powerdns-e2e.sh <namespace> <release>
set -euo pipefail

NAMESPACE=$1
RELEASE=$2
PORT=${PORT:-18081}
# Any image with dig, wget and sleep.
CLIENT_IMAGE=${CLIENT_IMAGE:-docker.io/internetsystemsconsortium/bind9:9.20}
# Scratch files stay in a fresh temporary directory: nothing is deleted.
WORK=$(mktemp -d)
cleanup() { [ -n "${FORWARD_PID:-}" ] && kill "$FORWARD_PID" 2>/dev/null || true; }
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }
expect() { # description, expected, actual
  [ "$3" = "$2" ] || fail "$1: expected '$2', got '$3'"
  ok "$1"
}
kc() { kubectl -n "$NAMESPACE" "$@"; }
one() { kc get "$@" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true; }

selector="app.kubernetes.io/name=powerdns,app.kubernetes.io/instance=$RELEASE"
auth="$selector,app.kubernetes.io/component=authoritative"
recursor="$selector,app.kubernetes.io/component=recursor"
dns_service=$(one svc -l "$auth,!powerdns.unxwares.com/endpoint")
api_service=$(one svc -l "$auth,powerdns.unxwares.com/endpoint=webserver")
recursor_service=$(one svc -l "$recursor,!powerdns.unxwares.com/endpoint")
[ -n "$dns_service" ] && [ -n "$api_service" ] || fail "release $RELEASE not found in $NAMESPACE"
key_ref=$(kc get deploy "$dns_service" \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="PDNS_API_KEY")].valueFrom.secretKeyRef}')
KEY=$(kc get secret "$(jq -r .name <<<"$key_ref")" -o jsonpath="{.data.$(jq -r .key <<<"$key_ref")}" | base64 -d)
[ -n "$KEY" ] || fail "no API key"

# --- REST API, through a port-forward -------------------------------------------------------------------------------
api_port=$(kc get svc "$api_service" -o jsonpath='{.spec.ports[0].port}')
kc port-forward "svc/$api_service" "$PORT:$api_port" >"$WORK/forward.log" 2>&1 &
FORWARD_PID=$!
API="http://127.0.0.1:$PORT/api/v1/servers/localhost"
for _ in $(seq 30); do
  curl -s -o /dev/null "$API" && break
  sleep 1
done
call() { # expected HTTP status, key, curl arguments: prints the body
  local code
  code=$(curl -sS -o "$WORK/body" -w '%{http_code}' -H "X-API-Key: $2" -H 'content-type: application/json' "${@:3}")
  [ "$code" = "$1" ] || fail "HTTP $code instead of $1 on ${*:3}: $(head -c 300 "$WORK/body")"
  cat "$WORK/body"
}
server=$(call 200 "$KEY" "$API")
expect "the API answers with the key" "authoritative" "$(jq -r .daemon_type <<<"$server")"
call 401 "" "$API" >/dev/null
ok "the API refuses a request without a key"
call 401 "wrong-$KEY" "$API" >/dev/null
ok "the API refuses a wrong key"

zone="e2e-$(date +%s).example.test."
records=$(jq -n --arg z "$zone" '{name: $z, kind: "Native", nameservers: ["ns1.example.test."], rrsets: [
  {name: ("www." + $z), type: "A", ttl: 60, records: [{content: "192.0.2.10", disabled: false}]},
  {name: ("www." + $z), type: "AAAA", ttl: 60, records: [{content: "2001:db8::10", disabled: false}]},
  {name: $z, type: "MX", ttl: 60, records: [{content: ("10 mail." + $z), disabled: false}]},
  {name: $z, type: "TXT", ttl: 60, records: [{content: "\"e2e\"", disabled: false}]}]}')
call 401 "wrong-$KEY" -X POST "$API/zones" -d "$records" >/dev/null
call 404 "$KEY" "$API/zones/$zone" >/dev/null
ok "a zone sent with a wrong key is refused and not created"
created=$(call 201 "$KEY" -X POST "$API/zones" -d "$records")
expect "a zone is created through the API" "$zone" "$(jq -r .name <<<"$created")"
expect "the zone is read back through the API" "192.0.2.10" \
  "$(call 200 "$KEY" "$API/zones/$zone" | jq -r --arg n "www.$zone" '.rrsets[] | select(.name == $n and .type == "A") | .records[0].content')"
call 204 "$KEY" -X PATCH "$API/zones/$zone" -d "$(jq -n --arg n "api.$zone" \
  '{rrsets: [{name: $n, type: "A", ttl: 60, changetype: "REPLACE", records: [{content: "192.0.2.30", disabled: false}]}]}')" >/dev/null
ok "a record is added to the zone through the API"

# --- DNS, from another pod ------------------------------------------------------------------------------------------
# A client pod that complies with the restricted Pod Security Standard. Prints its name.
client() { # name, labels (YAML flow mapping)
  local pod
  pod=$(kc create -o name -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  generateName: $RELEASE-e2e-$1-
  labels: $2
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  nodeSelector: { kubernetes.io/arch: amd64 }
  securityContext: { runAsNonRoot: true, runAsUser: 53, runAsGroup: 53, seccompProfile: { type: RuntimeDefault } }
  containers:
    - name: client
      image: $CLIENT_IMAGE
      command: [sleep, "600"]
      securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: [ALL] } }
EOF
  )
  kc wait --for=condition=Ready "$pod" --timeout=180s >/dev/null
  echo "${pod#pod/}"
}
client_pod=$(client client '{ app.kubernetes.io/name: powerdns-e2e-client }')

q() { # server, dig arguments: short answer, one line, sorted
  kc exec "$client_pod" -- dig +time=3 +tries=2 "@$1" +short "${@:2}" | sort | paste -sd' ' -
}
status() { # server, dig arguments: response code and flags
  kc exec "$client_pod" -- dig +time=3 +tries=2 "@$1" "${@:2}" |
    sed -n 's/.*status: \([A-Z]*\),.*/\1/p; s/.*;; flags: \([a-z ]*\);.*/\1/p' | paste -sd' ' -
}
check_auth() { # suffix of the descriptions
  for transport in +notcp +tcp; do
    expect "authoritative: A record ($transport)$1" "192.0.2.10" "$(q "$dns_service" "$transport" "www.$zone" A)"
  done
  expect "authoritative: AAAA record$1" "2001:db8::10" "$(q "$dns_service" "www.$zone" AAAA)"
  expect "authoritative: MX record$1" "10 mail.$zone" "$(q "$dns_service" "$zone" MX)"
  expect "authoritative: TXT record$1" '"e2e"' "$(q "$dns_service" "$zone" TXT)"
  expect "authoritative: record added through the API$1" "192.0.2.30" "$(q "$dns_service" "api.$zone" A)"
  expect "authoritative: the answers are authoritative$1" "NOERROR qr aa" "$(status "$dns_service" +norecurse "www.$zone" A)"
  expect "authoritative: unknown name, NXDOMAIN$1" "NXDOMAIN qr aa" "$(status "$dns_service" +norecurse "missing.$zone" A)"
}
check_auth ""
if [ -n "$recursor_service" ]; then
  expect "recursor: A record resolved through the authoritative server" "192.0.2.10" "$(q "$recursor_service" "www.$zone" A)"
  expect "recursor: record added through the API" "192.0.2.30" "$(q "$recursor_service" "api.$zone" A)"
  expect "recursor: recursive answer" "NOERROR qr rd ra" "$(status "$recursor_service" "www.$zone" AAAA)"
fi

# --- Security -------------------------------------------------------------------------------------------------------
pdns_pod=$(one pod -l "$auth" --field-selector=status.phase=Running)
proc=$(kc exec "$pdns_pod" -c pdns -- cat /proc/1/status)
expect "the server runs as uid 953" "953 953 953 953" "$(awk '/^Uid:/ {print $2, $3, $4, $5}' <<<"$proc")"
expect "the server has no capability" "0000000000000000 0000000000000000" \
  "$(awk '/^CapPrm:|^CapEff:/ {print $2}' <<<"$proc" | paste -sd' ' -)"
ports() { kc get svc "$1" -o jsonpath='{.spec.ports[*].name}' | tr ' ' '\n' | sort | paste -sd' ' -; }
expect "the DNS Service only carries DNS" "dns-tcp dns-udp" "$(ports "$dns_service")"
if [ -n "$recursor_service" ]; then
  expect "the recursor DNS Service only carries DNS" "dns-tcp dns-udp" "$(ports "$recursor_service")"
fi
if [ -n "$(kc get networkpolicy -l "$selector" -o name)" ]; then
  allowed_pod=$(client api '{ app.kubernetes.io/name: powerdns-e2e-client, e2e.unxwares.com/api: "true" }')
  reach() { kc exec "$1" -- wget -q -T 5 -O /dev/null "http://$api_service:$api_port/api/v1/servers/localhost" 2>&1 || true; }
  grep -q '401' <<<"$(reach "$allowed_pod")" || fail "a pod of networkPolicy.apiAllowedFrom does not reach the API"
  ok "a pod of networkPolicy.apiAllowedFrom reaches the API (and needs the key)"
  if grep -q '401' <<<"$(reach "$client_pod")"; then
    fail "a pod outside networkPolicy.apiAllowedFrom reaches the API"
  fi
  ok "a pod outside networkPolicy.apiAllowedFrom cannot reach the API, and still gets DNS answers"
fi

# --- The zone survives a restart ------------------------------------------------------------------------------------
old_pods=$(kc get pod -l "$auth" -o name)
kc rollout restart "deploy/$dns_service" >/dev/null
kc rollout status "deploy/$dns_service" --timeout=300s >/dev/null
# The old pod may still be terminating, and the Service endpoints take a moment to follow.
for pod in $old_pods; do kc wait --for=delete "$pod" --timeout=120s >/dev/null 2>&1 || true; done
for _ in $(seq 15); do
  [ "$(q "$dns_service" "www.$zone" A 2>/dev/null)" = "192.0.2.10" ] && break
  sleep 2
done
check_auth " after a restart"

echo "All end-to-end checks passed"
