#!/usr/bin/env bash
#
# check-american-spelling.sh — British spellings in the code's own text.
#
#   scripts/check-american-spelling.sh               every tracked source file
#   scripts/check-american-spelling.sh --self-test   prove it fails and passes
#
# Vale's Abera/American rule reads the Markdown and the prerendered pages.
# The owner pages are not prerendered, so their strings, the server's
# messages and the comments are read here, from the same word list:
# .vale/styles/Abera/American.yml. Neb set American spelling on 2026-11-06,
# after "Modelled" reached the abera.tech/fitness Goals tab.
#
# An outside value keeps its spelling: an identifier, an API value such as
# Google Calendar's "cancelled", a stored id, a URL. Each is a line in
# scripts/american-spelling-allow.txt: a path, a tab, and an extended regex
# the offending line must match, then a tab and the reason.

set -euo pipefail
cd "$(dirname "$0")/.."

RULE=.vale/styles/Abera/American.yml
ALLOW=scripts/american-spelling-allow.txt

words() {
  sed -n 's/^  \([a-z]*\): [a-z]*$/\1/p' "$RULE" | paste -sd'|'
}

# Lines with a British word, as path:line:text, minus the allowed ones.
findings() {
  local pattern
  pattern="\\b($(words))\\b"
  git ls-files -z -- '*.ts' '*.tsx' '*.mts' '*.cts' '*.js' '*.jsx' '*.mjs' '*.cjs' \
    '*.cs' '*.csproj' '*.props' '*.rs' '*.c' '*.h' '*.cc' '*.cpp' '*.hpp' '*.cxx' \
    '*.cmake' 'CMakeLists.txt' '*.py' '*.go' '*.java' '*.kt' '*.swift' \
    '*.css' '*.scss' '*.sh' '*.bash' '*.yml' '*.yaml' '*.toml' '*.json' 'Dockerfile' '*.Dockerfile' \
    ':!*/Migrations/*' ':!**/package-lock.json' ':!**/Cargo.lock' ':!**/*.Designer.cs' ':!.vale/*' ':!scripts/check-american-spelling.sh' \
    | { xargs -0 -r grep -n -i -w -E "$pattern" -- 2>/dev/null || true; } \
    | while IFS= read -r hit; do
        local path="${hit%%:*}" rest="${hit#*:}"
        local text="${rest#*:}" allowed=""
        while IFS=$'\t' read -r allow_path allow_regex _reason; do
          case "$allow_path" in ''|'#'*) continue ;; esac
          if [ "$allow_path" = "$path" ] && grep -q -E -- "$allow_regex" <<<"$text"; then
            allowed=1
            break
          fi
        done < "$ALLOW"
        [ -n "$allowed" ] || printf '%s\n' "$hit"
      done
}

if [ "${1:-}" = "--self-test" ]; then
  [ -n "$(words)" ] || { echo "self-test: no words read from $RULE" >&2; exit 1; }
  grep -q -E "\\b($(words))\\b" <<<'the forecast was modelled' \
    || { echo "self-test: 'modelled' was not caught" >&2; exit 1; }
  if grep -q -E "\\b($(words))\\b" <<<'the forecast was modeled, a cancellation'; then
    echo "self-test: American text was flagged" >&2; exit 1
  fi
  echo "self-test passed: the word list catches British forms and passes American ones"
  exit 0
fi

found="$(findings)"
if [ -n "$found" ]; then
  printf '%s\n' "$found"
  echo "British spelling in the text above. Write it the American way, or, for an outside value, add a line to $ALLOW." >&2
  exit 1
fi
echo "American spelling: no British forms in the tracked source."
