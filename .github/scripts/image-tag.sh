#!/usr/bin/env bash
# Print the version of an image directory of images/: the first `ARG VERSION=` of its Dockerfile.
#
# usage: .github/scripts/image-tag.sh <image directory>
set -euo pipefail

version=$(sed -n 's/^ARG VERSION=//p' "$1/Dockerfile" | head -1)
if [ -z "$version" ]; then
  echo "no ARG VERSION in $1/Dockerfile" >&2
  exit 1
fi
echo "$version"
