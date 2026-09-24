#!/usr/bin/env bash
#
# verify.sh — run the project's full verification suite, with a running
# pass/fail count and a final summary. Everything runs in containers, so the
# host needs only Docker and git. This mirrors what CI gates before a merge:
#
#   1. required checks: branch protection and the PR-gating workflows agree
#      (the checker first proves a renamed context and a lost pull_request
#      trigger are both caught)
#   2. template parity: every file .template-parity lists is byte-identical
#      to the template's default branch — trivially so inside the template,
#      which is the source (the checker first proves a drifted file and a
#      missing file are both caught)
#   3. prose: every tracked Markdown file passes the writing rules in
#      .vale/styles/Abera (the checker first proves every rule fires on a
#      fixture and that clean prose passes)
#   4. server: build + unit tests (warnings as errors, locked-mode restore)
#      + line coverage at or above SERVER_COVERAGE_MIN
#   5. client: typecheck + lint (Biome) + unit tests + coverage thresholds
#      (vitest.config's coverage.thresholds fail the run on their own)
#   6. OpenAPI contract: the committed spec (server/Api/openapi.json) and the
#      generated client types (client/src/api-types.d.ts) match the code
#   7. held majors: no npm dependency's next major is uninstallable and no
#      NuGet dependency's next major ships only a framework the project
#      cannot consume, the two cases Dependabot cannot open a pull request
#      for (scripts/check-held-majors.sh)
#   8. response DTOs: no response schema in that spec has a field named like
#      personal or secret data, unless allowlisted with a reason (the checker
#      plants a leaking spec and must catch it)
#   9. database runtime role: scripts/db/runtime-role.sql, applied to a real
#      PostgreSQL, allows rows and refuses CREATE/ALTER/DROP/TRUNCATE (the
#      checker over-privileges a second role and must catch it)
#  10. the production image builds
#  11. byte budget: that image's client build, in gzip bytes, is within
#      client/byte-budget.json (the checker proves its boundary: exactly at
#      the limit passes; one byte over, a missing artifact and a missing
#      budget all fail)
#  12. smoke: the running container serves client, API, health, security
#      headers, refuses a Host it was not configured for (but answers
#      /healthz on it), will not start with no hosts configured, runs as a
#      non-root user, its own `--healthcheck` probe (the Dockerfile's
#      HEALTHCHECK) says healthy against it and unhealthy against a dead
#      port — and `--migrate` applies and exits instead of serving
#  13. end-to-end: Playwright against the production container
#  14. mutation canary: a planted server bug must fail the tests
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

CHECKS_TOTAL=14
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

banner "Required checks: setup.sh's contexts match the PR-gating workflows"
# The self-test runs first, every time, here and before every other checker
# that has one: a check that has lost the ability to fail is caught rather
# than trusted.
if ./scripts/check-required-contexts.sh --self-test 2>&1 | tee "$LOG" \
   && ./scripts/check-required-contexts.sh 2>&1 | tee -a "$LOG"; then
  pass "Branch-protection contexts and PR-gating job names agree (and the checker caught a renamed context)"
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

banner "Prose: every tracked Markdown file passes the writing rules"
# The self-test runs first, every time: one fixture carries one violation per
# rule and every rule must fire on it, another is clean and must pass, so a
# rule that has stopped matching is caught here rather than trusted.
if ./scripts/check-prose.sh --self-test > "$LOG" 2>&1 \
   && ./scripts/check-prose.sh >> "$LOG" 2>&1; then
  grep -E '^self-test' "$LOG" || true
  pass "Prose passes .vale/styles/Abera"
else
  tail -40 "$LOG"
  fail "Prose (a rule violation in a Markdown file, or a broken self-test)"
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
    cp Api/openapi.json /out/openapi.json
  ' > "$LOG" 2>&1 \
   && docker run --rm -v "$PWD":/src:ro -v "$CONTRACT_OUT":/out -v "$NAME-npm:/npm-cache" \
        -e npm_config_cache=/npm-cache "$NODE_IMAGE" sh -c '
    set -e
    cp -r /src/tools/api-types /w
    cd /w
    npm ci --no-audit --no-fund
    node_modules/.bin/openapi-typescript /out/openapi.json --output /out/api-types.d.ts
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
  fail "Production image build"
fi

banner "Byte budget: the production client build, in compressed bytes"
# Bytes, not timing: the same numbers on a laptop and on a shared runner.
if ./scripts/check-byte-budget.sh "$IMAGE" 2>&1 | tee "$LOG"; then
  pass "Entry JS/CSS, initial total and prerendered HTML are within client/byte-budget.json (and the checker failed one byte over)"
else
  fail "Byte budget (something grew past client/byte-budget.json, or the checker's self-test)"
fi

# `--migrate` must apply and EXIT 0 without serving (Migrations.cs): it is the
# deploy's migration step. Detached and polled rather than run in the
# foreground, so an image that serves instead fails here in 30 s rather than
# hanging the suite.
migrate_applies_and_exits() {
  local ctr="$NAME-verify-migrate" state=""
  docker rm -f "$ctr" > /dev/null 2>&1
  docker run -d --name "$ctr" "$IMAGE" --migrate > /dev/null || return 1
  for _ in $(seq 1 30); do
    state="$(docker inspect --format '{{.State.Status}} {{.State.ExitCode}}' "$ctr" 2> /dev/null)"
    [ "${state%% *}" = exited ] && break
    sleep 1
  done
  docker logs "$ctr" 2>&1 | grep -q '^migrate:' || state="no migrate output"
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
  local ctr="$NAME-verify-nohosts" state="" named=""
  docker rm -f "$ctr" > /dev/null 2>&1
  docker run -d --name "$ctr" "$IMAGE" > /dev/null || return 1
  for _ in $(seq 1 30); do
    state="$(docker inspect --format '{{.State.Status}}' "$ctr" 2> /dev/null)"
    [ "$state" = exited ] && break
    sleep 1
  done
  docker logs "$ctr" 2>&1 | grep -q 'HostAllowlist__Hosts' && named=yes
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
if docker image inspect --format '{{.Config.User}}' "$IMAGE" | grep -Eq '^[1-9][0-9]*(:[0-9]+)?$' \
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
  fail "Production container smoke test"
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
if docker run --name "$E2E_CTR" --network "$NET" -v "$PWD":/src:ro -v "$NAME-npm:/npm-cache" \
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
