#!/usr/bin/env bash
#
# check-template-parity.sh — fail when a file this repository shares with
# modern-webapp-template has drifted from the template's default branch.
#
# The template is meant to lead: a practice lands there first and the other
# repositories inherit it, byte for byte, so a diff between repositories
# means drift and nothing else. That held until the held-majors check was
# ported and grew past its original (2026-09-18); this makes the next such
# drift a red pull request. .template-parity lists the shared paths; each
# is fetched from the template's default branch and compared.
#
# Read-only and dependency-light (curl, cmp). Inside the template itself the
# check passes without fetching: the template is the source.
set -euo pipefail
cd "$(dirname "$0")/.."

LIST=.template-parity
[ -f "$LIST" ] || { echo "error: $LIST not found" >&2; exit 1; }
template="$(sed -n 's/^template: *//p' "$LIST" | head -1)"
[ -n "$template" ] || { echo "error: $LIST names no template (a 'template: owner/repo' line)" >&2; exit 1; }

# This repository's name, from CI or from the origin remote.
self="${GITHUB_REPOSITORY:-}"
if [ -z "$self" ]; then
  self="$(git config --get remote.origin.url 2>/dev/null | sed -E 's#^(https://github\.com/|git@github\.com:)##; s#\.git$##')"
fi
if [ "$self" = "$template" ]; then
  echo "template parity: this is $template; nothing to compare"
  exit 0
fi

# Exit 2 on a fetch that fails is an outage to wait out, not drift; a
# finding is exit 1.
if ! api="$(curl -fsSL --retry 2 "https://api.github.com/repos/$template")"; then
  echo "error: could not reach api.github.com for $template; an outage, not drift" >&2
  exit 2
fi
branch="$(sed -n 's/.*"default_branch": *"\([^"]*\)".*/\1/p' <<< "$api")"
[ -n "$branch" ] || { echo "error: could not read the default branch of $template" >&2; exit 2; }

status=0
count=0
while IFS= read -r path; do
  case "$path" in ''|'#'*|template:*) continue ;; esac
  count=$((count + 1))
  if [ ! -f "$path" ]; then
    echo "error: $path is listed in $LIST but does not exist here" >&2
    status=1
    continue
  fi
  tmp="$(mktemp)"
  if ! curl -fsSL --retry 2 -o "$tmp" "https://raw.githubusercontent.com/$template/$branch/$path"; then
    echo "error: could not fetch $path from $template@$branch; an outage, not drift" >&2
    rm -f "$tmp"
    exit 2
  fi
  if cmp -s "$tmp" "$path"; then
    echo "$path: identical to $template@$branch"
  else
    echo "error: $path differs from $template@$branch; take the template's version, or land the change there first" >&2
    diff -u "$tmp" "$path" | head -20 >&2 || true
    status=1
  fi
  rm -f "$tmp"
done < "$LIST"
[ "$count" -gt 0 ] || { echo "error: $LIST lists no paths" >&2; exit 1; }
exit "$status"
