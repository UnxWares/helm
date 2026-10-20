#!/usr/bin/env bash
# Regenerate values.schema.json (from the `# @schema` annotations of values.yaml) and README.md
# (from README.md.gotmpl and the `# --` comments) for every chart, or for the charts given as arguments.
# CI fails when the committed files differ from what this script produces.
#
# usage: ./generate-schemas.sh [chart ...]
# needs: helm-values-schema-json v2.6.0
#          helm plugin install https://github.com/losisin/helm-values-schema-json.git --version v2.6.0
#        helm-docs v1.14.2 (https://github.com/norwoodj/helm-docs/releases/tag/v1.14.2)
# env:   SCHEMA (default: "helm schema"), HELM_DOCS (default: helm-docs)
set -euo pipefail

cd "$(dirname "$0")"
read -r -a schema <<<"${SCHEMA:-helm schema}"
helm_docs=${HELM_DOCS:-helm-docs}

charts=("$@")
[ ${#charts[@]} -gt 0 ] || charts=(charts/*/)
for chart in "${charts[@]}"; do
  chart=${chart%/}
  [ -d "$chart" ] || chart=charts/$chart
  echo "==> $chart"
  (cd "$chart" && "${schema[@]}" -f values.yaml -o values.schema.json --use-helm-docs --draft 7 >/dev/null)
  (cd "$chart" && "$helm_docs" --chart-search-root . --template-files README.md.gotmpl --log-level warning)
done
