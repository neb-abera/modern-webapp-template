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
#
#   scripts/check-template-parity.sh              run the check
#   scripts/check-template-parity.sh --self-test  prove it can fail
#
# --self-test builds a fixture template and a fixture repository in a temp
# directory, points the fetch at the fixture (TEMPLATE_PARITY_SOURCE, a
# file:// URL, the only way to plant a drift without a network) and requires:
# identical files pass, a changed file fails naming it, a listed file that
# is missing fails naming it, and the template itself passes without
# comparing.
set -euo pipefail
cd "$(dirname "$0")/.."

LIST=.template-parity

# The check, against the repository rooted at $1. A subshell, so an early
# exit inside it ends the check and not the caller: --self-test runs it
# several times against several trees.
check() (
  cd "$1"
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

  # Where the template's files are read from: its default branch on
  # raw.githubusercontent.com, or the directory --self-test points at.
  # Exit 2 on a fetch that fails is an outage to wait out, not drift; a
  # finding is exit 1.
  if [ -n "${TEMPLATE_PARITY_SOURCE:-}" ]; then
    branch="$TEMPLATE_PARITY_SOURCE"
    base="$TEMPLATE_PARITY_SOURCE"
  else
    if ! api="$(curl -fsSL --retry 2 "https://api.github.com/repos/$template")"; then
      echo "error: could not reach api.github.com for $template; an outage, not drift" >&2
      exit 2
    fi
    branch="$(sed -n 's/.*"default_branch": *"\([^"]*\)".*/\1/p' <<< "$api")"
    [ -n "$branch" ] || { echo "error: could not read the default branch of $template" >&2; exit 2; }
    base="https://raw.githubusercontent.com/$template/$branch"
  fi

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
    if ! curl -fsSL --retry 2 -o "$tmp" "$base/$path"; then
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
)

# expect <exit> <fixed string in the output> <label> <tree>: run the check
# on a tree and require both the exit code and the message. The message
# matters as much as the code: a check that fails for the wrong reason has
# not been proved.
SELF_TEST_FAILED=0
expect() {
  local want="$1" needle="$2" label="$3" root="$4" code=0 out
  out="$(check "$root" 2>&1)" || code=$?
  if [ "$code" -eq "$want" ] && printf '%s\n' "$out" | grep -Fq -- "$needle"; then
    echo "self-test: ok: $label (exit $code)"
  else
    echo "self-test FAILED: $label: wanted exit $want and '$needle', got exit $code:" >&2
    printf '%s\n' "$out" | sed 's/^/    /' >&2
    SELF_TEST_FAILED=1
  fi
}

self_test() {
  local dir
  dir="$(mktemp -d)"
  # shellcheck disable=SC2064 # expand now: the directory name is fixed
  trap "rm -rf '$dir'" EXIT

  # A fixture template with two shared files, and a repository that took
  # both of them byte for byte.
  mkdir -p "$dir/template/scripts" "$dir/repo/scripts"
  printf '#!/bin/sh\necho shared\n' > "$dir/template/scripts/shared.sh"
  printf 'one\ntwo\n' > "$dir/template/NOTICE"
  cp "$dir/template/scripts/shared.sh" "$dir/repo/scripts/"
  cp "$dir/template/NOTICE" "$dir/repo/"
  printf '# fixture\ntemplate: example/template\nscripts/shared.sh\nNOTICE\n' > "$dir/repo/$LIST"

  # Plant 1: a shared file edited in the repository instead of the template.
  cp -R "$dir/repo" "$dir/drifted"
  printf 'one\ntwo\nthree\n' > "$dir/drifted/NOTICE"

  # Plant 2: a listed file that the repository does not have at all.
  cp -R "$dir/repo" "$dir/missing"
  rm "$dir/missing/scripts/shared.sh"

  export TEMPLATE_PARITY_SOURCE="file://$dir/template"
  export GITHUB_REPOSITORY="example/repo"
  expect 0 "NOTICE: identical to example/template" "identical files pass" "$dir/repo"
  expect 1 "NOTICE differs from example/template" "a file edited here and not in the template fails, by name" "$dir/drifted"
  expect 1 "scripts/shared.sh is listed in $LIST but does not exist here" "a listed file that is missing fails, by name" "$dir/missing"
  GITHUB_REPOSITORY="example/template" \
    expect 0 "this is example/template; nothing to compare" "the template itself passes without comparing" "$dir/drifted"
  unset TEMPLATE_PARITY_SOURCE GITHUB_REPOSITORY

  if [ "$SELF_TEST_FAILED" -eq 0 ]; then
    echo "self-test: a drifted file and a missing file were both caught by name; identical files and the template itself pass"
  fi
  return "$SELF_TEST_FAILED"
}

if [ "${1:-}" = --self-test ]; then
  self_test
else
  check .
fi
