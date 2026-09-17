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
NODE_IMAGE="$(sed -n 's|^FROM \(node:[^ ]*\) AS node-base$|\1|p' Dockerfile)"
[ -n "$NODE_IMAGE" ] || { echo "error: could not derive the Node image from the Dockerfile" >&2; exit 1; }

dirs="$(awk '
  /package-ecosystem:/ { npm = ($NF == "npm") }
  npm && /directory:/  { sub(/^\//, "", $NF); print $NF; npm = 0 }
' .github/dependabot.yml)"
[ -n "$dirs" ] || { echo "error: no npm entries found in .github/dependabot.yml" >&2; exit 1; }

if [ "${1:-}" = --self-test ]; then
  args=(--self-test)
else
  # shellcheck disable=SC2206 # a word list on purpose: one directory per word
  args=($dirs)
fi

docker run --rm -v "$PWD":/src:ro -v "$NAME-npm:/npm-cache" -e npm_config_cache=/npm-cache \
  -e npm_config_update_notifier=false -e HELD_MAJORS_GRACE_DAYS \
  "$NODE_IMAGE" sh -c 'cp -r /src /w && cd /w && node scripts/held-majors.mjs "$@"' sh "${args[@]}"
