#!/usr/bin/env bash
# End-to-end check of a bind9 release installed with charts/bind9/ci/default-values.yaml, from other pods of the
# namespace: the zones of the values answer the expected records over UDP and TCP, authoritatively; other zones,
# zone transfers and the version are refused; named runs as uid 53 without any capability; the DNS Service only
# carries DNS; the exporter reports bind_up 1 to a pod the NetworkPolicy allows, and a pod it does not allow cannot
# reach it. The client pods stop by themselves after 10 minutes: nothing is deleted.
#
# usage: bind9-e2e.sh <namespace> <release>
set -euo pipefail

NAMESPACE=$1
RELEASE=$2
# Any image with dig, wget and sleep: the UnxWares BIND image, as the chart (CI passes the one it built).
CLIENT_IMAGE=${CLIENT_IMAGE:-ghcr.io/unxwares/bind9:9.20.30}

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }
expect() { # description, expected, actual
  [ "$3" = "$2" ] || fail "$1: expected '$2', got '$3'"
  ok "$1"
}
kc() { kubectl -n "$NAMESPACE" "$@"; }

selector="app.kubernetes.io/name=bind9,app.kubernetes.io/instance=$RELEASE"
dns_service=$(kc get svc -l "$selector,!bind9.unxwares.com/endpoint" -o jsonpath='{.items[0].metadata.name}')
admin_service=$(kc get svc -l "$selector,bind9.unxwares.com/endpoint=admin" -o jsonpath='{.items[0].metadata.name}')
named_pod=$(kc get pod -l "$selector,!app.kubernetes.io/component" --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}')
[ -n "$dns_service" ] && [ -n "$admin_service" ] && [ -n "$named_pod" ] || fail "release $RELEASE not found in $NAMESPACE"

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
client_pod=$(client client '{ app.kubernetes.io/name: bind9-e2e-client }')
admin_pod=$(client admin '{ app.kubernetes.io/name: bind9-e2e-client, e2e.unxwares.com/admin: "true" }')

q() { # dig arguments: short answer, one line, sorted
  kc exec "$client_pod" -- dig +time=3 +tries=2 "@$dns_service" +short "$@" | sort | paste -sd' ' -
}
status() { # dig arguments: response code and flags of a non-recursive query
  kc exec "$client_pod" -- dig +time=3 +tries=2 +norecurse "@$dns_service" "$@" |
    sed -n 's/.*status: \([A-Z]*\),.*/\1/p; s/.*;; flags: \([a-z ]*\);.*/\1/p' | paste -sd' ' -
}

for transport in +notcp +tcp; do
  expect "A record ($transport)" "192.0.2.10" "$(q "$transport" www.example.test A)"
  expect "AAAA record ($transport)" "2001:db8::10" "$(q "$transport" www.example.test AAAA)"
done
expect "MX record" "10 mail.example.test." "$(q example.test MX)"
expect "TXT record" '"v=spf1 -all"' "$(q example.test TXT)"
expect "CNAME followed in the zone" "192.0.2.10 www.example.test." "$(q docs.example.test A)"
expect "SOA serial" "2026110201" "$(q example.test SOA | cut -d' ' -f3)"
expect "PTR record of the second zone" "www.example.test." "$(q -x 192.0.2.10)"
expect "answers are authoritative" "NOERROR qr aa" "$(status www.example.test A)"
expect "unknown name: authoritative NXDOMAIN" "NXDOMAIN qr aa" "$(status missing.example.test A)"
expect "zone not served: REFUSED" "REFUSED qr" "$(status example.org A)"
axfr=$(kc exec "$client_pod" -- dig +time=3 +tries=1 "@$dns_service" example.test AXFR || true)
grep -q 'Transfer failed' <<<"$axfr" || fail "zone transfer not refused: $axfr"
ok "zone transfers are refused"
[ -z "$(q version.bind TXT CH)" ] || fail "version.bind reveals the version: $(q version.bind TXT CH)"
ok "the version is not revealed"

proc=$(kc exec "$named_pod" -c bind9 -- cat /proc/1/status)
expect "named runs as uid 53" "53 53 53 53" "$(awk '/^Uid:/ {print $2, $3, $4, $5}' <<<"$proc")"
expect "named has no capability" "0000000000000000 0000000000000000" "$(awk '/^CapPrm:|^CapEff:/ {print $2}' <<<"$proc" | paste -sd' ' -)"

expect "the DNS Service only carries DNS" "dns-tcp dns-udp" \
  "$(kc get svc "$dns_service" -o jsonpath='{.spec.ports[*].name}' | tr ' ' '\n' | sort | paste -sd' ' -)"
expect "the admin Service carries the metrics" "metrics" "$(kc get svc "$admin_service" -o jsonpath='{.spec.ports[*].name}')"
port=$(kc get svc "$admin_service" -o jsonpath='{.spec.ports[?(@.name=="metrics")].port}')

metrics=$(kc exec "$admin_pod" -- wget -q -T 10 -O - "http://$admin_service:$port/metrics")
grep -qx 'bind_up 1' <<<"$metrics" || fail "the exporter does not report bind_up 1"
ok "the exporter reads named's statistics (bind_up 1)"
queries=$(awk '/^bind_incoming_queries_total\{type="AAAA"\}/ {print $2}' <<<"$metrics")
[ -n "$queries" ] && [ "${queries%%.*}" -ge 2 ] 2>/dev/null || fail "AAAA queries not counted: '$queries'"
ok "the exporter counts the queries ($queries AAAA)"

if [ -n "$(kc get networkpolicy -l "$selector" -o name)" ]; then
  if kc exec "$client_pod" -- wget -q -T 5 -O /dev/null "http://$admin_service:$port/metrics" 2>/dev/null; then
    fail "a pod outside networkPolicy.adminAllowedFrom reaches the metrics"
  fi
  ok "a pod outside networkPolicy.adminAllowedFrom cannot reach the metrics, and still gets DNS answers"
fi

echo "All end-to-end checks passed"
