#!/usr/bin/env bash
#
# Give this working copy its own host ports.
#
# Several people — or several agent sessions — work on one repository at once,
# each in their own git worktree, and every compose service here publishes a
# host port. Two copies on one port is a bind failure at best; at worst the
# second copy fails to start and its owner then browses the first one's build,
# believing it to be theirs.
#
# Compose reads .env from the project directory on every invocation, so the
# ports land whether the caller went through the Makefile or ran
# `docker compose` by hand. The values are derived from the directory name —
# the same thing the image tag already uses — so they are stable across restarts
# rather than handed out by a counter that would need somewhere to live.
#
# Writes nothing if .env already exists: an override typed by hand outlives
# this script.
set -euo pipefail

cd "$(dirname "$0")/.."

if [ -e .env ]; then
  exit 0
fi

copy="$(basename "$PWD")"

# A linked worktree has `.git` as a file pointing at the real one; the main
# checkout has it as a directory. The main checkout keeps the numbers the docs
# quote, and every worktree beside it gets its own.
if [ -d .git ]; then
  offset=0
else
  offset="$(printf '%s' "$copy" | cksum | awk '{print ($1 % 300) + 1}')"
fi

cat > .env <<ENV
# Written by scripts/worktree-env.sh, and ignored by git: these numbers belong
# to this working copy alone.
#
# Change them freely — the script leaves an existing file alone. Delete the
# file to have it derived again.
APP_PORT=$((8080 + offset))
CLIENT_PORT=$((5173 + offset))
ENV
