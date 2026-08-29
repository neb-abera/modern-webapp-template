#!/usr/bin/env bash
#
# verify.sh — run the project's full verification suite, with a running
# pass/fail count and a final summary. Everything runs in containers, so the
# host needs only Docker and git. This mirrors what CI gates before a merge:
#
#   1. server: build + unit tests (warnings as errors)
#   2. client: typecheck + lint (Biome) + unit tests
#   3. the production image builds
#   4. smoke: the running container serves client, API, health, security headers
#   5. end-to-end: Playwright against the production container
#   6. mutation canary: a planted server bug must fail the tests
#
# Exit code 0 means everything passed.

set -u -o pipefail

cd "$(dirname "$0")/.."

NAME="$(basename "$PWD" | tr '[:upper:]' '[:lower:]')"
IMAGE="$NAME:latest"
NET="$NAME-verify-net"
APP="$NAME-verify-app"
SDK_IMAGE="mcr.microsoft.com/dotnet/sdk:10.0"
NODE_IMAGE="node:24-alpine"
PLAYWRIGHT_IMAGE="mcr.microsoft.com/playwright:v1.62.1-noble"
SMOKE_PORT="${SMOKE_PORT:-18080}"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
  RED=""; GREEN=""; YELLOW=""; BOLD=""; RESET=""
fi

CHECKS_TOTAL=6
CHECKS_RUN=0
CHECKS_PASSED=0
CHECKS_FAILED=0
CHECKS_SKIPPED=0
TESTS_PASSED=0
TESTS_FAILED=0
FAILED_NAMES=""
LOG="$(mktemp)"

cleanup() {
  docker rm -f "$APP" > /dev/null 2>&1
  docker rm -f "$NAME-verify-e2e" > /dev/null 2>&1
  docker network rm "$NET" > /dev/null 2>&1
  rm -f "$LOG"
}
trap cleanup EXIT

banner() {
  printf '\n%s== [%d/%d] %s ==%s\n' "$BOLD" "$((CHECKS_RUN + 1))" "$CHECKS_TOTAL" "$1" "$RESET"
}

tally() {
  printf '%sRunning tally: checks %d passed / %d failed, tests %d passed / %d failed%s\n' \
    "$BOLD" "$CHECKS_PASSED" "$CHECKS_FAILED" "$TESTS_PASSED" "$TESTS_FAILED" "$RESET"
}

pass() {
  CHECKS_RUN=$((CHECKS_RUN + 1)); CHECKS_PASSED=$((CHECKS_PASSED + 1))
  printf '%s[PASS]%s %s\n' "$GREEN" "$RESET" "$1"
  tally
}

fail() {
  CHECKS_RUN=$((CHECKS_RUN + 1)); CHECKS_FAILED=$((CHECKS_FAILED + 1))
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

# Run the server test suite in the SDK container against a copy of the tree.
# Named volumes cache NuGet packages between runs.
server_tests() {
  docker run --rm -v "$PWD":/src:ro -v "$NAME-nuget:/root/.nuget" "$SDK_IMAGE" bash -c '
    set -e
    cp -r /src /w
    cd /w/server
    dotnet test Api.Tests -c Release
  '
}

# The .NET test runner prints "Test summary: total: N, failed: N,
# succeeded: N"; older runners print "Passed: N / Failed: N".
server_passed() { grep -Eo 'succeeded: [0-9]+|Passed: [0-9]+' "$LOG" | tail -1 | grep -Eo '[0-9]+'; }
server_failed() { grep -Eo 'failed: [0-9]+|Failed: [0-9]+' "$LOG" | tail -1 | grep -Eo '[0-9]+'; }

banner "Server: build + unit tests (warnings as errors)"
if server_tests 2>&1 | tee "$LOG"; then
  count_tests "$(server_passed)" "$(server_failed)"
  pass "Server builds clean and all tests are green"
else
  count_tests "$(server_passed)" "$(server_failed)"
  fail "Server build/tests"
fi

banner "Client: typecheck + lint + unit tests"
if docker run --rm -v "$PWD":/src:ro -v "$NAME-npm:/npm-cache" -e npm_config_cache=/npm-cache "$NODE_IMAGE" sh -c '
    set -e
    cp -r /src/client /w
    cd /w
    npm ci --no-audit --no-fund
    npm run typecheck
    npm run lint
    npm run test
  ' 2>&1 | tee "$LOG"; then
  count_tests "$(grep -Eo 'Tests[^0-9]*[0-9]+ passed' "$LOG" | grep -Eo '[0-9]+' | tail -1)" 0
  pass "Client typechecks, lints and all tests are green"
else
  fail "Client typecheck/lint/tests"
fi

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

banner "Smoke: production container serves client, API and health"
docker network create "$NET" > /dev/null 2>&1
docker rm -f "$APP" > /dev/null 2>&1
if docker run -d --rm --name "$APP" --network "$NET" -p "127.0.0.1:$SMOKE_PORT:8080" "$IMAGE" > /dev/null \
   && for i in $(seq 1 30); do curl -fsS "http://localhost:$SMOKE_PORT/healthz" > /dev/null 2>&1 && break; sleep 1; done \
   && curl -fsS "http://localhost:$SMOKE_PORT/healthz" > /dev/null \
   && curl -fsS "http://localhost:$SMOKE_PORT/" | grep -q '<div id="root">' \
   && curl -fsS "http://localhost:$SMOKE_PORT/api/hello" | grep -q '"message":"Hello from the API"' \
   && curl -fsSI "http://localhost:$SMOKE_PORT/" | grep -qi 'x-content-type-options: nosniff'; then
  pass "Container serves the client, the API, health and security headers"
else
  docker logs "$APP" 2>&1 | tail -40
  fail "Production container smoke test"
fi

banner "End-to-end: Playwright against the production container"
E2E_CTR="$NAME-verify-e2e"
docker rm -f "$E2E_CTR" > /dev/null 2>&1
if docker run --name "$E2E_CTR" --network "$NET" -v "$PWD/e2e":/src:ro -v "$NAME-npm:/npm-cache" \
     -e npm_config_cache=/npm-cache -e E2E_BASE_URL="http://$APP:8080" -e CI="${CI:-}" \
     "$PLAYWRIGHT_IMAGE" bash -c '
    set -e
    cp -r /src /w
    cd /w
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
  docker cp "$E2E_CTR":/w/test-results e2e-test-results > /dev/null 2>&1 \
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
  printf '%s[SKIP]%s Mutation canary (could not plant the mutation)\n' "$YELLOW" "$RESET"
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
