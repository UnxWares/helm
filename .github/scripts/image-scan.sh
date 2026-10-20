#!/usr/bin/env bash
# Scan every image declared in the charts' artifacthub.io/images annotation with
# Trivy and print a Markdown summary (what Artifact Hub shows in its security report).
#
# usage: .github/scripts/image-scan.sh [chart-dir ...]
# env:   TRIVY (default: trivy)
set -euo pipefail

TRIVY=${TRIVY:-trivy}
cd "$(dirname "$0")/../.."
charts=("$@")
[ ${#charts[@]} -gt 0 ] || charts=(charts/*/)

images=$(python3 - "${charts[@]}" <<'PY'
import sys, yaml, pathlib
for d in sys.argv[1:]:
    meta = yaml.safe_load((pathlib.Path(d) / "Chart.yaml").read_text())
    raw = (meta.get("annotations") or {}).get("artifacthub.io/images", "")
    for img in yaml.safe_load(raw) or []:
        print(f"{meta['name']}\t{img['image']}")
PY
)

echo "| Chart | Image | Critical | High | Medium | Low | Fixable C/H |"
echo "|---|---|---:|---:|---:|---:|---:|"
status=0
while IFS=$'\t' read -r chart image; do
  [ -n "$image" ] || continue
  report=$(mktemp)
  if ! "$TRIVY" image --quiet --scanners vuln --format json -o "$report" "$image" >/dev/null 2>&1; then
    echo "| $chart | \`$image\` | scan failed | | | | |"; status=1; rm -f "$report"; continue
  fi
  python3 - "$report" "$chart" "$image" <<'PY'
import json, sys, collections
d = json.load(open(sys.argv[1]))
vulns = [v for r in d.get("Results", []) for v in r.get("Vulnerabilities") or []]
c = collections.Counter(v["Severity"] for v in vulns)
fixable = sum(1 for v in vulns if v["Severity"] in ("CRITICAL", "HIGH") and v.get("FixedVersion"))
print(f"| {sys.argv[2]} | `{sys.argv[3]}` | {c['CRITICAL']} | {c['HIGH']} | {c['MEDIUM']} | {c['LOW']} | {fixable} |")
PY
  rm -f "$report"
done <<< "$images"
exit $status
