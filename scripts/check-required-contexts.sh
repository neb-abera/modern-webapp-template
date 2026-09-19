#!/usr/bin/env bash
#
# check-required-contexts.sh — assert that the branch-protection contexts
# array in scripts/setup.sh matches the PR-gating job names in the three
# workflows that run on every pull request:
#
#   .github/workflows/ci.yml
#   .github/workflows/codeql.yml
#   .github/workflows/security-scan.yml
#
# A required-status-check context is the job's `name:`. A job that runs on
# PRs but is missing from setup.sh's list does not block a merge — a red
# scan would not stop Dependabot auto-merge. A context with no matching job
# blocks every merge forever, because GitHub waits for a check that never
# reports. Both directions fail this script.
#
# Deliberately dependency-light (bash + sed/grep, like verify.sh): job names
# are the 4-space-indented `name:` lines, and the one matrix variable used
# in job names (`${{ matrix.language }}`) is expanded from the matrix list.
# Run by verify.sh as part of the suite; exits 0 only when the sets match.
#
#   scripts/check-required-contexts.sh              run the check
#   scripts/check-required-contexts.sh --self-test  prove it can fail
#
# --self-test copies the files the check reads into a temp tree and breaks
# them the two ways this exists to catch: a context renamed in setup.sh
# (which must be reported in both directions, the stale name and the job
# it no longer matches), and a workflow whose pull_request trigger is gone.
# The untouched copy must pass. A checker that has never been seen to fail
# is an advisory check wearing a costume.

set -euo pipefail
cd "$(dirname "$0")/.."

WORKFLOWS=(
  .github/workflows/ci.yml
  .github/workflows/codeql.yml
  .github/workflows/security-scan.yml
)

# The check, against the tree rooted at $1. A subshell, so an early exit
# inside it ends the check and not the caller: --self-test runs it four
# times against four trees.
check() (
  cd "$1"

  # The contexts setup.sh requires: the quoted strings on its "contexts" line.
  required="$(grep '"contexts":' scripts/setup.sh \
    | grep -o '"[^"]*"' | sed 's/"//g' | grep -v '^contexts$')"
  [ -n "$required" ] || { echo "error: no contexts array found in scripts/setup.sh" >&2; exit 1; }

  # The job names of every workflow that gates PRs.
  actual=""
  for wf in "${WORKFLOWS[@]}"; do
    [ -f "$wf" ] || { echo "error: $wf not found" >&2; exit 1; }
    # Each workflow must trigger on every pull request, unfiltered: a bare
    # `pull_request:` in the on: block. A filtered trigger would let some PRs
    # merge with the required check permanently pending.
    if ! grep -q '^  pull_request:$' "$wf"; then
      echo "error: $wf has no unfiltered 'pull_request:' trigger" >&2
      exit 1
    fi
    names="$(sed -n 's/^    name: //p' "$wf")"
    langs="$(sed -n 's/.*language: \[\(.*\)\].*/\1/p' "$wf" | tr -d ' ' | tr ',' '\n')"
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      # shellcheck disable=SC2016 # literal '${{ matrix.language }}', not expansion
      if [ "${name#*'${{ matrix.language }}'}" != "$name" ]; then
        [ -n "$langs" ] || { echo "error: $wf uses matrix.language in a job name but has no matrix list" >&2; exit 1; }
        while IFS= read -r lang; do
          # shellcheck disable=SC2016 # literal '${{ matrix.language }}', not expansion
          actual="$actual${name//'${{ matrix.language }}'/$lang}"$'\n'
        done <<< "$langs"
      else
        actual="$actual$name"$'\n'
      fi
    done <<< "$names"
  done

  required_sorted="$(printf '%s\n' "$required" | sort)"
  actual_sorted="$(printf '%s' "$actual" | sort)"

  missing_from_setup="$(comm -13 <(printf '%s\n' "$required_sorted") <(printf '%s\n' "$actual_sorted"))"
  missing_from_workflows="$(comm -23 <(printf '%s\n' "$required_sorted") <(printf '%s\n' "$actual_sorted"))"

  status=0
  if [ -n "$missing_from_setup" ]; then
    echo "PR-gating jobs NOT required by setup.sh's contexts array (a red run would not block a merge):" >&2
    printf '%s\n' "$missing_from_setup" | sed 's/^/  - /' >&2
    status=1
  fi
  if [ -n "$missing_from_workflows" ]; then
    echo "Contexts required by setup.sh with no matching PR-gating job (would block every merge):" >&2
    printf '%s\n' "$missing_from_workflows" | sed 's/^/  - /' >&2
    status=1
  fi

  if [ "$status" -eq 0 ]; then
    count="$(printf '%s\n' "$required_sorted" | wc -l | tr -d ' ')"
    echo "required contexts and PR-gating job names agree ($count checks):"
    printf '%s\n' "$required_sorted" | sed 's/^/  - /'
  fi
  exit "$status"
)

# expect <exit> <fixed string> <label> <tree>: run the check on a tree and
# require both the exit code and the message, as a substring of the output
# (expect_line: as a whole line, for the names, where "  - verify" must not
# be satisfied by "  - verify-renamed"). The message matters as much as the
# code: a check that fails for the wrong reason has not been proved.
SELF_TEST_FAILED=0
expect() { expect_with -F "$@"; }
expect_line() { expect_with -Fx "$@"; }
expect_with() {
  local grep_mode="$1" want="$2" needle="$3" label="$4" root="$5" code=0 out
  out="$(check "$root" 2>&1)" || code=$?
  if [ "$code" -eq "$want" ] && printf '%s\n' "$out" | grep -q "$grep_mode" -- "$needle"; then
    echo "self-test: ok: $label (exit $code)"
  else
    echo "self-test FAILED: $label: wanted exit $want and '$needle', got exit $code:" >&2
    printf '%s\n' "$out" | sed 's/^/    /' >&2
    SELF_TEST_FAILED=1
  fi
}

self_test() {
  local dir first
  dir="$(mktemp -d)"
  # shellcheck disable=SC2064 # expand now: the directory name is fixed
  trap "rm -rf '$dir'" EXIT

  # The real files, copied: whatever they say today is the healthy case.
  mkdir -p "$dir/healthy/scripts" "$dir/healthy/.github/workflows"
  cp scripts/setup.sh "$dir/healthy/scripts/"
  cp "${WORKFLOWS[@]}" "$dir/healthy/.github/workflows/"

  # Plants are made with sed into a new file, then moved over: sed -i is
  # spelled differently on GNU and BSD, and this runs on both.
  edit() { # edit <file> <sed script>
    sed "$2" "$1" > "$1.planted" && mv "$1.planted" "$1"
  }

  # Plant 1: the first required context renamed to a name no workflow has.
  # setup.sh would then demand a check that never reports (every merge
  # blocked) while the real job goes unrequired (a red run merges). The
  # first context is a plain word (the verify job), so it is safe in a sed
  # pattern as it is; the assertion below would say if that stops holding.
  first="$(grep '"contexts":' scripts/setup.sh | grep -o '"[^"]*"' | sed 's/"//g' | grep -v '^contexts$' | head -1)"
  case "$first" in
    *[!A-Za-z0-9_-]*|'') echo "self-test FAILED: the first context '$first' is not a plain word; the plant would need escaping" >&2; return 1 ;;
  esac
  cp -R "$dir/healthy" "$dir/renamed"
  edit "$dir/renamed/scripts/setup.sh" "/\"contexts\":/ s/\"$first\"/\"$first-renamed\"/"

  # Plant 2: a PR-gating workflow that no longer triggers on pull requests.
  cp -R "$dir/healthy" "$dir/untriggered"
  edit "$dir/untriggered/.github/workflows/ci.yml" '/^  pull_request:$/d'

  expect 0 "required contexts and PR-gating job names agree" "the real files agree" "$dir/healthy"
  expect 1 "no matching PR-gating job" "a renamed context is reported as unmatched" "$dir/renamed"
  expect_line 1 "  - $first-renamed" "the report names the stale context" "$dir/renamed"
  expect 1 "NOT required by setup.sh" "the job the renamed context left behind is reported as unrequired" "$dir/renamed"
  expect_line 1 "  - $first" "the report names the unrequired job" "$dir/renamed"
  expect 1 "has no unfiltered 'pull_request:' trigger" "a workflow that stopped gating pull requests is reported" "$dir/untriggered"

  if [ "$SELF_TEST_FAILED" -eq 0 ]; then
    echo "self-test: a renamed context was reported both ways and a lost pull_request trigger was caught; the real files pass"
  fi
  return "$SELF_TEST_FAILED"
}

if [ "${1:-}" = --self-test ]; then
  self_test
else
  check .
fi
