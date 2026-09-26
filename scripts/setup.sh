#!/usr/bin/env bash
#
# setup.sh: one-command setup for a repository generated from this template.
#
#   ./scripts/setup.sh              set up the repository named by `origin`
#   ./scripts/setup.sh --self-test  prove the rename and the settings work
#   ./scripts/setup.sh --self-test --build
#                                   and build and test the renamed copy
#
# What it does:
#   1. renames the app after your repository (page title, heading, the unit
#      and e2e expectations of that heading, the README heading, badges and
#      links, NOTICE, SECURITY.md advisory URL) and pushes the change
#   2. enables the GitHub settings templates cannot carry over: secret
#      scanning, push protection, private vulnerability reporting, Dependabot
#      alerts and security updates, auto-merge, the Update branch button and
#      deleting merged branches
#   3. enables branch protection on the default branch requiring every check
#      in .github/required-checks, strict (a pull request must be up to date)
#   4. sets up commit signing and requires Verified commits once it works
#
# Requirements: git, perl, and the GitHub CLI (`gh`, https://cli.github.com)
# authenticated as an admin of the repository. Safe to re-run: every step is
# idempotent.
#
# --self-test needs no network and no GitHub account. It copies the tree to
# a temp directory and runs the rename there with a made-up repository
# name, then fails on any file that still names the template and on any
# file the rename lists that it did not change. It runs this script against
# a stubbed `gh` and checks what would have been sent: the repository
# settings and the required checks. Each of those assertions is then shown
# to fail on a planted defect: a leftover template name, and a PATCH that
# no longer turns on the Update branch button.
#
# --build (`make generate`, and the CI job `generate`) then builds the
# renamed copy's production image and runs its server, client and
# end-to-end tests against it, in the images verify.sh uses. The copy's
# tests expect the new name, so a rename that misses a file fails here.

set -euo pipefail

cd "$(dirname "$0")/.."

TEMPLATE_NAME="Modern Web App"
TEMPLATE_OWNER_REPO="neb-abera/modern-webapp-template"

# Files that carry the app's display name, and files that carry the
# repository's URL. The rename edits exactly these.
NAME_FILES=(client/index.html client/src/App.tsx client/tests/entry-server.test.tsx
  e2e/smoke.spec.ts e2e/delivery.spec.ts README.md)
REPO_FILES=(README.md SECURITY.md .github/ISSUE_TEMPLATE/config.yml server/Api/SecurityTxt.cs)

# Files that name the template on purpose after a rename: the parity check
# compares shared files with the template, and this script names what it
# renames from.
TEMPLATE_REFERENCES=(.template-parity scripts/check-template-parity.sh scripts/setup.sh scripts/verify.sh)

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
  GREEN=""; YELLOW=""; BOLD=""; RESET=""
fi
step() { printf '%s==>%s %s\n' "$BOLD" "$RESET" "$1"; }
done_() { printf '%s  done:%s %s\n' "$GREEN" "$RESET" "$1"; }
warn() { printf '%s  note:%s %s\n' "$YELLOW" "$RESET" "$1"; }

# rename_files <owner/repo>: rewrite the tree in the current directory for
# that repository. File edits only: the caller commits.
rename_files() {
  local repo=${1##*/}
  # The README heading first: "<name> Template" describes the template, and
  # the generated repository is not one.
  NEW_NAME="$repo" OLD_NAME="$TEMPLATE_NAME" perl -pi -e \
    's/^# \Q$ENV{OLD_NAME}\E Template$/# $ENV{NEW_NAME}/' README.md
  NEW_NAME="$repo" OLD_NAME="$TEMPLATE_NAME" perl -pi -e \
    's/\Q$ENV{OLD_NAME}\E/$ENV{NEW_NAME}/g' "${NAME_FILES[@]}"
  # README links and the private-advisory URLs (SECURITY.md, the issue
  # template contact link, security.txt) point at the generated repository.
  NEW_REPO="$1" OLD_REPO="$TEMPLATE_OWNER_REPO" perl -pi -e \
    's#\Q$ENV{OLD_REPO}\E#$ENV{NEW_REPO}#g' "${REPO_FILES[@]}"
  # NOTICE's first line names the work. The copyright line stays: it covers
  # the template's code the repository still carries.
  NEW_NAME="$repo" perl -pi -e '$_ = "$ENV{NEW_NAME}\n" if $. == 1' NOTICE
}

# template_leftovers <dir>: every file under <dir> that still names the
# template, outside TEMPLATE_REFERENCES. "Modern Web Application" (a ZAP
# rule name) is not the app's name.
template_leftovers() {
  local exclude=() f
  for f in "${TEMPLATE_REFERENCES[@]}"; do exclude+=(-e "^\./$f:"); done
  (cd "$1" && grep -rInE --exclude-dir=.git \
    -e "${TEMPLATE_NAME}([^A-Za-z]|\$)" -e "${TEMPLATE_OWNER_REPO##*/}" . \
    | grep -v "${exclude[@]}") || true
}

# settings_problems <gh log> <expected contexts JSON>: what a run of this
# script against the stubbed gh failed to send.
settings_problems() {
  local log="$1" want="$2"
  grep -q -- '-F allow_update_branch=true' "$log" \
    || echo "no PATCH turned on allow_update_branch (strict checks need the Update branch button)"
  grep -q -- '-F allow_auto_merge=true' "$log" \
    || echo "no PATCH turned on allow_auto_merge (Dependabot auto-merge needs it)"
  grep -q -- '-F delete_branch_on_merge=true' "$log" \
    || echo "no PATCH turned on delete_branch_on_merge"
  grep -q '"strict": true' "$log" \
    || echo "branch protection was not strict"
  grep -qF "\"contexts\": $want" "$log" \
    || echo "branch protection did not require exactly .github/required-checks: $want"
}

# build_and_test <tree> <name>: the production image of <tree>, then its
# server, client and end-to-end tests, in the images verify.sh derives.
# Containers, network and image carry <name>, and are removed on the way out.
build_and_test() (
  local tree="$1" name="$2" sdk node pw
  set -euo pipefail
  cd "$tree"
  sdk="$(sed -n 's|^FROM \(mcr\.microsoft\.com/dotnet/sdk:[^ ]*\) AS server-build$|\1|p' Dockerfile)"
  node="$(sed -n 's|^FROM \(node:[^ ]*\) AS node-base$|\1|p' Dockerfile)"
  pw="mcr.microsoft.com/playwright:v$(sed -n 's|.*"@playwright/test": "\([^"]*\)".*|\1|p' e2e/package.json)-noble"
  if [ -z "$sdk" ] || [ -z "$node" ]; then echo "error: could not derive the toolchain images" >&2; exit 1; fi
  # shellcheck disable=SC2064 # expand now: the names are fixed
  trap "docker rm -f '$name-app' > /dev/null 2>&1; docker network rm '$name-net' > /dev/null 2>&1; docker image rm '$name:latest' > /dev/null 2>&1" EXIT

  step "Building the renamed copy's production image"
  # shellcheck disable=SC2086 # a list of flags, as in verify.sh
  docker build ${VERIFY_DOCKER_BUILD_ARGS:-} -t "$name:latest" .

  step "Server tests of the renamed copy"
  docker run --rm -v "$tree":/src:ro -v "$name-nuget:/root/.nuget" "$sdk" \
    bash -c 'cp -r /src /w && cd /w/server && dotnet test Api.Tests -c Release -p:RestoreLockedMode=true'

  step "Client typecheck and tests of the renamed copy"
  docker run --rm -v "$tree":/src:ro -v "$name-npm:/npm-cache" -e npm_config_cache=/npm-cache "$node" \
    sh -c 'cp -r /src/client /w && cd /w && npm ci --no-audit --no-fund && npm run typecheck && npm run test'

  step "End-to-end tests against the renamed copy"
  docker network create "$name-net" > /dev/null
  docker run -d --rm --name "$name-app" --network "$name-net" \
    -e "HostAllowlist__Hosts=$name-app" "$name:latest" > /dev/null
  docker run --rm --network "$name-net" -v "$tree":/src:ro -v "$name-npm:/npm-cache" \
    -e npm_config_cache=/npm-cache -e E2E_BASE_URL="http://$name-app:8080" -e CI="${CI:-}" "$pw" bash -c '
      set -e
      mkdir -p /w/client/src
      cp -r /src/e2e /w/e2e
      cp /src/client/src/prerenderedRoutes.ts /w/client/src/
      cd /w/e2e
      npm ci --no-audit --no-fund
      npx playwright test'
)

self_test() {
  local dir src failed=0 problems leftovers f build="${1:-}" name
  src="$PWD"
  dir="$(mktemp -d)"
  # shellcheck disable=SC2064 # expand now: the directory name is fixed
  trap "rm -rf '$dir'" EXIT
  fail_() { echo "self-test FAILED: $1" >&2; failed=1; }
  ok() { echo "self-test: ok: $1"; }

  # The tree as it stands, tracked and new files, without anything ignored.
  copy_tree() { # copy_tree <dest>
    mkdir -p "$1"
    (cd "$src" && git ls-files -z --cached --others --exclude-standard \
      | while IFS= read -r -d '' f; do [ -e "$f" ] && printf '%s\0' "$f"; done \
      | tar --null -T - -cf -) | tar -xf - -C "$1"
  }

  # 1. The rename, with a repository name nothing else in the tree uses.
  copy_tree "$dir/generated"
  (cd "$dir/generated" && rename_files example-owner/acme-portal)
  leftovers="$(template_leftovers "$dir/generated")"
  if [ -z "$leftovers" ]; then ok "no file names the template after the rename"
  else fail_ "files still name the template after the rename:"; printf '%s\n' "$leftovers" | sed 's/^/    /' >&2; fi
  for f in "${NAME_FILES[@]}" "${REPO_FILES[@]}"; do
    grep -q 'acme-portal' "$dir/generated/$f" || fail_ "the rename lists $f and did not change it"
  done
  if [ "$(head -1 "$dir/generated/NOTICE")" = acme-portal ]; then ok "NOTICE names the generated project"
  else fail_ "NOTICE does not name the generated project"; fi
  if grep -qx '# acme-portal' "$dir/generated/README.md"; then ok "the README heading is the project's name"
  else fail_ "the README heading is not '# acme-portal'"; fi

  # 1a. Planted: a file the rename does not cover. It must be named.
  cp -R "$dir/generated" "$dir/leftover"
  echo "Welcome to $TEMPLATE_NAME." > "$dir/leftover/docs/planted.md"
  if template_leftovers "$dir/leftover" | grep -q '^\./docs/planted\.md:'; then
    ok "a planted leftover template name is reported"
  else fail_ "a planted leftover in docs/planted.md was not reported"; fi

  # 2. The settings, against a stubbed gh. The origin is the template, so
  # the rename and its push are skipped, and signing is stubbed to report
  # failure, so nothing touches this machine's keys or the network.
  mkdir -p "$dir/bin"
  cat > "$dir/bin/gh" << 'STUB'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >> "$GH_LOG"
case " $* " in *" --input - "*) cat >> "$GH_LOG" ;; esac
case " $* " in *" .default_branch "*) echo main ;; esac
exit 0
STUB
  chmod +x "$dir/bin/gh"
  run_setup() { # run_setup <tree>: setup.sh in <tree> against the stub
    printf '#!/bin/sh\nexit 1\n' > "$1/scripts/setup-signing.sh"
    git -C "$1" init -q
    git -C "$1" remote add origin "https://github.com/$TEMPLATE_OWNER_REPO.git"
    (cd "$1" && GH_LOG="$1.gh.log" PATH="$dir/bin:$PATH" NO_COLOR=1 ./scripts/setup.sh > "$1.out" 2>&1)
  }
  want="$(./scripts/check-required-contexts.sh --json)"

  copy_tree "$dir/settings"
  if run_setup "$dir/settings"; then
    problems="$(settings_problems "$dir/settings.gh.log" "$want")"
    if [ -z "$problems" ]; then ok "setup.sh sends the repository settings and the required checks"
    else fail_ "setup.sh against a stubbed gh:"; printf '%s\n' "$problems" | sed 's/^/    /' >&2; fi
  else
    fail_ "setup.sh against a stubbed gh exited non-zero:"; sed 's/^/    /' "$dir/settings.out" >&2
  fi

  # 2a. Planted: the Update branch flag dropped from the PATCH.
  copy_tree "$dir/noupdate"
  perl -pi -e 's/ -F allow_update_branch=true//' "$dir/noupdate/scripts/setup.sh"
  run_setup "$dir/noupdate" || true
  if settings_problems "$dir/noupdate.gh.log" "$want" | grep -q allow_update_branch; then
    ok "a PATCH without allow_update_branch is reported"
  else fail_ "a PATCH without allow_update_branch was not reported"; fi

  if [ "$failed" -eq 0 ]; then
    echo "self-test: the rename leaves no template name, the settings are sent, and both checks caught their planted defect"
  fi

  # 3. The renamed copy builds and passes its own tests.
  if [ "$build" = --build ] && [ "$failed" -eq 0 ]; then
    name="$(basename "$src" | tr '[:upper:]' '[:lower:]')-generated"
    if build_and_test "$dir/generated" "$name"; then
      echo "self-test: ok: the renamed copy builds and passes its server, client and end-to-end tests"
    else
      fail_ "the renamed copy did not build or did not pass its tests (output above)"
    fi
  fi
  return "$failed"
}

case "${1:-}" in
  --self-test)
    case "${2:-}" in
      ""|--build) self_test "${2:-}"; exit ;;
      *) echo "usage: $0 [--self-test [--build]]" >&2; exit 2 ;;
    esac ;;
  "") ;;
  *) echo "usage: $0 [--self-test [--build]]" >&2; exit 2 ;;
esac

#
# Detect the repository
#

origin=$(git remote get-url origin 2> /dev/null || true)
if [ -z "$origin" ]; then
  echo "error: no git remote named 'origin'. Clone your generated repository first." >&2
  exit 1
fi
owner_repo=$(printf '%s' "$origin" | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##')
repo=${owner_repo##*/}

if ! command -v gh > /dev/null; then
  echo "error: the GitHub CLI (gh) is required (https://cli.github.com) and must be authenticated (gh auth login)." >&2
  exit 1
fi
default_branch=$(gh api "repos/$owner_repo" --jq .default_branch)

step "Setting up $owner_repo (default branch: $default_branch)"

#
# 1. Rename the app after the repository
#

if [ "$owner_repo" = "$TEMPLATE_OWNER_REPO" ]; then
  warn "this is the template itself; skipping the rename"
else
  step "Renaming the app to \"$repo\""
  rename_files "$owner_repo"
  if git diff --quiet; then
    done_ "already renamed"
  else
    git add "${NAME_FILES[@]}" "${REPO_FILES[@]}" NOTICE
    git commit -q -m "Rename app after repository ($repo) via scripts/setup.sh"
    if git push -q origin "HEAD:$default_branch" 2> /dev/null; then
      done_ "renamed and pushed to $default_branch"
    else
      warn "push to $default_branch was rejected (branch protection already on?); open a PR with the local commit"
    fi
  fi
fi

#
# 2. Repository settings
#
# allow_update_branch: branch protection below is strict, so a pull request
# must be up to date with the default branch to merge. Without the Update
# branch button a Dependabot pull request that falls behind can never
# become mergeable, and its armed auto-merge waits forever.
# allow_auto_merge: the dependabot-automerge workflow arms auto-merge, which
# GitHub refuses on a repository where it is off.
#

step "Enabling repository settings"
gh api -X PATCH "repos/$owner_repo" \
  -f 'security_and_analysis[secret_scanning][status]=enabled' \
  -f 'security_and_analysis[secret_scanning_push_protection][status]=enabled' \
  -f 'security_and_analysis[dependabot_security_updates][status]=enabled' \
  -F allow_update_branch=true -F allow_auto_merge=true > /dev/null
done_ "secret scanning, push protection, Dependabot security updates, auto-merge, Update branch"
gh api -X PUT "repos/$owner_repo/private-vulnerability-reporting" > /dev/null
done_ "private vulnerability reporting"
gh api -X PUT "repos/$owner_repo/vulnerability-alerts" > /dev/null
done_ "Dependabot alerts"
# Merged PR branches delete themselves; without this every merged PR leaves
# a dead branch behind, and the branch list turns to noise within a few
# dozen PRs.
gh api -X PATCH "repos/$owner_repo" -F delete_branch_on_merge=true > /dev/null
done_ "merged PR branches are deleted automatically"

#
# 3. Branch protection requiring every PR-gating check
#
# The contexts are the `check` lines of .github/required-checks. The check
# runs first: a list that has drifted from the workflows would either let a
# red job merge or block every merge, so it is refused here too.
#

step "Enabling branch protection on $default_branch"
./scripts/check-required-contexts.sh > /dev/null
contexts=$(./scripts/check-required-contexts.sh --json)
gh api -X PUT "repos/$owner_repo/branches/$default_branch/protection" --input - > /dev/null << JSON
{
  "required_status_checks": {
    "strict": true,
    "contexts": $contexts
  },
  "enforce_admins": true,
  "required_pull_request_reviews": null,
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false
}
JSON
done_ "every check in .github/required-checks required, strict, enforced for admins"

#
# 4. Commit signing: verified commits, out of the box
#
# setup-signing.sh creates a signing key if this machine has none, configures
# this repository to sign, and registers the key with GitHub. Only when all
# of that succeeds does the branch start REQUIRING signatures: a repository
# that demands signatures from someone whose machine cannot produce them yet
# would lock its own adopter out on day one.
#

step "Setting up commit signing"
if ./scripts/setup-signing.sh; then
  gh api -X POST "repos/$owner_repo/branches/$default_branch/protection/required_signatures" > /dev/null
  done_ "commits sign automatically, and $default_branch requires Verified commits"
else
  warn "signing not configured; $default_branch does NOT require signatures."
  warn "enable later: ./scripts/setup-signing.sh && gh api -X POST repos/$owner_repo/branches/$default_branch/protection/required_signatures"
fi

#
# Let workflows open pull requests. The monthly dotnet-major-upgrade
# workflow proposes framework bumps as PRs; without this repository
# setting its create-pull-request step fails. Default token permissions
# stay read-only: workflows that need more grant it per job.
#

step "Allowing workflows to open pull requests"
gh api -X PUT "repos/$owner_repo/actions/permissions/workflow" \
  -f default_workflow_permissions=read \
  -F can_approve_pull_request_reviews=true > /dev/null
done_ "workflows may open PRs (dotnet-major-upgrade); default token stays read-only"

printf '\n%sSetup complete.%s Every future change now goes through a PR gated on the\nverification suite and CodeQL. Start developing with: make dev\n' "$BOLD" "$RESET"
