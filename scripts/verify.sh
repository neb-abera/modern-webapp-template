#!/usr/bin/env bash
#
# verify.sh — run the project's full verification suite, with a running
# pass/fail count and a final summary. Everything runs in containers, so the
# host needs only Docker and git. This mirrors what CI gates before a merge:
#
#   1. required checks: branch protection and the PR-gating workflows agree
#   2. server: build + unit tests (warnings as errors, locked-mode restore)
#      + line coverage at or above SERVER_COVERAGE_MIN
#   3. client: typecheck + lint (Biome) + unit tests + coverage thresholds
#      (vitest.config's coverage.thresholds fail the run on their own)
#   4. OpenAPI contract: the committed spec (server/Api/openapi.json) and the
#      generated client types (client/src/api-types.d.ts) match the code
#   5. the production image builds
#   6. smoke: the running container serves client, API, health, security
#      headers — and runs as a non-root user
#   7. end-to-end: Playwright against the production container
#   8. mutation canary: a planted server bug must fail the tests
#
# Exit code 0 means everything passed.

set -u -o pipefail

cd "$(dirname "$0")/.." || exit 1

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
if [ -z "$SDK_IMAGE" ] || [ -z "$NODE_IMAGE" ] || [ -z "$PLAYWRIGHT_VERSION" ]; then
  echo "error: could not derive toolchain images from Dockerfile / e2e/package.json" >&2
  exit 1
fi
SMOKE_PORT="${SMOKE_PORT:-18080}"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
  RED=""; GREEN=""; YELLOW=""; BOLD=""; RESET=""
fi

CHECKS_TOTAL=8
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
      dotnet test Api.Tests -c Release -p:RestoreLockedMode=true -- --coverlet --coverlet-output-format cobertura
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

banner "Required checks: setup.sh's contexts match the PR-gating workflows"
if ./scripts/check-required-contexts.sh 2>&1 | tee "$LOG"; then
  pass "Branch-protection contexts and PR-gating job names agree"
else
  fail "Required-checks drift guard"
fi

banner "Server: build + unit tests (warnings as errors) + coverage"
if server_tests coverage 2>&1 | tee "$LOG"; then
  count_tests "$(server_passed)" "$(server_failed)"
  SERVER_COVERAGE_PCT="$(sed -n 's/^server line coverage: \([0-9.]*\)%.*/\1/p' "$LOG" | head -1)"
  pass "Server builds clean, all tests green, coverage >= ${SERVER_COVERAGE_MIN}%"
else
  count_tests "$(server_passed)" "$(server_failed)"
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
CONTRACT_OUT="$(mktemp -d)"
if docker run --rm -v "$PWD":/src:ro -v "$CONTRACT_OUT":/out -v "$NAME-nuget:/root/.nuget" "$SDK_IMAGE" bash -c '
    set -e
    cp -r /src /w
    cd /w/server
    dotnet build Api -c Release -p:RestoreLockedMode=true
    cp Api/openapi.json /out/openapi.json
  ' > "$LOG" 2>&1 \
   && docker run --rm -v "$PWD":/src:ro -v "$CONTRACT_OUT":/out -v "$NAME-npm:/npm-cache" \
        -e npm_config_cache=/npm-cache "$NODE_IMAGE" sh -c '
    set -e
    cp -r /src/client /w
    cd /w
    npm ci --no-audit --no-fund
    npx openapi-typescript /out/openapi.json --output /out/api-types.d.ts
  ' >> "$LOG" 2>&1 \
   && diff -u server/Api/openapi.json "$CONTRACT_OUT/openapi.json" \
   && diff -u client/src/api-types.d.ts "$CONTRACT_OUT/api-types.d.ts"; then
  pass "openapi.json and api-types.d.ts are exactly what the code generates"
else
  tail -25 "$LOG"
  echo "regenerate with: a server build (emits server/Api/openapi.json)," >&2
  echo "then 'npm run generate:api-types' in client/, and commit both" >&2
  fail "OpenAPI contract drift (spec or generated types are stale)"
fi
rm -rf "$CONTRACT_OUT" 2>/dev/null || true

banner "Production image builds"
# VERIFY_DOCKER_BUILD_ARGS lets CI pass layer-cache flags; it changes how
# fast the image builds, not what is built.
# shellcheck disable=SC2086
if docker build ${VERIFY_DOCKER_BUILD_ARGS:-} -t "$IMAGE" . > "$LOG" 2>&1; then
  pass "Production image built as $IMAGE"
else
  tail -25 "$LOG"
  fail "Production image build"
fi

banner "Smoke: production container serves client, API and health, as non-root"
docker network create "$NET" > /dev/null 2>&1
docker rm -f "$APP" > /dev/null 2>&1
# Non-root proof: the image's configured user must be a non-zero numeric
# uid (the Dockerfile sets USER \$APP_UID, 1654 in the chiseled base). The
# chiseled runtime has no shell to run `id` in, so the image config is the
# assertion surface; empty (root default), "root" and "0" all fail this.
if docker image inspect --format '{{.Config.User}}' "$IMAGE" | grep -Eq '^[1-9][0-9]*(:[0-9]+)?$' \
   && docker run -d --rm --name "$APP" --network "$NET" -p "127.0.0.1:$SMOKE_PORT:8080" "$IMAGE" > /dev/null \
   && for _ in $(seq 1 30); do curl -fsS "http://localhost:$SMOKE_PORT/healthz" > /dev/null 2>&1 && break; sleep 1; done \
   && curl -fsS "http://localhost:$SMOKE_PORT/healthz" > /dev/null \
   && curl -fsS "http://localhost:$SMOKE_PORT/" | grep -q '<div id="root">' \
   && curl -fsS "http://localhost:$SMOKE_PORT/api/hello" | grep -q '"message":"Hello from the API"' \
   && curl -fsSI "http://localhost:$SMOKE_PORT/" | grep -qi 'x-content-type-options: nosniff'; then
  pass "Container serves the client, API, health and security headers as non-root"
else
  docker logs "$APP" 2>&1 | tail -40
  fail "Production container smoke test"
fi

banner "End-to-end: Playwright against the production container"
E2E_CTR="$NAME-verify-e2e"
docker rm -f "$E2E_CTR" > /dev/null 2>&1
# The suite is copied to /w/e2e with GITHUB_WORKSPACE=/w so that in CI the
# github reporter's workspace-relative annotation paths (e2e/<file>) match
# the repo layout; GITHUB_ACTIONS activates that reporter (see
# e2e/playwright.config.ts). Both are inert outside GitHub Actions.
if docker run --name "$E2E_CTR" --network "$NET" -v "$PWD/e2e":/src:ro -v "$NAME-npm:/npm-cache" \
     -e npm_config_cache=/npm-cache -e E2E_BASE_URL="http://$APP:8080" -e CI="${CI:-}" \
     -e GITHUB_ACTIONS="${GITHUB_ACTIONS:-}" -e GITHUB_WORKSPACE=/w \
     "$PLAYWRIGHT_IMAGE" bash -c '
    set -e
    mkdir -p /w
    cp -r /src /w/e2e
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
BACKUP="$(mktemp)"
cp server/Api/Program.cs "$BACKUP"
restore_canary() { cp "$BACKUP" server/Api/Program.cs; rm -f "$BACKUP"; }
perl -pi -e 's/Hello from the API/Goodbye from the API/' server/Api/Program.cs
if ! cmp -s server/Api/Program.cs "$BACKUP"; then
  if server_tests > "$LOG" 2>&1; then
    restore_canary
    fail "Mutation canary (tests did NOT catch the planted bug!)"
  else
    caught=$(server_failed)
    restore_canary
    echo "planted a wrong greeting; ${caught:-some} tests failed as they should, then restored"
    pass "Mutation canary: tests caught the planted bug (${caught:-?} failures)"
  fi
else
  restore_canary
  CHECKS_RUN=$((CHECKS_RUN + 1)); CHECKS_SKIPPED=$((CHECKS_SKIPPED + 1))
  summary_row "skipped"
  printf '%s[SKIP]%s Mutation canary (could not plant the mutation)\n' "$YELLOW" "$RESET"
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
  exit 1
fi
