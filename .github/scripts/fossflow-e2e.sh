#!/usr/bin/env bash
# End-to-end check of a fossflow release, through its Service.
# - Both modes: the web app and its scripts are served, the container runs without root on a read-only root
#   filesystem, the backend port (3001) cannot be reached from another pod, and, when the release has a
#   NetworkPolicy with allowed peers, a pod that is not one of them cannot reach FossFLOW at all.
# - Server storage: a diagram is created, listed, read back, updated, and is still there after the pod is replaced;
#   the API sends no CORS header to another site.
# - Browser-only: no backend answers behind /api/.
#
# usage: fossflow-e2e.sh <namespace> <release>
set -euo pipefail

NAMESPACE=$1
RELEASE=$2
# One local port per release: the script runs once per release, and a port-forward that is still stopping must not
# answer for the next release.
PORT=$((15380 + $(printf '%s' "$RELEASE" | cksum | cut -d' ' -f1) % 90))
BASE="http://127.0.0.1:$PORT"
# Scratch files stay in a fresh temporary directory: nothing is deleted.
WORK=$(mktemp -d)
stop_forward() {
  if [ -n "${FORWARD_PID:-}" ]; then
    # The forward exits on TERM (status 143): neither this nor kill may fail the script under set -e.
    kill "$FORWARD_PID" 2>/dev/null || true
    wait "$FORWARD_PID" 2>/dev/null || true
  fi
  true
}
trap stop_forward EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }

deployment=$(kubectl -n "$NAMESPACE" get deploy -l "app.kubernetes.io/instance=$RELEASE" -o jsonpath='{.items[0].metadata.name}')
kubectl -n "$NAMESPACE" get deploy "$deployment" -o json >"$WORK/deployment.json"
selector=$(jq -r '.spec.selector.matchLabels | to_entries | map("\(.key)=\(.value)") | join(",")' "$WORK/deployment.json")
container=$(jq -c '.spec.template.spec.containers[0]' "$WORK/deployment.json")
image=$(jq -r .image <<<"$container")
http_port=$(jq -r '.ports[] | select(.name == "http") | .containerPort' <<<"$container")
storage=$(jq -r '.env[] | select(.name == "ENABLE_SERVER_STORAGE") | .value' <<<"$container")
service=$(kubectl -n "$NAMESPACE" get svc -l "app.kubernetes.io/instance=$RELEASE" -o jsonpath='{.items[0].metadata.name}')
service_port=$(kubectl -n "$NAMESPACE" get svc "$service" -o jsonpath='{.spec.ports[0].port}')

# (Re)starts the port-forward to the Service and waits for the web app.
forward() {
  stop_forward
  kubectl -n "$NAMESPACE" port-forward "svc/$service" "$PORT:$service_port" >"$WORK/forward.log" 2>&1 &
  FORWARD_PID=$!
  for _ in $(seq 60); do
    curl -sf -o /dev/null "$BASE/" && return 0
    sleep 1
  done
  fail "no answer through the Service: $(cat "$WORK/forward.log")"
}

# Runs a shell command in a new pod of the namespace (image of the release, restricted Pod Security profile) and
# prints its output.
# usage: in_new_pod <pod name> <labels, or ""> <command>
in_new_pod() {
  local overrides phase=""
  overrides=$(jq -cn --arg name "$1" '{spec: {automountServiceAccountToken: false, enableServiceLinks: false,
    securityContext: {runAsNonRoot: true, runAsUser: 65534, runAsGroup: 65534, seccompProfile: {type: "RuntimeDefault"}},
    containers: [{name: $name, securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true,
      capabilities: {drop: ["ALL"]}}}]}}')
  kubectl -n "$NAMESPACE" delete pod "$1" --ignore-not-found >/dev/null
  kubectl -n "$NAMESPACE" run "$1" --image "$image" --image-pull-policy IfNotPresent --restart Never \
    ${2:+--labels "$2"} --override-type strategic --overrides "$overrides" --command -- sh -c "$3" >/dev/null
  for _ in $(seq 120); do
    phase=$(kubectl -n "$NAMESPACE" get pod "$1" -o jsonpath='{.status.phase}')
    case $phase in Succeeded | Failed) break ;; esac
    sleep 1
  done
  kubectl -n "$NAMESPACE" logs "$1"
  kubectl -n "$NAMESPACE" delete pod "$1" --wait=false >/dev/null
  [ "$phase" = Succeeded ] || fail "the pod $1 ended in phase '$phase'"
}

forward

# --- Web app --------------------------------------------------------------------------------------------------------
curl -sSf -o "$WORK/index.html" "$BASE/" || fail "/ does not answer"
grep -q '<title>FossFLOW' "$WORK/index.html" || fail "/ is not the FossFLOW web app: $(head -c 300 "$WORK/index.html")"
scripts=$(grep -o 'src="/static/js/[^"]*\.js"' "$WORK/index.html" | sed -e 's/^src="//' -e 's/"$//')
[ -n "$scripts" ] || fail "index.html references no script"
for script in $scripts; do
  type=$(curl -sSf -o /dev/null -w '%{content_type}' "$BASE$script") || fail "$script is not served"
  case $type in application/javascript* | text/javascript*) ;; *) fail "$script is served as '$type'" ;; esac
done
ok "the web app and its $(wc -w <<<"$scripts") scripts are served through the Service"
curl -sSf -o "$WORK/route.html" "$BASE/diagram/e2e" || fail "a client-side route does not answer"
grep -q '<title>FossFLOW' "$WORK/route.html" || fail "a client-side route does not serve the web app"
ok "client-side routes serve the web app"

# --- Diagrams -------------------------------------------------------------------------------------------------------
if [ "$storage" = true ]; then
  status=$(curl -sSf "$BASE/api/storage/status") || fail "/api/storage/status does not answer"
  [ "$(jq -r .enabled <<<"$status")" = true ] || fail "server storage is not enabled: $status"
  ok "server storage is enabled"

  id="e2e-$(date +%s)-$RANDOM"
  diagram=$(jq -cn --arg id "$id" '{id: $id, name: "End-to-end diagram", version: "1.0",
    items: [{id: "server", name: "Server", icon: "server"}],
    views: [{id: "view", name: "Main view", items: [{id: "server", tile: {x: 2, y: 3}}]}]}')
  # The backend keeps the diagram and adds its own fields (id, created, lastModified).
  same_diagram() { jq -e --argjson want "$diagram" '{name, items, views} == ($want | {name, items, views})' >/dev/null; }

  code=$(curl -sS -o "$WORK/created.json" -w '%{http_code}' -X POST -H 'content-type: application/json' \
    -d "$diagram" "$BASE/api/diagrams")
  [ "$code" = 201 ] && [ "$(jq -r .id "$WORK/created.json")" = "$id" ] ||
    fail "creating a diagram answered $code: $(cat "$WORK/created.json")"
  ok "a diagram is created"

  listing=$(curl -sSf "$BASE/api/diagrams") || fail "the diagrams cannot be listed"
  [ "$(jq -r --arg id "$id" '.[] | select(.id == $id) | .name' <<<"$listing")" = "End-to-end diagram" ] ||
    fail "the diagram is missing from the listing: $listing"
  ok "the diagram is listed with its name"

  curl -sSf "$BASE/api/diagrams/$id" >"$WORK/read.json" || fail "the diagram cannot be read back"
  same_diagram <"$WORK/read.json" || fail "the diagram read back differs: $(cat "$WORK/read.json")"
  ok "the diagram reads back unchanged"

  diagram=$(jq -c '.name = "Renamed diagram" | .items[0].name = "Database"' <<<"$diagram")
  curl -sSf -o /dev/null -X PUT -H 'content-type: application/json' -d "$diagram" "$BASE/api/diagrams/$id" ||
    fail "the update of the diagram is refused"
  curl -sSf "$BASE/api/diagrams/$id" >"$WORK/read.json" || fail "the updated diagram cannot be read back"
  same_diagram <"$WORK/read.json" || fail "the updated diagram reads back differently: $(cat "$WORK/read.json")"
  ok "an update is saved and read back"

  headers=$(curl -sS -D - -o /dev/null -H 'Origin: https://other-site.example' "$BASE/api/diagrams")
  if grep -qi '^access-control-allow-origin' <<<"$headers"; then
    fail "the API lets another site read the diagrams: $headers"
  fi
  headers=$(curl -sS -D - -o /dev/null -X OPTIONS -H 'Origin: https://other-site.example' \
    -H 'Access-Control-Request-Method: DELETE' "$BASE/api/diagrams/$id")
  if grep -qi '^access-control-allow' <<<"$headers"; then
    fail "the API accepts a preflight request from another site: $headers"
  fi
  ok "the API sends no CORS header to another site (reads and preflight)"

  kubectl -n "$NAMESPACE" rollout restart "deploy/$deployment" >/dev/null
  kubectl -n "$NAMESPACE" rollout status "deploy/$deployment" --timeout=300s >/dev/null
  forward
  curl -sSf "$BASE/api/diagrams/$id" >"$WORK/read.json" || fail "the diagram is gone after the pod was replaced"
  same_diagram <"$WORK/read.json" || fail "the diagram changed after the pod was replaced: $(cat "$WORK/read.json")"
  ok "the diagram is still there after the pod is replaced"
else
  code=$(curl -sS -o /dev/null -w '%{http_code}' "$BASE/api/storage/status")
  [ "$code" = 502 ] || fail "browser-only mode: /api/storage/status answered $code, expected 502 (no backend)"
  ok "browser-only mode: no backend answers behind /api/"
fi

# --- Container and network ------------------------------------------------------------------------------------------
pod=$(kubectl -n "$NAMESPACE" get pods -l "$selector" --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}')
pod_ip=$(kubectl -n "$NAMESPACE" get pod "$pod" -o jsonpath='{.status.podIP}')
identity=$(kubectl -n "$NAMESPACE" exec "$pod" -- sh -c 'id -u; touch /e2e-write-test 2>/dev/null && echo writable || echo read-only')
[ "$(head -1 <<<"$identity")" != 0 ] || fail "the container runs as root"
[ "$(tail -1 <<<"$identity")" = read-only ] || fail "the root filesystem of the container is writable"
ok "the container runs as uid $(head -1 <<<"$identity") on a read-only root filesystem"

reach="reach() { wget -q -T 5 -O /dev/null \"\$1\" 2>/dev/null && echo open || echo closed; }"
reach="$reach; echo web=\$(reach http://$pod_ip:$http_port/) backend=\$(reach http://$pod_ip:3001/api/storage/status)"
# A pod of the release, an allowed peer of the NetworkPolicy if there is one. Without NetworkPolicy, a closed backend
# port means that the backend only listens on 127.0.0.1; with one, the policy closes it too.
result=$(in_new_pod "$RELEASE-e2e-peer" "app.kubernetes.io/instance=$RELEASE" "$reach")
[ "$result" = "web=open backend=closed" ] ||
  fail "from another pod, expected the web port open and the backend port closed, got: $result"
ok "from another pod, the web port answers and the backend port does not"

# With networkPolicy.ingressFrom set, only those peers and the pods of the release may reach FossFLOW.
policy_peers=$(kubectl -n "$NAMESPACE" get networkpolicy -l "app.kubernetes.io/instance=$RELEASE" -o json |
  jq '[.items[].spec.ingress[]?.from // empty] | length')
if [ "$policy_peers" -gt 0 ]; then
  result=$(in_new_pod "$RELEASE-e2e-outsider" "" "$reach")
  [ "$result" = "web=closed backend=closed" ] ||
    fail "a pod that is not an allowed peer of the NetworkPolicy reaches FossFLOW: $result"
  ok "the NetworkPolicy keeps out a pod that is not an allowed peer"
fi

echo "All end-to-end checks passed"
