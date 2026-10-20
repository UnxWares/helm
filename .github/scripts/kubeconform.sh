#!/usr/bin/env bash
# Render every chart (default values + each ci/*-values.yaml) and validate the
# manifests against the Kubernetes OpenAPI schemas and the CRDs catalog.
#
# usage: .github/scripts/kubeconform.sh [kubernetes-version ...]
# env:   HELM (default: helm), KUBECONFORM (default: kubeconform)
set -euo pipefail

HELM=${HELM:-helm}
KUBECONFORM=${KUBECONFORM:-kubeconform}
versions=("$@")
[ ${#versions[@]} -gt 0 ] || versions=(1.31.0 1.34.0)

cd "$(dirname "$0")/../.."
status=0
for chart in charts/*/; do
  chart=${chart%/}
  value_files=("")
  if [ -d "$chart/ci" ]; then
    for f in "$chart"/ci/*-values.yaml; do value_files+=("$f"); done
  fi
  for values in "${value_files[@]}"; do
    args=()
    [ -n "$values" ] && args=(-f "$values")
    label="$chart${values:+ ($(basename "$values"))}"
    if ! manifests=$("$HELM" template ci-release "$chart" --namespace ci "${args[@]}" 2>&1); then
      # Charts may refuse to render without user input (required image, database password...):
      # their ci/ values files are validated instead.
      if [ -z "$values" ] && [ ${#value_files[@]} -gt 1 ] && grep -q 'execution error at' <<<"$manifests"; then
        echo "::notice::$label: needs user values ($(grep -o 'execution error at [^)]*): .*' <<<"$manifests" | head -1 | sed 's/^[^)]*): //')), validated through ci/ only"
        continue
      fi
      echo "::error::$label: helm template failed"; echo "$manifests"; status=1; continue
    fi
    for v in "${versions[@]}"; do
      if ! out=$(echo "$manifests" | "$KUBECONFORM" -strict -summary -kubernetes-version "$v" \
          -schema-location default \
          -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' 2>&1); then
        echo "::error::$label: kubeconform failed for Kubernetes $v"; status=1
      fi
      echo "$label [k8s $v]: $(echo "$out" | tail -1)"
      echo "$out" | grep -v '^Summary' || true
    done
  done
done
exit $status
