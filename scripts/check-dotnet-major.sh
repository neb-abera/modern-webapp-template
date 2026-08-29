#!/usr/bin/env bash
#
# check-dotnet-major.sh — detect a newer GA .NET major and rewrite every
# version site that must move in lockstep with it:
#
#   1. <TargetFramework> in server/Directory.Build.props
#   2. the dotnet/sdk and dotnet/aspnet base images in the Dockerfile
#      (tag and digest together, preserving the supply-chain pinning)
#   3. Microsoft.AspNetCore.* package versions in
#      server/Directory.Packages.props
#
# Dependabot keeps everything current within a major but never crosses one,
# because the TargetFramework gates it; this script makes the cross-major
# jump. Run monthly by .github/workflows/dotnet-major-upgrade.yml, and safe
# to run locally: it only edits files, never commits.
#
# Environment:
#   SUMMARY_FILE  optional path; a Markdown summary (used as the PR body)
#                 is written there.
#
# Exits 0 whether or not changes were made; non-zero only on failure.

set -euo pipefail
cd "$(dirname "$0")/.."

RELEASES_INDEX_URL="https://raw.githubusercontent.com/dotnet/core/main/release-notes/releases-index.json"
SUMMARY_FILE="${SUMMARY_FILE:-/dev/null}"

note() { echo "$*"; }

# In-place regex replace that works with both GNU and BSD sed.
replace() { # replace <file> <perl-substitution>
  perl -pi -e "$2" "$1"
}

current="$(sed -n 's/.*<TargetFramework>net\([0-9][0-9.]*\)<.*/\1/p' server/Directory.Build.props)"
[ -n "$current" ] || { echo "error: could not read TargetFramework from server/Directory.Build.props" >&2; exit 1; }

latest="$(curl -fsSL "$RELEASES_INDEX_URL" | jq -r '
  ."releases-index"
  | map(select(."support-phase" == "active" or ."support-phase" == "maintenance"))
  | max_by(."channel-version" | split(".") | map(tonumber))
  | ."channel-version"')"
[ -n "$latest" ] && [ "$latest" != "null" ] || { echo "error: could not determine latest GA .NET version" >&2; exit 1; }

cur_major="${current%%.*}"
new_major="${latest%%.*}"

if [ "$new_major" -le "$cur_major" ]; then
  note "net${current} is the latest GA major (index says ${latest}); nothing to do."
  echo "Already on the latest GA .NET major (net${current})." > "$SUMMARY_FILE"
  exit 0
fi

note "GA .NET ${latest} is out; currently on net${current}. Rewriting the lockstep sites."

digest_of() { docker buildx imagetools inspect "$1" --format '{{.Manifest.Digest}}'; }

# The sdk tag is just the channel version; the aspnet tag carries an OS
# suffix (e.g. 10.0-noble-chiseled) that can change between majors, so
# discover the new major's chiseled tag from the registry rather than
# assuming the suffix survives.
sdk_ref="mcr.microsoft.com/dotnet/sdk:${latest}"
sdk_digest="$(digest_of "$sdk_ref")"

aspnet_suffix="$(sed -n 's|^FROM mcr\.microsoft\.com/dotnet/aspnet:[0-9.]*-\([a-z-]*\)@.*|\1|p' Dockerfile | head -1)"
aspnet_tag="${latest}-${aspnet_suffix}"
if ! docker buildx imagetools inspect "mcr.microsoft.com/dotnet/aspnet:${aspnet_tag}" >/dev/null 2>&1; then
  aspnet_tag="$(curl -fsSL https://mcr.microsoft.com/v2/dotnet/aspnet/tags/list \
    | jq -r '.tags[]' | grep -E "^${latest}-[a-z]+-chiseled$" | sort | head -1)"
  [ -n "$aspnet_tag" ] || { echo "error: no ${latest} chiseled aspnet tag found; the tag layout changed" >&2; exit 1; }
  note "aspnet suffix changed: using ${aspnet_tag}"
fi
aspnet_digest="$(digest_of "mcr.microsoft.com/dotnet/aspnet:${aspnet_tag}")"

replace server/Directory.Build.props "s|<TargetFramework>net\Q${current}\E<|<TargetFramework>net${latest}<|"
replace Dockerfile "s|dotnet/sdk:\Q${current}\E\@sha256:[0-9a-f]+|dotnet/sdk:${latest}\@${sdk_digest}|g"
replace Dockerfile "s|dotnet/aspnet:\Q${current}\E-[a-z-]+\@sha256:[0-9a-f]+|dotnet/aspnet:${aspnet_tag}\@${aspnet_digest}|g"

# Framework-tracking packages: bump every Microsoft.AspNetCore.* entry to
# the latest stable release of the new major. Anything without one yet is
# left alone and called out in the summary.
pending=""
bumped=""
while read -r pkg; do
  lower="$(echo "$pkg" | tr '[:upper:]' '[:lower:]')"
  new_ver="$(curl -fsSL "https://api.nuget.org/v3-flatcontainer/${lower}/index.json" \
    | jq -r --arg m "${new_major}." '.versions | map(select(startswith($m) and (contains("-") | not))) | last // empty')"
  if [ -n "$new_ver" ]; then
    replace server/Directory.Packages.props "s|(Include=\"\Q${pkg}\E\" Version=\")[^\"]+|\${1}${new_ver}|"
    bumped="${bumped}- \`${pkg}\` → ${new_ver}\n"
  else
    pending="${pending}- \`${pkg}\` has no stable ${new_major}.x release yet\n"
  fi
done < <(sed -n 's/.*PackageVersion Include="\(Microsoft\.AspNetCore\.[^"]*\)".*/\1/p' server/Directory.Packages.props)

{
  echo "Moves the repo from **net${current}** to **net${latest}**, the latest GA .NET major."
  echo
  echo "Every lockstep site moves together:"
  echo
  echo "- \`<TargetFramework>\` in \`server/Directory.Build.props\`"
  echo "- \`dotnet/sdk:${latest}\` and \`dotnet/aspnet:${aspnet_tag}\` in the \`Dockerfile\`, digest-pinned"
  printf '%b' "$bumped"
  if [ -n "$pending" ]; then
    echo
    echo "Left for a human (re-run the workflow once these ship):"
    printf '%b' "$pending"
  fi
  echo
  echo "Review the [breaking changes for .NET ${new_major}](https://learn.microsoft.com/dotnet/core/compatibility/${latest}) before merging."
  echo
  echo "Opened by \`dotnet-major-upgrade.yml\`. CI does not run automatically on PRs opened with the workflow token — close and reopen this PR (or push an empty commit) to run the verify suite."
} > "$SUMMARY_FILE"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "new-version=${latest}" >> "$GITHUB_OUTPUT"
fi

note "done: net${current} -> net${latest}"
