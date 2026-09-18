#!/usr/bin/env bash
#
# check-held-majors.sh — fail when a dependency's next major cannot install
# beside the rest of its manifest, for every npm and NuGet manifest
# Dependabot watches.
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
# NuGet gets the same treatment (scripts/held-nuget-majors.cs, run with
# `dotnet run` in the SDK image the server builds with): a major that ships
# no framework a referencing project can consume is never offered either.
# Skipped when dependabot.yml has no nuget entry, so one script serves every
# repository.
#
# Accepted cases live in .held-majors with their reasoning, like
# .trivyignore. An entry that is no longer needed fails the check too.
#
# Exit 1 is a finding (a held major or a stale entry). Exit 2 is a registry
# that could not be reached after a retry: an outage to wait out, not a
# finding, and the message says so.
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

# Manifest directories per ecosystem. A root manifest is `directory: /`,
# which becomes `.`.
manifest_dirs() {
  awk -v eco="$1" '
    /package-ecosystem:/ { gsub(/"/, "", $NF); hit = ($NF == eco) }
    hit && /directory:/  { gsub(/"/, "", $NF); sub(/^\//, "", $NF); print ($NF == "" ? "." : $NF); hit = 0 }
  ' .github/dependabot.yml
}
npm_dirs="$(manifest_dirs npm)"
nuget_dirs="$(manifest_dirs nuget)"
[ -n "$npm_dirs$nuget_dirs" ] || { echo "error: no npm or nuget entries found in .github/dependabot.yml" >&2; exit 1; }

# Exit 1 when either half found something; exit 2 when a half could not
# reach its registry and neither found anything. A finding outranks an
# outage in the exit code so it cannot be read as one.
found=0
outage=0
if [ -n "$npm_dirs" ]; then
  rc=0
  if [ "${1:-}" = --self-test ]; then
    args=(--self-test)
  else
    # shellcheck disable=SC2206 # a word list on purpose: one directory per word
    args=($npm_dirs)
  fi
  # Read-only mount, no copy: everything the check writes goes to a temp
  # directory inside the container.
  docker run --rm -v "$PWD":/src:ro -w /src -v "$NAME-npm:/npm-cache" -e npm_config_cache=/npm-cache \
    -e npm_config_update_notifier=false -e HELD_MAJORS_GRACE_DAYS \
    "$NODE_IMAGE" node scripts/held-majors.mjs "${args[@]}" || rc=$?
  case $rc in 0) ;; 2) outage=1 ;; *) found=1 ;; esac
fi

if [ -n "$nuget_dirs" ]; then
  rc=0
  nuget_log="$(mktemp)"
  SDK_IMAGE=""
  for dockerfile in Dockerfile */Dockerfile; do
    [ -f "$dockerfile" ] || continue
    SDK_IMAGE="$(sed -n 's|^FROM \(mcr\.microsoft\.com/dotnet/sdk:[^ ]*\) AS .*|\1|p' "$dockerfile" | head -1)"
    [ -z "$SDK_IMAGE" ] || break
  done
  [ -n "$SDK_IMAGE" ] || { echo "error: no 'FROM mcr.microsoft.com/dotnet/sdk:... AS ...' stage found in a Dockerfile" >&2; exit 1; }
  if [ "${1:-}" = --self-test ]; then
    args=(--self-test)
  else
    # shellcheck disable=SC2206 # a word list on purpose: one directory per word
    args=($nuget_dirs)
  fi
  # The tree is mounted read-only, so the file-based app is copied out and
  # compiles into a scratch directory of its own.
  docker run --rm -v "$PWD":/src:ro -w /src \
    -e DOTNET_CLI_TELEMETRY_OPTOUT=1 -e DOTNET_NOLOGO=1 -e HELD_MAJORS_GRACE_DAYS \
    "$SDK_IMAGE" sh -c 'cp scripts/held-nuget-majors.cs /tmp/ && cd /src && dotnet run /tmp/held-nuget-majors.cs -- "$@"' sh "${args[@]}" 2>&1 | tee "$nuget_log" || rc=$?
  # dotnet run restores the file-based app before any line of it runs, and
  # that restore reads nuget.org's service index: with the registry down it
  # fails NU1301 before the app's own retry can. That is the outage, too.
  # (pipefail: rc is docker's exit code, tee's is 0.)
  case $rc in
    0) ;;
    2) outage=1 ;;
    *) if grep -q NU1301 "$nuget_log"; then
         echo "error: nuget.org unreachable (NU1301); this is an outage, not a held major" >&2
         outage=1
       else
         found=1
       fi ;;
  esac
  rm -f "$nuget_log"
fi

if [ "$found" -eq 1 ]; then exit 1; fi
if [ "$outage" -eq 1 ]; then exit 2; fi
exit 0
