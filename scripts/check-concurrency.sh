#!/usr/bin/env bash
#
# check-concurrency.sh — no workflow loses a run on the default branch to
# its concurrency group.
#
#   scripts/check-concurrency.sh              check .github/workflows/*.yml
#   scripts/check-concurrency.sh --self-test  prove the check can fail
#
# A concurrency group holds one running and one pending run. A third run
# cancels the pending one, whatever cancel-in-progress says. So a group
# keyed by branch (`${{ github.workflow }}-${{ github.ref }}`) on push left
# three merges minutes apart with the middle commit never checked. That
# happened to aberaTech 2d7cced and aab70ed on 2026-09-26.
#
# For a workflow that runs on anything besides a pull request:
#
#   - cancel-in-progress is never `true`.
#   - A group built from an expression names github.sha, so each commit
#     gets its own group. The form used everywhere:
#       group: ${{ github.workflow }}-${{ github.event_name == 'pull_request' && github.ref || github.sha }}
#       cancel-in-progress: ${{ github.event_name == 'pull_request' }}
#     A pull request still cancels its own older run.
#   - A fixed group (a deploy that must serialize) has cancel-in-progress
#     false or absent. Its pending run can still be replaced by a newer
#     one, which is correct only when the newest commit always deploys.
#     The workflow says why in a comment.
#
# A workflow triggered only by pull_request or pull_request_target may do
# anything.

set -euo pipefail
cd "$(dirname "$0")/.."

# groups <file>: one line per concurrency block, "<group>\t<cancel>".
# Handles `concurrency: <group>` and the block form at any indentation.
groups() {
  awk '
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    function flush() { if (inblock) printf "%s\t%s\n", group, cancel; inblock = 0 }
    {
      line = $0
      match(line, /^[[:space:]]*/); ind = RLENGTH
      if (inblock && trim(line) != "" && line !~ /^[[:space:]]*#/) {
        if (ind <= cind) flush()
        else if (line ~ /^[[:space:]]*group:/) { sub(/^[[:space:]]*group:/, "", line); group = trim(line) }
        else if (line ~ /^[[:space:]]*cancel-in-progress:/) { sub(/^[[:space:]]*cancel-in-progress:/, "", line); cancel = trim(line) }
      }
      if ($0 ~ /^[[:space:]]*concurrency:/) {
        rest = $0; sub(/^[[:space:]]*concurrency:/, "", rest); sub(/[[:space:]]#.*$/, "", rest); rest = trim(rest)
        if (rest != "") printf "%s\t%s\n", rest, ""
        else { inblock = 1; cind = ind; group = ""; cancel = "" }
      }
    }
    END { flush() }
  ' "$1"
}

# triggers <file>: the event names under on:, flow form (`on: push`,
# `on: [a, b]`) or block form (the keys indented under `on:`).
triggers() {
  sed -n 's/^on:[[:space:]]*\[*\([^]#]*\)\]*.*$/\1/p' "$1" | tr ',' '\n'
  sed -n '/^on:[[:space:]]*$/,/^[^[:space:]#]/s/^  \([a-z_]*\):.*$/\1/p' "$1"
}

# check <dir>: print each offending workflow under <dir>; exit 1 if any.
check() (
  status=0
  for wf in "$1"/*.yml; do
    [ -f "$wf" ] || continue
    others=$(triggers "$wf" | tr -d ' ' | grep -v '^$' | grep -vx -e pull_request -e pull_request_target || true)
    [ -n "$others" ] || continue
    on=$(printf '%s' "$others" | tr '\n' ' ')
    while IFS=$'\t' read -r group cancel; do
      if [ "$cancel" = "true" ]; then
        echo "error: $wf sets cancel-in-progress: true and also runs on: $on" >&2
        status=1
      fi
      # shellcheck disable=SC2016 # '${{' is a GitHub expression, not shell
      case "$group" in
        *'${{'*)
          case "$group" in
            *github.sha*) ;;
            *)
              echo "error: $wf keys its concurrency group without github.sha and runs on: $on" >&2
              echo "       a third run cancels the pending second. Use: \${{ github.workflow }}-\${{ github.event_name == 'pull_request' && github.ref || github.sha }}" >&2
              status=1
              ;;
          esac
          ;;
        *)
          if [ -n "$cancel" ] && [ "$cancel" != "false" ]; then
            echo "error: $wf has the fixed concurrency group '$group' with cancel-in-progress: $cancel" >&2
            status=1
          fi
          ;;
      esac
    done < <(groups "$wf")
  done
  exit "$status"
)

if [ "${1:-}" = "--self-test" ]; then
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  cp .github/workflows/*.yml "$tmp/"
  check "$tmp" || { echo "self-test FAILED: the unmodified workflows do not pass" >&2; exit 1; }
  push=$'on:\n  push:\n    branches: [main]\n  pull_request:\n'
  # plant <name> <workflow text> <pass|fail>: add one workflow, run the
  # check, require the outcome, remove it.
  plant() {
    printf '%s' "$2" > "$tmp/planted.yml"
    if check "$tmp" 2> /dev/null; then got=pass; else got=fail; fi
    rm "$tmp/planted.yml"
    [ "$got" = "$3" ] || { echo "self-test FAILED: $1 should $3 and did $got" >&2; exit 1; }
  }
  # shellcheck disable=SC2016 # the ${{ }} are GitHub expressions, not shell
  {
    plant 'a push workflow that cancels in progress' \
      "${push}concurrency:"$'\n  group: x-${{ github.sha }}\n  cancel-in-progress: true\n' fail
    plant 'a push workflow keyed by branch (the old form)' \
      "${push}concurrency:"$'\n  group: ${{ github.workflow }}-${{ github.ref }}\n  cancel-in-progress: ${{ github.event_name == \'pull_request\' }}\n' fail
    plant 'a schedule workflow keyed by branch in the one-line form' \
      $'on:\n  schedule:\n    - cron: "0 3 * * 1"\nconcurrency: ${{ github.workflow }}-${{ github.ref }}\n' fail
    plant 'a job-level group keyed by branch' \
      "${push}"$'jobs:\n  a:\n    concurrency:\n      group: ${{ github.ref }}\n    runs-on: ubuntu-latest\n' fail
    plant 'a fixed group that can cancel' \
      "${push}concurrency:"$'\n  group: deploy-production\n  cancel-in-progress: ${{ github.event_name == \'pull_request\' }}\n' fail
    plant 'the form keyed by commit on push and by ref on a pull request' \
      "${push}concurrency:"$'\n  group: ${{ github.workflow }}-${{ github.event_name == \'pull_request\' && github.ref || github.sha }}\n  cancel-in-progress: ${{ github.event_name == \'pull_request\' }}\n' pass
    plant 'a fixed deploy group with cancel off' \
      $'on:\n  workflow_run:\n    workflows: [CI]\n  workflow_dispatch:\nconcurrency:\n  group: deploy-production\n  cancel-in-progress: false\n' pass
    plant 'a pull_request-only workflow that cancels, keyed by branch' \
      $'on: [pull_request, pull_request_target]\nconcurrency:\n  group: ${{ github.workflow }}-${{ github.ref }}\n  cancel-in-progress: true\n' pass
  }
  echo "self-test passed: cancel on push, a branch-keyed group on push and a fixed group that cancels all fail"
  exit 0
fi

check .github/workflows
echo "concurrency: every run outside a pull request has its own group or a fixed one that never cancels"
