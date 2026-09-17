#!/usr/bin/env bash
#
# check-byte-budget.sh — the client's byte budget, as a gate.
#
#   ./scripts/check-byte-budget.sh [image]     (default: <directory>:latest,
#                                               the image verify.sh builds)
#
# Nothing else notices a bundle that doubled: the tests pass, the page works,
# and every visitor on a slow connection pays. This measures the production
# build — the wwwroot inside the production image, not a dev build — in
# gzip -9 bytes against client/byte-budget.json: the entry script, the entry
# stylesheet, the initial total for /, and each prerendered page. Bytes, never
# timing: the numbers are the same on every machine.
#
# A checker that has never been seen to fail is not a checker, so the same run
# plants 300 KB of incompressible text in a copy of the entry script and
# requires the check to FAIL on it.
#
# Runs in the Node image the Dockerfile pins; the host needs only Docker.

set -euo pipefail
cd "$(dirname "$0")/.."

NAME="$(basename "$PWD" | tr '[:upper:]' '[:lower:]')"
IMAGE="${1:-$NAME:latest}"
NODE_IMAGE="$(sed -n 's|^FROM \(node:[^ ]*\) AS node-base$|\1|p' Dockerfile)"
[ -n "$NODE_IMAGE" ] || { echo "error: could not derive the Node image from the Dockerfile" >&2; exit 1; }

# The runtime image has no shell, so the build is copied out of a container
# that is created and never started.
DIST="$(mktemp -d)"
SOURCE="$NAME-byte-budget-src"
# shellcheck disable=SC2329  # invoked via the EXIT trap below
cleanup() {
  docker rm -f "$SOURCE" > /dev/null 2>&1 || true
  rm -rf "$DIST"
}
trap cleanup EXIT
docker rm -f "$SOURCE" > /dev/null 2>&1 || true
docker create --name "$SOURCE" "$IMAGE" > /dev/null
docker cp "$SOURCE:/app/wwwroot" "$DIST/dist"

docker run --rm --name "$NAME-byte-budget" -v "$PWD":/src:ro -v "$DIST/dist":/dist:ro "$NODE_IMAGE" sh -c '
  set -eu
  check="node /src/scripts/check-byte-budget.mjs"

  $check /dist /src/client/byte-budget.json

  cp -r /dist /planted
  entry="$(ls /planted/assets/*.js | head -1)"
  head -c 225000 /dev/urandom | base64 >> "$entry"
  if $check /planted /src/client/byte-budget.json > /planted.out 2>&1; then
    echo "self-test FAILED: 300 KB planted in the entry script stayed within budget" >&2
    cat /planted.out >&2
    exit 1
  fi
  grep -q "OVER" /planted.out || { echo "self-test FAILED: the failure named nothing as OVER" >&2; cat /planted.out >&2; exit 1; }
  echo "self-test: a planted 300 KB in the entry script was caught"
'
