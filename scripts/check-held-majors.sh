#!/usr/bin/env bash
#
# check-held-majors.sh — fail when a dependency's next major cannot install
# beside the rest of its manifest.
#
# Dependabot only opens a pull request for a bump that installs. When a new
# major declares a peer range the manifest cannot satisfy (npm ERESOLVE),
# nothing is offered and nothing goes red: the pin just ages. That is how
# openapi-typescript sat at 6.7.6 for two years here (7 peers on typescript
# ^5.x; the client compiles with TypeScript 7) until someone went looking.
# This is the looking, mechanized.
#
# For every npm manifest Dependabot watches (the npm `directory:` entries in
# .github/dependabot.yml, so the two cannot disagree), each direct dependency
# with a newer major that has been out longer than the grace period is
# resolved, together, into a temp copy of the manifest. If that resolves,
# Dependabot can offer it and an open major is ordinary work. If it does
# not, this fails.
#
# Accepted cases live in .held-majors with their reasoning, like
# .trivyignore. An entry that is no longer needed fails the check too.
#
#   scripts/check-held-majors.sh              run the check
#   scripts/check-held-majors.sh --self-test  prove it can fail
#
# Runs in the pinned Node image (derived from the Dockerfile, as verify.sh
# does). Resolution only: no package scripts run.

set -euo pipefail
cd "$(dirname "$0")/.."

NAME="$(basename "$PWD" | tr '[:upper:]' '[:lower:]')"

# The Node image is whatever the Dockerfile's node base stage pins, so this
# cannot drift from the node everything else runs on. The Dockerfile may sit
# at the root or one directory down; the stage is `nodebase` or `node-base`.
NODE_IMAGE=""
for dockerfile in Dockerfile */Dockerfile; do
  [ -f "$dockerfile" ] || continue
  NODE_IMAGE="$(sed -n 's|^FROM \(node:[^ ]*\) AS node-\{0,1\}base$|\1|p' "$dockerfile" | head -1)"
  [ -z "$NODE_IMAGE" ] || break
done
[ -n "$NODE_IMAGE" ] || { echo "error: no 'FROM node:... AS nodebase' stage found in a Dockerfile" >&2; exit 1; }

# A root manifest is `directory: /`, which becomes `.`.
dirs="$(awk '
  /package-ecosystem:/ { gsub(/"/, "", $NF); npm = ($NF == "npm") }
  npm && /directory:/  { gsub(/"/, "", $NF); sub(/^\//, "", $NF); print ($NF == "" ? "." : $NF); npm = 0 }
' .github/dependabot.yml)"
[ -n "$dirs" ] || { echo "error: no npm entries found in .github/dependabot.yml" >&2; exit 1; }

if [ "${1:-}" = --self-test ]; then
  args=(--self-test)
else
  # shellcheck disable=SC2206 # a word list on purpose: one directory per word
  args=($dirs)
fi

# Read-only mount, no copy: everything the check writes goes to a temp
# directory inside the container.
docker run --rm -v "$PWD":/src:ro -w /src -v "$NAME-npm:/npm-cache" -e npm_config_cache=/npm-cache \
  -e npm_config_update_notifier=false -e HELD_MAJORS_GRACE_DAYS \
  "$NODE_IMAGE" node scripts/held-majors.mjs "${args[@]}"
