#!/usr/bin/env bash
# Regenerate the hash-pinned requirements.txt of a Python image from its requirements.in, inside the
# image's own base (same Python version and platform as the build).
#
# usage: images/lock.sh <image directory>   e.g. images/lock.sh images/taiga-back
# env:   CONTAINER (default: docker; podman works too)
set -euo pipefail

dir=$(cd "$1" && pwd)
base=$(grep -m1 -E '^FROM ' "$dir/Dockerfile" | awk '{print $2}')
"${CONTAINER:-docker}" run --rm -v "$dir:/work:z" -w /work "$base" sh -euc '
  # Headers to build the metadata of source-only packages (psycopg2 needs pg_config).
  if command -v apk >/dev/null; then apk add -q --no-cache build-base libpq-dev libffi-dev; fi
  pip install -q --root-user-action=ignore pip-tools
  pip-compile -q --generate-hashes --allow-unsafe --strip-extras --no-emit-index-url \
    --output-file requirements.txt requirements.in'
