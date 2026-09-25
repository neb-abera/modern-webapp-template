#!/usr/bin/env bash
#
# check-required-contexts.sh: the checks branch protection requires and the
# job names the pull-request workflows report must agree.
#
# One file, byte-identical in the web app, Rust and C++ project templates
# (each lists it in .template-parity). Nothing in it names a stack.
# A stack supplies its list in .github/required-checks:
#
#   workflow .github/workflows/ci.yml     a workflow whose jobs gate merges
#   check verify                          a check branch protection requires
#
# Blank lines and lines starting with # are ignored. scripts/setup.sh sends
# the `check` lines to GitHub as the required status check contexts, read
# through `--json` below, so the list exists in one place.
#
# A required-status-check context is the job's `name:`, or its id when it
# has none. A job that runs on pull requests but is not a `check` line does
# not block a merge: a red run would not stop Dependabot auto-merge. A
# `check` line with no job behind it blocks every merge, because GitHub
# waits for a check that never reports. Both directions fail.
#
# The workflows are read by convention rather than by a YAML engine, so the
# script needs bash, sed, awk and grep and nothing a stack has to install:
#   - each listed workflow triggers on `  pull_request:` with no filter keys
#     under it (a filtered trigger leaves some pull requests with the
#     required check pending forever)
#   - job ids sit at two spaces under `jobs:`, a job's `name:` and `if:` at
#     four
#   - a job whose `if:` tests github.event_name without allowing
#     'pull_request', or with != 'pull_request', does not run on pull
#     requests and is left out
#   - one `${{ matrix.<var> }}` per job name, expanded from a flow list
#     (`<var>: [a, b]`) or from include entries (`- <var>: a`) in that job
# A job that breaks a convention is reported as an error or a mismatch.
#
#   scripts/check-required-contexts.sh              run the check
#   scripts/check-required-contexts.sh --json       print the checks as a JSON array
#   scripts/check-required-contexts.sh --self-test  prove it can fail
#
# --self-test copies the list and its workflows into a temp tree and breaks
# them the ways this exists to catch: a check renamed in the list (reported
# both ways, the stale name and the job it no longer matches), a workflow
# whose pull_request trigger is gone, a job added with no check line, and a
# check name --json cannot carry. The untouched copy must pass.

set -euo pipefail
cd "$(dirname "$0")/.."

LIST=.github/required-checks

# The `workflow` or `check` values of the list at $1, one per line.
list_values() { # list_values <file> <kind>
  [ -f "$1" ] || { echo "error: $1 not found" >&2; return 1; }
  sed -n "s/^$2 \\(.*[^ ]\\) *\$/\\1/p" "$1"
}

# The check names one workflow reports on a pull request.
# shellcheck disable=SC2016 # '${{ matrix.' is literal YAML text
workflow_contexts() { # workflow_contexts <file>
  awk -v file="$1" '
    function flush(   var, rest, vals, n, i, v, out) {
      if (job == "" || skip) return
      if (name == "") name = job
      if (index(name, "${{ matrix.") > 0) {
        rest = substr(name, index(name, "${{ matrix.") + 11)
        var = substr(rest, 1, index(rest, " }}") - 1)
        if (index(substr(rest, index(rest, " }}") + 3), "${{") > 0) {
          printf "error: %s job %s: more than one expression in its name\n", file, job > "/dev/stderr"; bad = 1; return
        }
        vals = flow[var] != "" ? flow[var] : incl[var]
        if (vals == "") {
          printf "error: %s job %s: cannot expand ${{ matrix.%s }}\n", file, job, var > "/dev/stderr"; bad = 1; return
        }
        n = split(vals, v, "\n")
        for (i = 1; i <= n; i++) if (v[i] != "") {
          out = name; sub(/\$\{\{ matrix\.[A-Za-z0-9_-]+ \}\}/, v[i], out); print out
        }
      } else if (index(name, "${{") > 0) {
        printf "error: %s job %s: unhandled expression in its name\n", file, job > "/dev/stderr"; bad = 1
      } else print name
    }
    function unquote(s) { gsub(/^["\047 ]+|["\047 ]+$/, "", s); return s }
    /^jobs:/ { injobs = 1; next }
    !injobs { next }
    /^[^ #]/ { flush(); job = ""; injobs = 0; next }
    /^  [A-Za-z0-9_-]+:[ \t]*$/ {
      flush(); job = $0; sub(/^  /, "", job); sub(/:.*/, "", job)
      name = ""; skip = 0; delete flow; delete incl; next
    }
    job == "" { next }
    /^    name: / && name == "" { name = $0; sub(/^    name: /, "", name); name = unquote(name); next }
    /^    if: / {
      if ($0 ~ /github\.event_name/ && ($0 !~ /\047pull_request\047/ || $0 ~ /!= *\047pull_request\047/)) skip = 1
      next
    }
    /^ +[A-Za-z0-9_-]+: \[.*\][ \t]*$/ {
      k = $0; sub(/^ +/, "", k); sub(/:.*/, "", k)
      if (flow[k] == "") {
        v = $0; sub(/^[^[]*\[/, "", v); sub(/\][ \t]*$/, "", v)
        m = split(v, parts, ",")
        for (i = 1; i <= m; i++) flow[k] = flow[k] unquote(parts[i]) "\n"
      }
      next
    }
    /^ +- [A-Za-z0-9_-]+: / {
      k = $0; sub(/^ +- /, "", k); sub(/:.*/, "", k)
      v = $0; sub(/^ +- [A-Za-z0-9_-]+: /, "", v)
      incl[k] = incl[k] unquote(v) "\n"
      next
    }
    END { flush(); exit bad }
  ' "$1"
}

# The check, against the tree rooted at $1. A subshell, so an early exit
# inside it ends the check and not the caller.
check() (
  cd "$1"
  required="$(list_values "$LIST" check)" || exit 1
  [ -n "$required" ] || { echo "error: $LIST has no check lines" >&2; exit 1; }
  workflows="$(list_values "$LIST" workflow)"
  [ -n "$workflows" ] || { echo "error: $LIST has no workflow lines" >&2; exit 1; }

  actual=""
  while IFS= read -r wf; do
    [ -f "$wf" ] || { echo "error: $wf (listed in $LIST) not found" >&2; exit 1; }
    # An unfiltered trigger: the line itself, and no deeper key under it.
    if ! awk '/^  pull_request:[ \t]*$/ { found = 1; next }
              found == 1 && /^    [A-Za-z_-]+:/ { filtered = 1 }
              found == 1 && /^  [^ ]/ { found = 2 }
              END { exit !(found && !filtered) }' "$wf"; then
      echo "error: $wf has no unfiltered 'pull_request:' trigger" >&2
      exit 1
    fi
    names="$(workflow_contexts "$wf")" || exit 1
    actual="$actual$names"$'\n'
  done <<< "$workflows"

  required_sorted="$(printf '%s\n' "$required" | sort)"
  actual_sorted="$(printf '%s' "$actual" | grep -v '^$' | sort)"

  missing_from_list="$(comm -13 <(printf '%s\n' "$required_sorted") <(printf '%s\n' "$actual_sorted"))"
  missing_from_workflows="$(comm -23 <(printf '%s\n' "$required_sorted") <(printf '%s\n' "$actual_sorted"))"

  status=0
  if [ -n "$missing_from_list" ]; then
    echo "Pull-request jobs with no check line in $LIST (a red run would not block a merge):" >&2
    printf '%s\n' "$missing_from_list" | sed 's/^/  - /' >&2
    status=1
  fi
  if [ -n "$missing_from_workflows" ]; then
    echo "Check lines in $LIST with no matching pull-request job (would block every merge):" >&2
    printf '%s\n' "$missing_from_workflows" | sed 's/^/  - /' >&2
    status=1
  fi

  if [ "$status" -eq 0 ]; then
    count="$(printf '%s\n' "$required_sorted" | wc -l | tr -d ' ')"
    echo "required checks and pull-request job names agree ($count checks):"
    printf '%s\n' "$required_sorted" | sed 's/^/  - /'
  fi
  exit "$status"
)

# The check lines as a JSON array of strings, for setup.sh. A name holding a
# quote, a backslash or a control character would need escaping, and no job
# name has a reason to, so it is refused rather than escaped.
json() ( # json <root>
  cd "$1"
  required="$(list_values "$LIST" check)" || exit 1
  [ -n "$required" ] || { echo "error: $LIST has no check lines" >&2; exit 1; }
  if printf '%s\n' "$required" | LC_ALL=C grep -q '["\\[:cntrl:]]'; then
    echo "error: a check name in $LIST holds a quote, a backslash or a control character" >&2
    exit 1
  fi
  printf '%s\n' "$required" | awk 'BEGIN { printf "[" } { printf "%s\"%s\"", (NR > 1 ? ", " : ""), $0 } END { print "]" }'
)

# expect <exit> <fixed string> <label> <command...>: run a command and require
# both the exit code and the message, as a substring of the output
# (expect_line: as a whole line, so "  - verify" is not satisfied by
# "  - verify-renamed"). A check that fails for the wrong reason has not
# been proved.
SELF_TEST_FAILED=0
expect() { expect_with -F "$@"; }
expect_line() { expect_with -Fx "$@"; }
expect_with() {
  local grep_mode="$1" want="$2" needle="$3" label="$4" code=0 out
  shift 4
  out="$("$@" 2>&1)" || code=$?
  if [ "$code" -eq "$want" ] && printf '%s\n' "$out" | grep -q "$grep_mode" -- "$needle"; then
    echo "self-test: ok: $label (exit $code)"
  else
    echo "self-test FAILED: $label: wanted exit $want and '$needle', got exit $code:" >&2
    printf '%s\n' "$out" | sed 's/^/    /' >&2
    SELF_TEST_FAILED=1
  fi
}

self_test() {
  local dir first wf
  dir="$(mktemp -d)"
  # shellcheck disable=SC2064 # expand now: the directory name is fixed
  trap "rm -rf '$dir'" EXIT

  # The real files, copied: whatever they say today is the healthy case.
  mkdir -p "$dir/healthy/.github"
  cp "$LIST" "$dir/healthy/$LIST"
  while IFS= read -r wf; do
    mkdir -p "$dir/healthy/$(dirname "$wf")"
    cp "$wf" "$dir/healthy/$wf"
  done < <(list_values "$LIST" workflow)
  wf="$(list_values "$LIST" workflow | head -1)"
  first="$(list_values "$LIST" check | head -1)"

  # Plants are written to a new file and moved over: sed -i and awk -i are
  # spelled differently or missing on GNU and BSD, and this runs on both.
  edit() { # edit <file> <awk program>
    awk "$2" "$1" > "$1.planted" && mv "$1.planted" "$1"
  }

  # Plant 1: the first check renamed to a name no workflow has.
  cp -R "$dir/healthy" "$dir/renamed"
  # shellcheck disable=SC2016 # $0 is awk's, not the shell's
  edit "$dir/renamed/$LIST" '/^check / && !done { print $0 "-renamed"; done = 1; next } { print }'

  # Plant 2: the first workflow no longer triggers on pull requests.
  cp -R "$dir/healthy" "$dir/untriggered"
  edit "$dir/untriggered/$wf" '!/^  pull_request:[ \t]*$/'

  # Plant 3: a job added to the first workflow with no check line.
  cp -R "$dir/healthy" "$dir/added"
  edit "$dir/added/$wf" '{ print } /^jobs:/ { print "  planted:"; print "    name: planted job"; print "    runs-on: ubuntu-latest" }'

  # Plant 4: a check name with a quote in it.
  cp -R "$dir/healthy" "$dir/quoted"
  printf 'check say "hi"\n' >> "$dir/quoted/$LIST"

  expect 0 "required checks and pull-request job names agree" "the real files agree" check "$dir/healthy"
  expect 1 "no matching pull-request job" "a renamed check is reported as unmatched" check "$dir/renamed"
  expect_line 1 "  - $first-renamed" "the report names the stale check" check "$dir/renamed"
  expect 1 "no check line in" "the job the renamed check left behind is reported as unrequired" check "$dir/renamed"
  expect_line 1 "  - $first" "the report names the unrequired job" check "$dir/renamed"
  expect 1 "has no unfiltered 'pull_request:' trigger" "a workflow that stopped gating pull requests is reported" check "$dir/untriggered"
  expect_line 1 "  - planted job" "a job with no check line is reported" check "$dir/added"
  expect 0 "\"$first\"" "--json carries the real checks" json "$dir/healthy"
  expect 1 "holds a quote" "--json refuses a name it cannot carry" json "$dir/quoted"

  if [ "$SELF_TEST_FAILED" -eq 0 ]; then
    echo "self-test: a renamed check was reported both ways, a lost trigger, an unlisted job and an unsafe name were caught; the real files pass"
  fi
  return "$SELF_TEST_FAILED"
}

case "${1:-}" in
  --self-test) self_test ;;
  --json) json . ;;
  "") check . ;;
  *) echo "usage: $0 [--self-test | --json]" >&2; exit 2 ;;
esac
