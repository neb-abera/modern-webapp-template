#!/usr/bin/env bash
#
# check-prose.sh — lint the prose against the writing rules.
#
#   scripts/check-prose.sh                every tracked Markdown file
#   scripts/check-prose.sh <path>...      these files or directories
#   scripts/check-prose.sh --self-test    prove every rule fires, and that
#                                         clean prose passes
#
# The rules are .vale/styles/Abera, one file per rule, and .vale.ini names
# them. They catch the mechanical part of the writing standard in the global
# CLAUDE.md: dashes, semicolons, intensifiers, hedges, jargon, throat-clearing,
# clichés and rhetorical shapes. They cannot catch an aphorism or a sentence
# that says nothing. That is what review is for.
#
# The self-test runs the rules over .vale/fixtures/fails.md, which carries one
# violation per rule, and fails unless every rule in the style directory fired
# and the exit code carried it. It then runs .vale/fixtures/passes.md and
# fails on any alert. A rule with no line in fails.md is a rule nobody has
# seen fail, so adding a rule means adding its line.
#
# Runs in the Vale image the Dockerfile pins (the `vale` stage, which
# Dependabot bumps); the host needs only Docker.

set -euo pipefail
cd "$(dirname "$0")/.."

NAME="$(basename "$PWD" | tr '[:upper:]' '[:lower:]')"

VALE_IMAGE=""
for dockerfile in Dockerfile */Dockerfile; do
  [ -f "$dockerfile" ] || continue
  VALE_IMAGE="$(sed -n 's|^FROM \(jdkato/vale:[^ ]*\) AS vale$|\1|p' "$dockerfile" | head -1)"
  [ -z "$VALE_IMAGE" ] || break
done
[ -n "$VALE_IMAGE" ] || { echo "error: no 'FROM jdkato/vale:... AS vale' stage found in a Dockerfile" >&2; exit 1; }

STYLE_DIR=.vale/styles/Abera
[ -d "$STYLE_DIR" ] || { echo "error: $STYLE_DIR is missing" >&2; exit 1; }

vale() {
  docker run --rm --name "$NAME-prose" -v "$PWD":/src:ro -w /src "$VALE_IMAGE" \
    --config=.vale.ini --output=line "$@"
}

if [ "${1:-}" = "--self-test" ]; then
  failed=0

  # Every rule fires on the fixture that carries one violation each, and the
  # exit code is non-zero.
  code=0
  out="$(vale .vale/fixtures/fails.md 2>&1)" || code=$?
  if [ "$code" -eq 0 ]; then
    echo "self-test FAILED: fails.md produced exit 0" >&2
    failed=1
  fi
  fired="$(printf '%s\n' "$out" | grep -Eo 'Abera\.[A-Za-z]+' | sort -u)"
  for rule in "$STYLE_DIR"/*.yml; do
    name="Abera.$(basename "$rule" .yml)"
    if ! printf '%s\n' "$fired" | grep -qx "$name"; then
      echo "self-test FAILED: $name never fired on .vale/fixtures/fails.md" >&2
      failed=1
    fi
  done

  # Clean prose passes with no output.
  code=0
  out="$(vale .vale/fixtures/passes.md 2>&1)" || code=$?
  if [ "$code" -ne 0 ] || [ -n "$out" ]; then
    echo "self-test FAILED: passes.md produced alerts:" >&2
    printf '%s\n' "$out" >&2
    failed=1
  fi

  if [ "$failed" -ne 0 ]; then
    exit 1
  fi
  echo "self-test passed: $(printf '%s\n' "$fired" | grep -c .) rules fire on fails.md, passes.md is clean"
  exit 0
fi

if [ "$#" -gt 0 ]; then
  vale "$@"
else
  # Every tracked Markdown file except the self-test fixtures, one of which
  # fails by design.
  git ls-files -z -- '*.md' ':(exclude).vale/fixtures/*' | xargs -0 scripts/check-prose.sh
fi
