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

set -euo pipefail
cd "$(dirname "$0")/.."

WORKFLOWS=(
  .github/workflows/ci.yml
  .github/workflows/codeql.yml
  .github/workflows/security-scan.yml
)

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
