#!/usr/bin/env bash
#
# setup.sh — one-command setup for a repository generated from this template:
#
#   ./scripts/setup.sh
#
# What it does:
#   1. renames the app after your repository (page title, heading, e2e
#      expectation, README badge and links) and pushes the change
#   2. enables the GitHub security settings templates cannot carry over:
#      secret scanning, push protection, private vulnerability reporting,
#      Dependabot alerts and security updates
#   3. enables branch protection on the default branch requiring the CI
#      (`verify`) and CodeQL checks
#
# Requirements: git, and the GitHub CLI (`gh`, https://cli.github.com)
# authenticated as an admin of the repository. Safe to re-run: every step is
# idempotent.

set -euo pipefail

cd "$(dirname "$0")/.."

TEMPLATE_NAME="Modern Web App"
TEMPLATE_OWNER_REPO="neb-abera/modern-webapp-template"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
  GREEN=""; YELLOW=""; BOLD=""; RESET=""
fi
step() { printf '%s==>%s %s\n' "$BOLD" "$RESET" "$1"; }
done_() { printf '%s  done:%s %s\n' "$GREEN" "$RESET" "$1"; }
warn() { printf '%s  note:%s %s\n' "$YELLOW" "$RESET" "$1"; }

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
  echo "error: the GitHub CLI (gh) is required — https://cli.github.com — and must be authenticated (gh auth login)." >&2
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
  NEW_NAME="$repo" perl -pi -e 's/\QModern Web App\E/$ENV{NEW_NAME}/g' \
    client/index.html client/src/App.tsx e2e/smoke.spec.ts README.md
  NEW_REPO="$owner_repo" perl -pi -e 's#\Qneb-abera/modern-webapp-template\E#$ENV{NEW_REPO}#g' \
    README.md
  if git diff --quiet; then
    done_ "already renamed"
  else
    git add client/index.html client/src/App.tsx e2e/smoke.spec.ts README.md
    git commit -q -m "Rename app after repository ($repo) via scripts/setup.sh"
    if git push -q origin "HEAD:$default_branch" 2> /dev/null; then
      done_ "renamed and pushed to $default_branch"
    else
      warn "push to $default_branch was rejected (branch protection already on?); open a PR with the local commit"
    fi
  fi
fi

#
# 2. Repo security settings
#

step "Enabling security settings"
gh api -X PATCH "repos/$owner_repo" \
  -f 'security_and_analysis[secret_scanning][status]=enabled' \
  -f 'security_and_analysis[secret_scanning_push_protection][status]=enabled' \
  -f 'security_and_analysis[dependabot_security_updates][status]=enabled' > /dev/null
done_ "secret scanning, push protection, Dependabot security updates"
gh api -X PUT "repos/$owner_repo/private-vulnerability-reporting" > /dev/null
done_ "private vulnerability reporting"
gh api -X PUT "repos/$owner_repo/vulnerability-alerts" > /dev/null
done_ "Dependabot alerts"

#
# 3. Branch protection requiring the CI and CodeQL checks
#

step "Enabling branch protection on $default_branch"
gh api -X PUT "repos/$owner_repo/branches/$default_branch/protection" --input - > /dev/null <<'JSON'
{
  "required_status_checks": {
    "strict": true,
    "contexts": ["verify", "analyze (csharp)", "analyze (javascript-typescript)", "analyze (actions)"]
  },
  "enforce_admins": true,
  "required_pull_request_reviews": null,
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false
}
JSON
done_ "verify + CodeQL checks required, strict, enforced for admins"

printf '\n%sSetup complete.%s Every future change now goes through a PR gated on the\nverification suite and CodeQL. Start developing with: make dev\n' "$BOLD" "$RESET"
