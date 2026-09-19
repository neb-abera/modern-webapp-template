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
# A checker that has never been seen to fail is not a checker, so the same
# run proves the gate at its boundary, from the build it just measured: a
# budget of exactly the entry script's size must pass, one byte under it
# (the script is one byte over) must fail naming the row, a build missing an
# artifact the document names must fail rather than measure it as nothing,
# and a missing or unreadable budget must fail rather than pass by default.
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
  budget=/src/client/byte-budget.json

  # The real check. Its stdout is kept: the self-test builds its boundary
  # from the entry script size measured here.
  $check /dist "$budget" > /measured.txt || { cat /measured.txt; exit 1; }
  cat /measured.txt

  entry="$(awk "\$1 == \"entryJs\" { print \$2 }" /measured.txt)"
  [ -n "$entry" ] || { echo "self-test FAILED: no entryJs measurement to build a boundary from" >&2; exit 1; }
  with_entry_budget() { # with_entry_budget <bytes> <out.json>: the real budget with entryJs replaced
    node -e "const b = JSON.parse(require(\"fs\").readFileSync(process.argv[1], \"utf8\")); b.entryJs = Number(process.argv[2]); process.stdout.write(JSON.stringify(b));" "$budget" "$1" > "$2"
  }
  with_entry_budget "$entry" /exact.json
  with_entry_budget "$((entry - 1))" /one-under.json
  echo "not json" > /garbage.json
  cp -r /dist /missing && rm /missing/assets/*.js

  failed=0
  expect() { # expect <exit> <fixed string in the output> <label> <dist> <budget>
    want="$1"; needle="$2"; label="$3"; code=0
    out="$($check "$4" "$5" 2>&1)" || code=$?
    if [ "$code" -eq "$want" ] && printf "%s\n" "$out" | grep -Fq -- "$needle"; then
      echo "self-test: ok: $label (exit $code)"
    else
      echo "self-test FAILED: $label: wanted exit $want and \"$needle\", got exit $code:" >&2
      printf "%s\n" "$out" | sed "s/^/    /" >&2
      failed=1
    fi
  }
  expect 0 "$(printf "budget %8s   ok" "$entry")" "a budget of exactly the measured $entry bytes passes" /dist /exact.json
  expect 1 "$(printf "budget %8s   OVER" "$((entry - 1))")" "one byte over the budget fails, naming the row" /dist /one-under.json
  expect 2 "artifact missing" "a build missing the entry script fails, it does not measure as nothing" /missing "$budget"
  expect 3 "budget file /no-such-budget.json is missing or not JSON" "a missing budget fails, it does not pass" /dist /no-such-budget.json
  expect 3 "budget file /garbage.json is missing or not JSON" "an unreadable budget fails" /dist /garbage.json
  [ "$failed" -eq 0 ] || exit 1
  echo "self-test: exactly at the limit passes; one byte over, a missing artifact and a missing budget all fail"
'
