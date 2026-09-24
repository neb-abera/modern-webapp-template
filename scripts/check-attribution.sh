#!/usr/bin/env bash
#
# check-attribution.sh — refuse commits that credit an AI.
#
#   scripts/check-attribution.sh                  HEAD against the default branch
#   scripts/check-attribution.sh <range>          any git range, e.g. abc123..def456
#   scripts/check-attribution.sh --all            every commit reachable from HEAD
#   scripts/check-attribution.sh --self-test      prove it fires and prove it passes
#
# Nothing published under Neb's name credits an AI. No `Co-Authored-By: Claude`
# trailer on a commit, no `Generated with Claude Code` line. The rule is the
# Attribution section of the global CLAUDE.md.
#
# Two gates already existed and both have the same blind spot: they run on the
# machine making the commit. `git-hooks/commit-msg` strips the trailer, and
# `.claude/hooks/no-ai-attribution.sh` refuses a `gh` command that would publish
# one. A commit made anywhere those are not installed reaches a pull request
# untouched.
#
# On 2026-09-24 that cost a day. aberaTech's master was rewritten to strip 45
# commits, and hours later a pull request cut from the pre-rewrite master was
# merged. The merge commit had both chains as parents, so every commit from
# f68e545 onward existed twice and three of the stripped lines were back. The
# rewrite had to be redone.
#
# So the check belongs where the merge happens: on the pull request, reading
# the commits it would add. A range with no offending commit exits 0 and says
# how many it read, because a checker that is silent when it finds nothing is
# indistinguishable from one that never ran.
#
# The deliberate override, for the rare case the text itself is the subject
# (this file, the hook, their tests), is KEEP_AI_ATTRIBUTION=1.

set -euo pipefail

# No cd. This reads git history, so it works in whatever repository it is
# invoked from, which is also what lets the self-test point it at a throwaway
# one. An earlier draft cd'd to the script's own repository root and happily
# checked this repository's history while claiming to check the test's.
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

# Written apart so this file does not match its own check.
TRAILER="Co-Authored-By: ""Claude"
GENERATED="Generated with \[""Claude Code\]"

usage() {
  sed -n '3,9p' "$0" | sed 's/^# \{0,1\}//'
}

# Every commit message in the range, checked one at a time so the report names
# the commit rather than the range.
check_range() {
  local range="$1"
  local offenders=0 read=0 sha subject

  while IFS= read -r sha; do
    [ -n "$sha" ] || continue
    read=$((read + 1))
    subject="$(git log -1 --format='%s' "$sha")"

    if git log -1 --format='%B' "$sha" | grep -qiE "$TRAILER|$GENERATED"; then
      offenders=$((offenders + 1))
      printf 'attribution: %s %s\n' "${sha:0:9}" "$subject" >&2
      git log -1 --format='%B' "$sha" \
        | grep -inE "$TRAILER|$GENERATED" \
        | sed 's/^/    /' >&2
    fi
  done < <(git rev-list "$range")

  if [ "$offenders" -gt 0 ]; then
    cat >&2 <<MSG

$offenders of $read commits credit an AI. Nothing published under Neb's name does
(global CLAUDE.md, "Attribution"). Rewrite the messages before this merges:

  git rebase -i ${range%%..*}      # reword each one listed above

Merging as-is puts the lines on the default branch, where removing them needs a
history rewrite and a force push past the ruleset.
MSG
    return 1
  fi

  printf 'attribution: %s commits carry no AI credit\n' "$read"
}

self_test() {
  local work status
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' RETURN

  # core.hooksPath is set globally on Neb's machines, so a temp repo inherits
  # git-hooks/commit-msg, which strips the trailer before this test can plant
  # one. Point it at an empty directory: the whole point here is to commit
  # something the other gate would have refused.
  mkdir -p "$work/nohooks"

  git init -q "$work"
  git -C "$work" config core.hooksPath "$work/nohooks"
  git -C "$work" config user.email "test@example.invalid"
  git -C "$work" config user.name "Test"
  git -C "$work" config commit.gpgsign false
  git -C "$work" commit -q --allow-empty -m "base"
  local base
  base="$(git -C "$work" rev-parse HEAD)"

  # A clean commit must pass.
  git -C "$work" commit -q --allow-empty -m "a clean message"
  if ! (cd "$work" && "$SELF" "$base..HEAD") >/dev/null 2>&1; then
    echo "self-test FAILED: a clean range was refused" >&2
    return 1
  fi

  # The trailer must fire.
  git -C "$work" commit -q --allow-empty \
    -m "$(printf 'carries the trailer\n\n%s <noreply@anthropic.com>' "$TRAILER")"
  status=0
  (cd "$work" && "$SELF" "$base..HEAD") >/dev/null 2>&1 || status=$?
  if [ "$status" -eq 0 ]; then
    echo "self-test FAILED: the trailer was not caught" >&2
    return 1
  fi

  # The generated-with line must fire, on its own.
  git init -q "$work/second"
  git -C "$work/second" config core.hooksPath "$work/nohooks"
  git -C "$work/second" config user.email "test@example.invalid"
  git -C "$work/second" config user.name "Test"
  git -C "$work/second" config commit.gpgsign false
  git -C "$work/second" commit -q --allow-empty -m "base"
  base="$(git -C "$work/second" rev-parse HEAD)"
  git -C "$work/second" commit -q --allow-empty \
    -m "$(printf 'carries the line\n\nGenerated with [Claude Code](https://claude.com/claude-code)')"
  status=0
  (cd "$work/second" && "$SELF" "$base..HEAD") >/dev/null 2>&1 || status=$?
  if [ "$status" -eq 0 ]; then
    echo "self-test FAILED: the generated-with line was not caught" >&2
    return 1
  fi

  echo "check-attribution: self-test passed"
}

if [ "${KEEP_AI_ATTRIBUTION:-}" = "1" ]; then
  echo "attribution: skipped, KEEP_AI_ATTRIBUTION=1"
  exit 0
fi

case "${1:-}" in
  --self-test) self_test ;;
  --help | -h) usage ;;
  --all) check_range "HEAD" ;;
  "")
    base="${GITHUB_BASE_REF:-}"
    if [ -n "$base" ]; then
      check_range "origin/$base..HEAD"
    else
      check_range "origin/HEAD..HEAD"
    fi
    ;;
  *) check_range "$1" ;;
esac
