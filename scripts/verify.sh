#!/usr/bin/env bash
#
# verify.sh — run the project's full verification suite, with a running
# pass/fail count and a final summary. Everything runs in containers, so the
# host needs only Docker and git. This mirrors what CI gates before a merge.
# The checks, in the order they run:
#
#   - required checks: .github/required-checks and the pull-request jobs
#     agree (the checker first proves a renamed check, a lost pull_request
#     trigger and an unlisted job are all caught)
#   - template parity: every file .template-parity lists is byte-identical
#     to the template's default branch — trivially so inside the template,
#     which is the source (the checker first proves a drifted file and a
#     missing file are both caught)
#   - prose: every tracked Markdown file passes the writing rules in
#     .vale/styles/Abera (the checker first proves every rule fires on a
#     fixture and that clean prose passes)
#   - attribution: no commit on the branch credits an AI (the checker first
#     proves a planted trailer and a generated-with line are refused)
#   - server: build + unit tests (warnings as errors, locked-mode restore)
#     + line coverage at or above SERVER_COVERAGE_MIN
#   - client: typecheck + lint (Biome) + unit tests + coverage thresholds
#     (vitest.config's coverage.thresholds fail the run on their own)
#   - OpenAPI contract: the committed spec (server/Api/openapi.json) and the
#     generated client types (client/src/api-types.d.ts) match the code
#   - held majors: no npm dependency's next major is uninstallable and no
#     NuGet dependency's next major ships only a framework the project
#     cannot consume, the two cases Dependabot cannot open a pull request
#     for (scripts/check-held-majors.sh)
#   - response DTOs: no response schema in that spec has a field named like
#     personal or secret data, unless allowlisted with a reason (the checker
#     plants a leaking spec and must catch it)
#   - database runtime role: scripts/db/runtime-role.sql, applied to a real
#     PostgreSQL, allows rows and refuses CREATE/ALTER/DROP/TRUNCATE (the
#     checker over-privileges a second role and must catch it)
#   - the production image builds
#   - byte budget: that image's client build, in gzip bytes, is within
#     client/byte-budget.json (the checker proves its boundary: exactly at
#     the limit passes; one byte over, a missing artifact and a missing
#     budget all fail)
#   - smoke: the running container serves client, API, health, security
#     headers, refuses a Host it was not configured for (but answers
#     /healthz on it), will not start with no hosts configured, runs as a
#     non-root user, its own `--healthcheck` probe (the Dockerfile's
#     HEALTHCHECK) says healthy against it and unhealthy against a dead
#     port — and `--migrate` applies and exits instead of serving
#   - load harness: k6 runs load/smoke.js against that container, one user
#     and correctness thresholds only, never timing (a planted run at a
#     dead port must end with k6's crossed-thresholds exit code, 99)
#   - end-to-end: Playwright against the production container
#   - mutation canary: a planted server bug must fail the tests
#
# A check that needs an earlier one is skipped when that one failed, and the
# skip names it: the byte budget, the smoke test, the load harness and the
# end-to-end suite need the production image, the last two need the running
# container, and the mutation canary needs green server tests. So the report
# leads with the failure that caused the rest. Before this, an image that did
# not build sent the end-to-end suite at a container that never started, and
# eight CI runs of ERR_NAME_NOT_RESOLVED were read as a delivery.spec flake.
# The first check proves it: scripts/verify.sh --self-test runs this script
# on a copy of the tree with Docker, curl and the other checkers stubbed. A
# green copy must run the end-to-end suite and pass. A copy whose image does
# not build must not run it, and must report the build as its one failure. A
# copy whose server tests fail must not score the mutation canary.
#
# Exit code 0 means everything passed.

set -u -o pipefail

cd "$(dirname "$0")/.." || exit 1

# verify_self_test: run this script on stubbed copies of the tree (see the
# header) and check what it ran and what it reported.
verify_self_test() {
  local dir bin failed=0 code out ran
  dir="$(mktemp -d)"
  # shellcheck disable=SC2064 # expand now: the directory name is fixed
  trap "rm -rf '$dir'" EXIT
  bin="$dir/bin"
  mkdir -p "$bin"
  # docker: every call is logged. The production image build fails when
  # STUB_BUILD=fail. The server tests fail when STUB_SERVER=fail, and when
  # the canary's planted greeting is in the tree, and report their counts the
  # way the .NET runner does. Everything else answers as a healthy image would.
  cat > "$bin/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
args=" $* "
case "$1" in
  build)
    if [ "${STUB_BUILD:-}" = fail ] && [[ "$args" == *" -t $STUB_IMAGE "* ]]; then
      echo "planted: the production image does not build" >&2
      exit 1
    fi ;;
  image) echo 1654 ;;
  inspect) if [[ "$args" == *ExitCode* ]]; then echo "exited 0"; else echo exited; fi ;;
  # The app's log goes on after the line the smoke test looks for, as a
  # crashing .NET process does. A reader that stops at the match closes the
  # pipe, and the late line then dies of SIGPIPE.
  logs) echo "migrate: applied"; echo "HostAllowlist__Hosts is not set"; sleep 0.3; echo "   at Program.<Main>(String[] args)" ;;
  exec) [[ "$args" == *ASPNETCORE_HTTP_PORTS=8099* ]] && exit 1 ;;
  run)
    if [[ "$args" == *grafana/k6* ]]; then
      [[ "$args" == *":9 "* ]] && exit 99
    elif [[ "$args" == *COVERAGE_MODE=* ]]; then
      if [ "${STUB_SERVER:-}" = fail ] || grep -q Goodbye server/Api/Program.cs; then
        echo "Test summary: total: 5, failed: 1, succeeded: 4"
        exit 1
      fi
      echo "Test summary: total: 5, failed: 0, succeeded: 5"
      echo "server line coverage: 90.0% (minimum 85%)"
    elif [[ "$args" == *":/out "* ]]; then
      out="${args%%:/out *}"; out="${out##* }"
      cp server/Api/openapi.json client/src/api-types.d.ts "$out/"
    elif [[ "$args" == *mcr.microsoft.com/playwright* ]]; then
      echo "3 passed"
    fi ;;
esac
exit 0
STUB
  # curl: the answers the smoke test expects from a healthy container.
  cat > "$bin/curl" <<'STUB'
#!/usr/bin/env bash
args=" $* "
if [[ "$args" == *http_code* ]]; then
  if [[ "$args" == */healthz* ]]; then echo 200; else echo 400; fi
else
  echo '<div id="root"> {"message":"Hello from the API"} x-content-type-options: nosniff'
fi
STUB
  chmod +x "$bin/docker" "$bin/curl"

  # run_copy <scenario> [VAR=value...]: verify.sh on a fresh copy of the
  # tracked tree, every other checker replaced by one that passes. Sets
  # code, out and ran (the docker calls it made).
  run_copy() {
    local copy="$dir/$1" f
    shift
    mkdir -p "$copy"
    git ls-files | tar -cf - -T - | tar -xf - -C "$copy"
    cp scripts/verify.sh "$copy/scripts/verify.sh"
    for f in "$copy"/scripts/*.sh "$copy"/scripts/*/*.sh; do
      [ -f "$f" ] && [ "$f" != "$copy/scripts/verify.sh" ] || continue
      printf '#!/bin/sh\nexit 0\n' > "$f"
    done
    : > "$copy.docker"
    code=0
    out="$(cd "$copy" && env -u GITHUB_STEP_SUMMARY -u GITHUB_ACTIONS -u CI PATH="$bin:$PATH" \
      STUB_LOG="$copy.docker" STUB_IMAGE="$(basename "$copy" | tr '[:upper:]' '[:lower:]'):latest" \
      VERIFY_SELF_TEST_INNER=1 NO_COLOR=1 "$@" ./scripts/verify.sh 2>&1)" || code=$?
    ran="$(cat "$copy.docker")"
  }
  ok() { echo "self-test: ok: $1"; }
  flunk() { echo "self-test FAILED: $1" >&2; printf '%s\n' "$out" | tail -30 | sed 's/^/    /' >&2; failed=1; }
  check() { if "${@:2}"; then ok "$1"; else flunk "$1"; fi; }
  # shellcheck disable=SC2329  # invoked through check()
  absent() { ! grep -Eq "$1" <<< "$ran"; }
  # shellcheck disable=SC2329  # invoked through check()
  absent_in_out() { ! grep -Eq "$1" <<< "$out"; }
  failures() { printf '%s\n' "$out" | awk '/^FAILURES:/ { f = 1; next } /^NOT RUN/ { f = 0 } f && sub(/^  - /, "")'; }

  run_copy green
  check "a tree whose checks all pass exits 0 (exit $code)" [ "$code" -eq 0 ]
  check "and it ran the end-to-end suite" grep -q 'mcr.microsoft.com/playwright' <<< "$ran"
  check "and the load harness" grep -q 'grafana/k6' <<< "$ran"

  run_copy nobuild STUB_BUILD=fail
  check "a production image that does not build fails the run (exit $code)" [ "$code" -eq 1 ]
  check "the build is the one failure reported" [ "$(failures)" = "Production image build" ]
  check "the end-to-end suite never ran" absent 'mcr\.microsoft\.com/playwright'
  check "nor the load harness, nor the smoke container" absent 'grafana/k6|--name nobuild-verify-app'
  check "and each is reported as not run, naming the build" \
    grep -q '^\[SKIP\] End-to-end suite (not run: "Production image build" failed first)' <<< "$out"

  run_copy noserver STUB_SERVER=fail
  check "failing server tests fail the run (exit $code)" [ "$code" -eq 1 ]
  check "and the mutation canary is not scored against them" [ "$(failures)" = "Server build/tests/coverage" ]
  check "the canary did not pass on the failures already there" absent_in_out '^\[PASS\] Mutation canary'
  check "it says why" grep -q '^\[SKIP\] Mutation canary (not run: "Server build/tests/coverage" failed first)' <<< "$out"

  if [ "$failed" -eq 0 ]; then
    echo "self-test: a green tree ran every check, an image that did not build stopped the checks that need it and was the one failure named, and failing server tests kept the canary from passing"
  fi
  return "$failed"
}

if [ "${1:-}" = --self-test ]; then
  verify_self_test
  exit $?
fi

NAME="$(basename "$PWD" | tr '[:upper:]' '[:lower:]')"
IMAGE="$NAME:latest"
NET="$NAME-verify-net"
APP="$NAME-verify-app"
# Toolchain images are derived from their sources of truth — the Dockerfile
# (digest-pinned, kept current by Dependabot) and e2e/package.json — so this
# script can never drift from what the build actually uses.
SDK_IMAGE="$(sed -n 's|^FROM \(mcr\.microsoft\.com/dotnet/sdk:[^ ]*\) AS server-build$|\1|p' Dockerfile)"
NODE_IMAGE="$(sed -n 's|^FROM \(node:[^ ]*\) AS node-base$|\1|p' Dockerfile)"
PLAYWRIGHT_VERSION="$(sed -n 's|.*"@playwright/test": "\([^"]*\)".*|\1|p' e2e/package.json)"
PLAYWRIGHT_IMAGE="mcr.microsoft.com/playwright:v${PLAYWRIGHT_VERSION}-noble"
# The k6 image is the one `make load` runs, from compose.yaml.
K6_IMAGE="$(sed -n 's|^ *image: \(grafana/k6:[^ ]*\)$|\1|p' compose.yaml)"
if [ -z "$SDK_IMAGE" ] || [ -z "$NODE_IMAGE" ] || [ -z "$PLAYWRIGHT_VERSION" ] || [ -z "$K6_IMAGE" ]; then
  echo "error: could not derive toolchain images from Dockerfile / e2e/package.json / compose.yaml" >&2
  exit 1
fi
SMOKE_PORT="${SMOKE_PORT:-18080}"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
  RED=""; GREEN=""; YELLOW=""; BOLD=""; RESET=""
fi

# Counted from the banners below, so adding a check cannot leave it stale.
CHECKS_TOTAL="$(grep -c '^banner "' scripts/verify.sh)"
CHECKS_RUN=0
CHECKS_PASSED=0
CHECKS_FAILED=0
CHECKS_SKIPPED=0
TESTS_PASSED=0
TESTS_FAILED=0
FAILED_NAMES=""
LOG="$(mktemp)"

# When CI provides a step-summary file (GITHUB_STEP_SUMMARY), the run also
# appends a markdown report of the same tally and exports the two coverage
# reports to coverage-artifacts/ for the (optional) Codecov upload step.
# Local runs are untouched: with the variable unset, everything below is a
# no-op and the terminal output is identical either way.
CURRENT_CHECK=""
SUMMARY_ROWS=""
SERVER_COVERAGE_PCT=""
CLIENT_COVERAGE_PCT=""
COV_OUT=""
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  COV_OUT="$PWD/coverage-artifacts"
  rm -rf "$COV_OUT"
  mkdir -p "$COV_OUT"
fi

# shellcheck disable=SC2329  # invoked via the EXIT trap below
cleanup() {
  docker rm -f "$APP" > /dev/null 2>&1
  docker rm -f "$NAME-verify-e2e" > /dev/null 2>&1
  docker rm -f "$NAME-verify-migrate" "$NAME-verify-nohosts" "$NAME-verify-db" > /dev/null 2>&1
  docker rm -f "$NAME-byte-budget-src" "$NAME-byte-budget" "$NAME-check-pii" > /dev/null 2>&1
  docker network rm "$NET" > /dev/null 2>&1
  rm -f "$LOG"
}
trap cleanup EXIT

banner() {
  CURRENT_CHECK="$1"
  printf '\n%s== [%d/%d] %s ==%s\n' "$BOLD" "$((CHECKS_RUN + 1))" "$CHECKS_TOTAL" "$1" "$RESET"
}

summary_row() {
  SUMMARY_ROWS="$SUMMARY_ROWS| $CURRENT_CHECK | $1 |\n"
}

tally() {
  printf '%sRunning tally: checks %d passed / %d failed, tests %d passed / %d failed%s\n' \
    "$BOLD" "$CHECKS_PASSED" "$CHECKS_FAILED" "$TESTS_PASSED" "$TESTS_FAILED" "$RESET"
}

pass() {
  CHECKS_RUN=$((CHECKS_RUN + 1)); CHECKS_PASSED=$((CHECKS_PASSED + 1))
  summary_row "pass"
  printf '%s[PASS]%s %s\n' "$GREEN" "$RESET" "$1"
  tally
}

fail() {
  CHECKS_RUN=$((CHECKS_RUN + 1)); CHECKS_FAILED=$((CHECKS_FAILED + 1))
  summary_row "**FAIL**"
  FAILED_NAMES="$FAILED_NAMES  - $1\n"
  printf '%s[FAIL]%s %s\n' "$RED" "$RESET" "$1"
  tally
}

skip() {
  CHECKS_RUN=$((CHECKS_RUN + 1)); CHECKS_SKIPPED=$((CHECKS_SKIPPED + 1))
  summary_row "skipped"
  printf '%s[SKIP]%s %s\n' "$YELLOW" "$RESET" "$1"
}

# What a later check depends on, and the failed check that broke it: one
# "<key><TAB><check name>" line per broken prerequisite (see the header).
BROKEN=""
broke() { BROKEN="$BROKEN$1"$'\t'"$2"$'\n'; }
NOT_RUN=""
# blocked <key> <check> <prerequisite key>...: when a prerequisite is
# broken, skip <check> naming the failure behind it, mark <key> broken by
# the same failure for the checks after, and succeed.
blocked() {
  local key="$1" what="$2" p cause
  shift 2
  for p; do
    cause="$(printf '%s' "$BROKEN" | awk -F '\t' -v k="$p" '$1 == k { print $2; exit }')"
    if [ -n "$cause" ]; then
      broke "$key" "$cause"
      NOT_RUN="$NOT_RUN  - $what\n"
      skip "$what (not run: \"$cause\" failed first)"
      return 0
    fi
  done
  return 1
}

# Add "N passed / M failed" style counts found in a tool's output to the tally.
count_tests() {
  local passed="$1" failed="$2"
  TESTS_PASSED=$((TESTS_PASSED + ${passed:-0}))
  TESTS_FAILED=$((TESTS_FAILED + ${failed:-0}))
}

# Server line coverage the tests must reach. Measured 92% on 2026-08; the
# gate sits below that so a reasonable refactor doesn't break the build,
# while a change landing meaningful untested logic does.
SERVER_COVERAGE_MIN=85

# Run the server test suite in the SDK container against a copy of the tree.
# Named volumes cache NuGet packages between runs. With "coverage", the run
# also collects line coverage (coverlet.MTP) and fails below
# SERVER_COVERAGE_MIN — enforced here by parsing the cobertura report,
# because the coverlet MTP extension collects but does not gate.
#
# --coverlet-single-hit: the floor reads covered-or-not, never the counts,
# and coverlet's default keeps a hit counter running inside whatever loops
# the tests drive hardest (on aberaTech, 2026-09-08: 15 s bare, 8 m 38 s
# instrumented, 28 s with single hit, identical line-rate). The template's
# suite is too small to show it (117 tests: ~1 s bare, ~2 s either way),
# but every app generated from here inherits the setting before it grows.
server_tests() {
  # In CI (COV_OUT set), mount coverage-artifacts/ so the cobertura report
  # survives the container for the summary and the Codecov upload.
  local cov_mount=()
  if [ -n "$COV_OUT" ] && [ "${1:-}" = coverage ]; then
    cov_mount=(-v "$COV_OUT":/covout)
  fi
  docker run --rm -v "$PWD":/src:ro -v "$NAME-nuget:/root/.nuget" \
    ${cov_mount[@]+"${cov_mount[@]}"} \
    -e COVERAGE_MODE="${1:-plain}" -e COVERAGE_MIN="$SERVER_COVERAGE_MIN" "$SDK_IMAGE" bash -c '
    set -e
    cp -r /src /w
    cd /w/server
    if [ "$COVERAGE_MODE" = coverage ]; then
      dotnet test Api.Tests -c Release -p:RestoreLockedMode=true -- --coverlet --coverlet-output-format cobertura --coverlet-single-hit
      report="$(find . -name "coverage.cobertura.*.xml" | head -1)"
      [ -n "$report" ] || { echo "error: no cobertura report produced" >&2; exit 1; }
      if [ -d /covout ]; then cp "$report" /covout/server-cobertura.xml; fi
      rate="$(sed -n "s/.*<coverage[^>]*line-rate=\"\([0-9.]*\)\".*/\1/p" "$report" | head -1)"
      awk -v r="$rate" -v m="$COVERAGE_MIN" "BEGIN {
        printf \"server line coverage: %.1f%% (minimum %d%%)\n\", r * 100, m
        exit (r * 100 >= m) ? 0 : 1
      }"
    else
      dotnet test Api.Tests -c Release -p:RestoreLockedMode=true
    fi
  '
}

# The .NET test runner prints "Test summary: total: N, failed: N,
# succeeded: N"; older runners print "Passed: N / Failed: N".
server_passed() { grep -Eo 'succeeded: [0-9]+|Passed: [0-9]+' "$LOG" | tail -1 | grep -Eo '[0-9]+'; }
server_failed() { grep -Eo 'failed: [0-9]+|Failed: [0-9]+' "$LOG" | tail -1 | grep -Eo '[0-9]+'; }

banner "Verify itself: a failed check stops the checks that need it"
# The stubbed copies run this script, so inside them the check is skipped
# rather than run again.
if [ -n "${VERIFY_SELF_TEST_INNER:-}" ]; then
  skip "Verify itself (inside its own self-test)"
elif ./scripts/verify.sh --self-test > "$LOG" 2>&1; then
  grep -E '^self-test' "$LOG" || true
  pass "A failed image build stops the checks that need the image, and is the failure reported"
else
  cat "$LOG"
  fail "Verify itself (the self-test: a check ran without its prerequisite, or the report named the wrong failure)"
fi

banner "Required checks: .github/required-checks matches the pull-request jobs"
# The self-test runs first, every time, here and before every other checker
# that has one: a check that has lost the ability to fail is caught rather
# than trusted.
if ./scripts/check-required-contexts.sh --self-test 2>&1 | tee "$LOG" \
   && ./scripts/check-required-contexts.sh 2>&1 | tee -a "$LOG"; then
  pass "Required checks and pull-request job names agree (and the checker caught a renamed check)"
else
  fail "Required-checks drift guard (a context/job mismatch, or the checker's self-test)"
fi

banner "Template parity: files shared with modern-webapp-template are byte-identical to it"
# Inside the template this passes without fetching (it is the source); in a
# repository generated from it, each path in .template-parity is compared
# with the template's default branch. The self-test needs no network.
if ./scripts/check-template-parity.sh --self-test 2>&1 | tee "$LOG" \
   && ./scripts/check-template-parity.sh 2>&1 | tee -a "$LOG"; then
  pass "Shared files match the template (and the checker caught a planted drift)"
else
  fail "Template parity (a shared file drifted from the template, or the checker's self-test)"
fi

banner "Prose: the Markdown and the built pages pass the writing rules"
# The self-test runs first, every time: one fixture carries one violation per
# rule and every rule must fire on it, another is clean and must pass, so a
# rule that has stopped matching is caught here rather than trusted.
#
# Then the pages, through the `pageprose` stage: the prerendered HTML the
# image ships, checked as a reader is given it rather than as source. A
# README lints and the page beside it does not is how a line of copy that
# breaks every rule stays live.
if ./scripts/check-prose.sh --self-test > "$LOG" 2>&1 \
   && ./scripts/check-prose.sh >> "$LOG" 2>&1 \
   && docker build --target pageprose -t "$NAME-pageprose" . >> "$LOG" 2>&1; then
  grep -E '^self-test' "$LOG" || true
  pass "Prose passes .vale/styles/Abera, in the Markdown and on the pages"
else
  tail -40 "$LOG"
  fail "Prose (a rule violation in a Markdown file or a built page, or a broken self-test)"
fi

banner "Attribution: no commit on this branch credits an AI"
# The self-test first, as everywhere else: it plants a trailer and a
# generated-with line in throwaway repositories and requires both to be
# refused, then requires a clean range to pass.
#
# Then the branch itself. The commit-msg hook and the Claude PreToolUse gate
# both run on the machine making the commit, so neither sees a commit made
# anywhere they are not installed. This is the one that runs where the merge
# happens.
if ./scripts/check-attribution.sh --self-test > "$LOG" 2>&1 \
   && ./scripts/check-attribution.sh >> "$LOG" 2>&1; then
  grep -E '^check-attribution|^attribution:' "$LOG" || true
  pass "No commit on this branch credits an AI"
else
  tail -30 "$LOG"
  fail "Attribution (a commit carries an AI credit, or a broken self-test)"
fi

banner "Server: build + unit tests (warnings as errors) + coverage"
if server_tests coverage 2>&1 | tee "$LOG"; then
  count_tests "$(server_passed)" "$(server_failed)"
  SERVER_COVERAGE_PCT="$(sed -n 's/^server line coverage: \([0-9.]*\)%.*/\1/p' "$LOG" | head -1)"
  pass "Server builds clean, all tests green, coverage >= ${SERVER_COVERAGE_MIN}%"
else
  count_tests "$(server_passed)" "$(server_failed)"
  broke server "Server build/tests/coverage"
  fail "Server build/tests/coverage"
fi

# The client's coverage thresholds live in vite.config.ts (test.coverage);
# `npm run test` runs vitest with --coverage, which fails below them.
banner "Client: typecheck + lint + unit tests + coverage"
# GITHUB_ACTIONS is forwarded so Vitest's github-actions reporter (inline PR
# annotations — see client/vite.config.ts) activates in CI; in CI the
# coverage output is also mounted out for the summary and Codecov upload.
client_cov_mount=()
if [ -n "$COV_OUT" ]; then client_cov_mount=(-v "$COV_OUT":/covout); fi
if docker run --rm -v "$PWD":/src:ro -v "$NAME-npm:/npm-cache" -e npm_config_cache=/npm-cache \
    ${client_cov_mount[@]+"${client_cov_mount[@]}"} \
    -e GITHUB_ACTIONS="${GITHUB_ACTIONS:-}" "$NODE_IMAGE" sh -c '
    set -e
    cp -r /src/client /w
    cd /w
    npm ci --no-audit --no-fund
    npm run typecheck
    npm run lint
    npm run test
    if [ -d /covout ]; then
      cp coverage/coverage-summary.json coverage/lcov.info /covout/
    fi
  ' 2>&1 | tee "$LOG"; then
  count_tests "$(grep -Eo 'Tests[^0-9]*[0-9]+ passed' "$LOG" | grep -Eo '[0-9]+' | tail -1)" 0
  if [ -n "$COV_OUT" ] && [ -f "$COV_OUT/coverage-summary.json" ]; then
    CLIENT_COVERAGE_PCT="$(sed -n 's/.*"total": *{"lines":{[^}]*"pct":\([0-9.]*\).*/\1/p' "$COV_OUT/coverage-summary.json" | head -1)"
  fi
  pass "Client typechecks, lints, all tests green, coverage above thresholds"
else
  fail "Client typecheck/lint/tests/coverage"
fi

banner "OpenAPI contract: committed spec and generated client types match the code"
# The server emits openapi.json at build time (Microsoft.Extensions.
# ApiDescription.Server) and the client's api-types.d.ts is generated from
# it. Both are committed; regenerate both here from the current code and
# fail on any difference, so the server's records and the client's types
# cannot silently diverge. Same pattern as any generated-file gate: the
# committed artifact must be reproducible from source.
#
# openapi-typescript is not in the client manifest: it lives in
# tools/api-types with a TypeScript 5 of its own (that package.json says
# why), so this installs that tree, not the client's.
CONTRACT_OUT="$(mktemp -d)"
if docker run --rm -v "$PWD":/src:ro -v "$CONTRACT_OUT":/out -v "$NAME-nuget:/root/.nuget" "$SDK_IMAGE" bash -c '
    set -e
    cp -r /src /w
    cd /w/server
    dotnet build Api -c Release -p:RestoreLockedMode=true
    # install rather than cp: the file inherits the mode it had in the
    # checkout, and a tree checked out under a umask of 007 hands back a
    # root-owned 640 file that the diff below cannot read.
    install -m 644 Api/openapi.json /out/openapi.json
  ' > "$LOG" 2>&1 \
   && docker run --rm -v "$PWD":/src:ro -v "$CONTRACT_OUT":/out -v "$NAME-npm:/npm-cache" \
        -e npm_config_cache=/npm-cache "$NODE_IMAGE" sh -c '
    set -e
    cp -r /src/tools/api-types /w
    cd /w
    npm ci --no-audit --no-fund
    node_modules/.bin/openapi-typescript /out/openapi.json --output /out/api-types.d.ts
    chmod 644 /out/api-types.d.ts
  ' >> "$LOG" 2>&1 \
   && diff -u server/Api/openapi.json "$CONTRACT_OUT/openapi.json" \
   && diff -u client/src/api-types.d.ts "$CONTRACT_OUT/api-types.d.ts"; then
  pass "openapi.json and api-types.d.ts are exactly what the code generates"
else
  tail -25 "$LOG"
  echo "regenerate with 'make contract' and commit both files" >&2
  fail "OpenAPI contract drift (spec or generated types are stale)"
fi
rm -rf "$CONTRACT_OUT" 2>/dev/null || true

banner "Held majors: every newer npm and NuGet major can be taken, so Dependabot can offer it"
# The self-tests run first, every time: they replay the failure this check
# exists for from published versions (an npm peer conflict, a NuGet package
# shipping only a newer framework), so a check that has lost the ability to
# fail is caught here rather than trusted.
if ./scripts/check-held-majors.sh --self-test > "$LOG" 2>&1 \
   && ./scripts/check-held-majors.sh >> "$LOG" 2>&1; then
  grep -E ' -> |^self-test' "$LOG" || true
  pass "No npm or NuGet dependency is held behind a major it cannot take"
else
  tail -40 "$LOG"
  fail "Held majors (an uninstallable major, a stale .held-majors entry, or a broken self-test)"
fi

banner "Response DTOs: no personal or secret fields leave the API unlisted"
if ./scripts/check-response-pii.sh 2>&1 | tee "$LOG"; then
  pass "Response schemas carry no unlisted PII-named fields (and the checker caught a planted one)"
else
  fail "Response DTO discipline (a PII-named response field, or the checker's self-test)"
fi

banner "Database runtime role: rows yes, schema no"
if ./scripts/db/check-runtime-role.sh 2>&1 | tee "$LOG"; then
  pass "The runtime role can read and write rows and is refused DDL (and an over-privileged role was caught)"
else
  fail "Database runtime role (scripts/db/runtime-role.sql, or the checker's self-test)"
fi

banner "Production image builds"
# VERIFY_DOCKER_BUILD_ARGS lets CI pass layer-cache flags; it changes how
# fast the image builds, not what is built.
# shellcheck disable=SC2086
if docker build ${VERIFY_DOCKER_BUILD_ARGS:-} -t "$IMAGE" . > "$LOG" 2>&1; then
  pass "Production image built as $IMAGE"
else
  tail -25 "$LOG"
  broke image "Production image build"
  fail "Production image build"
fi

banner "Byte budget: the production client build, in compressed bytes"
# Bytes, not timing: the same numbers on a laptop and on a shared runner.
if blocked budget "Byte budget" image; then
  :
elif ./scripts/check-byte-budget.sh "$IMAGE" 2>&1 | tee "$LOG"; then
  pass "Entry JS/CSS, initial total and prerendered HTML are within client/byte-budget.json (and the checker failed one byte over)"
else
  fail "Byte budget (something grew past client/byte-budget.json, or the checker's self-test)"
fi

# `--migrate` must apply and EXIT 0 without serving (Migrations.cs): it is the
# deploy's migration step. Detached and polled rather than run in the
# foreground, so an image that serves instead fails here in 30 s rather than
# hanging the suite.
migrate_applies_and_exits() {
  local ctr="$NAME-verify-migrate" state="" logs
  docker rm -f "$ctr" > /dev/null 2>&1
  docker run -d --name "$ctr" "$IMAGE" --migrate > /dev/null || return 1
  for _ in $(seq 1 30); do
    state="$(docker inspect --format '{{.State.Status}} {{.State.ExitCode}}' "$ctr" 2> /dev/null)"
    [ "${state%% *}" = exited ] && break
    sleep 1
  done
  # The log is read whole before it is searched. Under pipefail, grep -q
  # closing the pipe at its match fails the pipeline with SIGPIPE whenever
  # the container logs another line after it.
  logs="$(docker logs "$ctr" 2>&1)"
  grep -q '^migrate:' <<< "$logs" || state="no migrate output"
  if [ "$state" != "exited 0" ]; then
    echo "--migrate did not apply and exit 0 (got: $state)"
    docker logs "$ctr" 2>&1 | tail -20
    docker rm -f "$ctr" > /dev/null 2>&1
    return 1
  fi
  docker rm -f "$ctr" > /dev/null 2>&1
}

# With no HostAllowlist__Hosts the production image must exit non-zero naming
# the variable, not serve every Host. Polled like --migrate, so an image that
# serves instead fails in 30 s rather than hanging the suite.
refuses_to_start_without_hosts() {
  local ctr="$NAME-verify-nohosts" state="" named="" logs
  docker rm -f "$ctr" > /dev/null 2>&1
  docker run -d --name "$ctr" "$IMAGE" > /dev/null || return 1
  for _ in $(seq 1 30); do
    state="$(docker inspect --format '{{.State.Status}}' "$ctr" 2> /dev/null)"
    [ "$state" = exited ] && break
    sleep 1
  done
  logs="$(docker logs "$ctr" 2>&1)"
  grep -q 'HostAllowlist__Hosts' <<< "$logs" && named=yes
  if [ "$state" != exited ] || [ "$named" != yes ]; then
    # The evidence is this container's, not the main app's: say what it did.
    echo "image with no hosts configured did not refuse to start (state: $state, exit code: $(docker inspect --format '{{.State.ExitCode}}' "$ctr" 2> /dev/null))"
    docker logs "$ctr" 2>&1 | tail -20
    docker rm -f "$ctr" > /dev/null 2>&1
    return 1
  fi
  docker rm -f "$ctr" > /dev/null 2>&1
}

banner "Smoke: production container serves client, API and health, as non-root"
docker network create "$NET" > /dev/null 2>&1
docker rm -f "$APP" > /dev/null 2>&1
# The production image answers only to the hosts it is told about
# (HostAllowlist__Hosts) and refuses to start when told nothing. The e2e
# container reaches it by container name, so that name is listed the way a
# deployment lists its domain. The probes below prove a Host nobody configured
# is refused, that /healthz is answered anyway (platform probes arrive by pod
# IP), and that the image with no hosts configured exits instead of serving.
# Non-root proof: the image's configured user must be a non-zero numeric
# uid (the Dockerfile sets USER \$APP_UID, 1654 in the chiseled base). The
# chiseled runtime has no shell to run `id` in, so the image config is the
# assertion surface; empty (root default), "root" and "0" all fail this.
# Healthcheck proof: the Dockerfile's HEALTHCHECK re-enters the binary with
# --healthcheck (Program.cs), which is all compose's service_healthy and
# `up --wait` have to go on. Run the same command inside the serving
# container: exit 0 against the live port, and exactly 1 (Program.cs's
# unhealthy code, not a crash) when ASPNETCORE_HTTP_PORTS names a port
# nothing listens on — a probe that cannot say "unhealthy" would keep a
# dead revision in rotation.
if blocked container "Production container smoke test" image; then
  :
elif docker image inspect --format '{{.Config.User}}' "$IMAGE" | grep -Eq '^[1-9][0-9]*(:[0-9]+)?$' \
   && docker run -d --rm --name "$APP" --network "$NET" -p "127.0.0.1:$SMOKE_PORT:8080" \
        -e "HostAllowlist__Hosts=localhost,$APP" "$IMAGE" > /dev/null \
   && for _ in $(seq 1 30); do curl -fsS "http://localhost:$SMOKE_PORT/healthz" > /dev/null 2>&1 && break; sleep 1; done \
   && curl -fsS "http://localhost:$SMOKE_PORT/healthz" > /dev/null \
   && curl -fsS "http://localhost:$SMOKE_PORT/" | grep -q '<div id="root">' \
   && curl -fsS "http://localhost:$SMOKE_PORT/api/hello" | grep -q '"message":"Hello from the API"' \
   && curl -fsSI "http://localhost:$SMOKE_PORT/" | grep -qi 'x-content-type-options: nosniff' \
   && [ "$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: not-this-app.example' "http://localhost:$SMOKE_PORT/")" = 400 ] \
   && [ "$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: not-this-app.example' "http://localhost:$SMOKE_PORT/healthz")" = 200 ] \
   && docker exec "$APP" dotnet Api.dll --healthcheck \
   && { docker exec -e ASPNETCORE_HTTP_PORTS=8099 "$APP" dotnet Api.dll --healthcheck; [ $? -eq 1 ]; } \
   && refuses_to_start_without_hosts \
   && migrate_applies_and_exits; then
  pass "Container serves the client, API, health and security headers as non-root; --healthcheck tells a live port from a dead one"
else
  docker logs "$APP" 2>&1 | tail -40
  broke container "Production container smoke test"
  fail "Production container smoke test"
fi

banner "Load harness: k6 runs load/smoke.js against the production container"
# Build and run, never timing: LOAD_PROFILE=smoke is one user, three passes,
# and thresholds on checks and failed requests only. The p95 bound in
# load/smoke.js belongs to `make load`. The planted run first: pointed at a
# port nothing listens on, k6 must exit 99, its code for crossed thresholds.
# Any other code is a harness that did not run, and a harness that cannot
# fail proves nothing when it passes. --user because the mount is read as
# the checkout's owner (a umask of 007 leaves the image's own user out).
k6_smoke() { # k6_smoke <base url>
  docker run --rm --network "$NET" --user "$(id -u):$(id -g)" -v "$PWD/load":/scripts:ro \
    -e BASE_URL="$1" -e LOAD_PROFILE=smoke "$K6_IMAGE" run --quiet /scripts/smoke.js
}
k6_planted=0
if blocked load "Load harness" container; then
  :
elif ! { k6_smoke "http://$APP:9" > "$LOG" 2>&1 || k6_planted=$?; [ "$k6_planted" -eq 99 ]; }; then
  tail -20 "$LOG"
  fail "Load harness (the planted run at a dead port exited $k6_planted, not 99: the harness did not run)"
elif k6_smoke "http://$APP:8080" 2>&1 | tee "$LOG"; then
  pass "k6 ran load/smoke.js against the container with every check green (and a dead port crossed its thresholds)"
else
  fail "Load harness (a check or a request failed against the running container)"
fi

banner "End-to-end: Playwright against the production container"
E2E_CTR="$NAME-verify-e2e"
docker rm -f "$E2E_CTR" > /dev/null 2>&1
# The suite is copied to /w/e2e with GITHUB_WORKSPACE=/w so that in CI the
# github reporter's workspace-relative annotation paths (e2e/<file>) match
# the repo layout; GITHUB_ACTIONS activates that reporter (see
# e2e/playwright.config.ts). Both are inert outside GitHub Actions.
# The suite reads client/src/prerenderedRoutes.ts (the list the prerender
# tool bakes) to prove every prerendered route with JavaScript off, so that
# one file travels with it at the same relative path.
if blocked e2e "End-to-end suite" container; then
  :
elif docker run --name "$E2E_CTR" --network "$NET" -v "$PWD":/src:ro -v "$NAME-npm:/npm-cache" \
     -e npm_config_cache=/npm-cache -e E2E_BASE_URL="http://$APP:8080" -e CI="${CI:-}" \
     -e GITHUB_ACTIONS="${GITHUB_ACTIONS:-}" -e GITHUB_WORKSPACE=/w \
     "$PLAYWRIGHT_IMAGE" bash -c '
    set -e
    mkdir -p /w/client/src
    cp -r /src/e2e /w/e2e
    cp /src/client/src/prerenderedRoutes.ts /w/client/src/
    cd /w/e2e
    npm ci --no-audit --no-fund
    npx playwright test
  ' 2>&1 | tee "$LOG"; then
  docker rm -f "$E2E_CTR" > /dev/null 2>&1
  count_tests "$(grep -Eo '[0-9]+ passed' "$LOG" | tail -1 | grep -Eo '[0-9]+')" 0
  pass "End-to-end suite green against the production image"
else
  count_tests "$(grep -Eo '[0-9]+ passed' "$LOG" | tail -1 | grep -Eo '[0-9]+')" \
              "$(grep -Eo '[0-9]+ failed' "$LOG" | tail -1 | grep -Eo '[0-9]+')"
  # Traces are how you see what the browser saw; app logs are the other half.
  rm -rf e2e-test-results
  docker cp "$E2E_CTR":/w/e2e/test-results e2e-test-results > /dev/null 2>&1 \
    && echo "playwright traces copied to e2e-test-results/"
  docker rm -f "$E2E_CTR" > /dev/null 2>&1
  echo "--- app logs (last 40 lines):"
  docker logs "$APP" 2>&1 | tail -40
  fail "End-to-end suite"
fi

banner "Mutation canary: do the tests catch a planted bug?"
# Against a suite that already fails, any failure count would score as a
# caught bug, so the canary needs the server tests green.
if ! blocked canary "Mutation canary" server; then
BACKUP="$(mktemp)"
cp server/Api/Program.cs "$BACKUP"
restore_canary() { cp "$BACKUP" server/Api/Program.cs; rm -f "$BACKUP"; }
perl -pi -e 's/Hello from the API/Goodbye from the API/' server/Api/Program.cs
if ! cmp -s server/Api/Program.cs "$BACKUP"; then
  server_tests > "$LOG" 2>&1
  # The exit code alone cannot tell a failing test from a build that never
  # produced one, and both are non-zero. So read the reported failure count:
  # a planted bug that does not compile measures nothing, and treating it as
  # "the tests caught it" is how this check used to pass on a broken tree.
  caught=$(server_failed)
  if [ -z "$caught" ]; then
    restore_canary
    tail -30 "$LOG"
    fail "Mutation canary (the test run reported no results at all, so the planted bug was never measured; the build is broken)"
  elif [ "$caught" -eq 0 ]; then
    restore_canary
    fail "Mutation canary (tests did NOT catch the planted bug!)"
  else
    restore_canary
    echo "planted a wrong greeting; $caught tests failed as they should, then restored"
    pass "Mutation canary: tests caught the planted bug ($caught failures)"
  fi
else
  restore_canary
  CHECKS_RUN=$((CHECKS_RUN + 1)); CHECKS_SKIPPED=$((CHECKS_SKIPPED + 1))
  summary_row "skipped"
  printf '%s[SKIP]%s Mutation canary (could not plant the mutation)\n' "$YELLOW" "$RESET"
fi
fi

# The same tally as the terminal output, rendered as markdown on the CI run
# page. Zero duplicate work: every number is parsed from the run above.
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    printf '## Verification suite\n\n'
    printf '| Check | Result |\n'
    printf '| --- | --- |\n'
    printf '%b' "$SUMMARY_ROWS"
    printf '\n'
    printf '**Checks:** %d passed, %d failed, %d skipped (of %d) &nbsp;·&nbsp; **Tests:** %d passed, %d failed\n\n' \
      "$CHECKS_PASSED" "$CHECKS_FAILED" "$CHECKS_SKIPPED" "$CHECKS_TOTAL" "$TESTS_PASSED" "$TESTS_FAILED"
    printf '| Coverage | Measured | Blocking floor |\n'
    printf '| --- | --- | --- |\n'
    printf '| Server (lines) | %s%% | %d%% (scripts/verify.sh) |\n' \
      "${SERVER_COVERAGE_PCT:-?}" "$SERVER_COVERAGE_MIN"
    printf '| Client (lines) | %s%% | 90%% (client/vite.config.ts thresholds) |\n' \
      "${CLIENT_COVERAGE_PCT:-?}"
  } >> "$GITHUB_STEP_SUMMARY"
fi

printf '\n%s========================= VERIFICATION COMPLETE =========================%s\n' "$BOLD" "$RESET"
printf 'Checks : %s%d passed%s, %s%d failed%s, %d skipped (of %d)\n' \
  "$GREEN" "$CHECKS_PASSED" "$RESET" "$RED" "$CHECKS_FAILED" "$RESET" "$CHECKS_SKIPPED" "$CHECKS_TOTAL"
printf 'Tests  : %s%d passed%s, %s%d failed%s\n' \
  "$GREEN" "$TESTS_PASSED" "$RESET" "$RED" "$TESTS_FAILED" "$RESET"
if [ "$CHECKS_FAILED" -eq 0 ]; then
  printf '%s%sALL CHECKS PASSED — this build behaves as intended.%s\n' "$BOLD" "$GREEN" "$RESET"
  exit 0
else
  printf '%s%sFAILURES:%s\n' "$BOLD" "$RED" "$RESET"
  printf '%b' "$FAILED_NAMES"
  if [ -n "$NOT_RUN" ]; then
    printf '%sNOT RUN, because a check they need failed:%s\n' "$YELLOW" "$RESET"
    printf '%b' "$NOT_RUN"
  fi
  exit 1
fi
