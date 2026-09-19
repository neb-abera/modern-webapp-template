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
#   scripts/check-dotnet-major.sh              run the check
#   scripts/check-dotnet-major.sh --self-test  prove it does the job
#
# Environment:
#   SUMMARY_FILE  optional path; a Markdown summary (used as the PR body)
#                 is written there.
#
# Exits 0 whether or not changes were made; non-zero only on failure.
#
# --self-test is the upgrade, rehearsed. The three files above are copied
# into a temp tree with this script beside them; curl and docker are
# replaced on PATH by stubs that answer from fixtures (a releases index one
# major ahead, a registry that knows the new tags, a NuGet feed with a
# preview and a stable release of the new major); the copy is run and every
# lockstep site must have moved, exactly. Run again with an index naming the
# current major it must change nothing, with a registry whose runtime-image
# suffix changed it must find the new tag, and with an index it cannot read
# it must fail saying so. Runs unattended once a month, so this is the only
# time anyone watches it work: CI runs it on every pull request.

set -euo pipefail
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
cd "$(dirname "$0")/.."

RELEASES_INDEX_URL="https://raw.githubusercontent.com/dotnet/core/main/release-notes/releases-index.json"
SUMMARY_FILE="${SUMMARY_FILE:-/dev/null}"

note() { echo "$*"; }

self_test() {
  local dir current major next suffix sdk_digest aspnet_digest failed=0
  dir="$(mktemp -d)"
  # shellcheck disable=SC2064 # expand now: the directory name is fixed
  trap "rm -rf '$dir'" EXIT

  current="$(sed -n 's/.*<TargetFramework>net\([0-9][0-9.]*\)<.*/\1/p' server/Directory.Build.props)"
  suffix="$(sed -n 's|^FROM mcr\.microsoft\.com/dotnet/aspnet:[0-9.]*-\([a-z-]*\)@.*|\1|p' Dockerfile | head -1)"
  if [ -z "$current" ] || [ -z "$suffix" ]; then
    echo "self-test FAILED: could not read the TargetFramework or the aspnet image suffix" >&2
    return 1
  fi
  major="${current%%.*}"
  next="$((major + 1)).0"
  sdk_digest="sha256:$(printf '%064d' 0 | tr 0 a)"
  aspnet_digest="sha256:$(printf '%064d' 0 | tr 0 b)"

  # One tree per scenario: the real files, this script, nothing else.
  plant() {
    mkdir -p "$dir/$1/server" "$dir/$1/scripts"
    cp server/Directory.Build.props server/Directory.Packages.props "$dir/$1/server/"
    cp Dockerfile "$dir/$1/"
    cp "$SELF" "$dir/$1/scripts/check-dotnet-major.sh"
  }
  plant upgrade
  plant resuffixed
  plant current
  plant unreadable

  # Fixtures the stubs answer from.
  mkdir -p "$dir/fixture" "$dir/bin"
  printf '{"releases-index":[{"channel-version":"%s","support-phase":"active"},{"channel-version":"%s","support-phase":"maintenance"}]}\n' \
    "$next" "$current" > "$dir/fixture/index-next.json"
  printf '{"releases-index":[{"channel-version":"%s","support-phase":"active"}]}\n' "$current" > "$dir/fixture/index-current.json"
  printf '{"releases-index":[]}\n' > "$dir/fixture/index-empty.json"
  # A preview of the new major that must be skipped and a stable one that must be taken.
  printf '{"versions":["%s.0","%s.0-preview.1","%s.3"]}\n' "$current" "$next" "$next" > "$dir/fixture/nuget.json"

  # The stubs. curl's last argument is the URL; docker is only ever asked
  # `buildx imagetools inspect <ref> [--format ...]`, where the ref is $4.
  # Which index and which runtime tag exist come from the scenario.
  cat > "$dir/bin/curl" <<STUB
#!/usr/bin/env bash
for a; do url="\$a"; done
case "\$url" in
  *releases-index.json) cat "\$STUB_RELEASES_INDEX" ;;
  *api.nuget.org/v3-flatcontainer/*/index.json) cat "$dir/fixture/nuget.json" ;;
  *mcr.microsoft.com/v2/dotnet/aspnet/tags/list) printf '{"tags":["%s-noble","%s"]}\n' "$next" "\$STUB_ASPNET_TAG" ;;
  *) echo "stub curl: unexpected URL \$url" >&2; exit 1 ;;
esac
STUB
  cat > "$dir/bin/docker" <<STUB
#!/usr/bin/env bash
case "\$4" in
  mcr.microsoft.com/dotnet/sdk:$next) echo "$sdk_digest" ;;
  mcr.microsoft.com/dotnet/aspnet:\$STUB_ASPNET_TAG) echo "$aspnet_digest" ;;
  *) echo "stub docker: no such image \$4" >&2; exit 1 ;;
esac
STUB
  chmod +x "$dir/bin/curl" "$dir/bin/docker"

  # run <tree> <index fixture> <aspnet tag the registry has>: sets code, out.
  local code out
  run() {
    code=0
    out="$(cd "$dir/$1" && PATH="$dir/bin:$PATH" STUB_RELEASES_INDEX="$dir/fixture/$2" STUB_ASPNET_TAG="$3" \
      SUMMARY_FILE="$dir/$1.summary.md" GITHUB_OUTPUT="$dir/$1.output" scripts/check-dotnet-major.sh 2>&1)" || code=$?
  }
  ok() { echo "self-test: ok: $1"; }
  flunk() { echo "self-test FAILED: $1" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; failed=1; }
  check() { if "${@:2}"; then ok "$1"; else flunk "$1"; fi; }
  # shellcheck disable=SC2329  # invoked through check()
  moved_everything() { # moved_everything <tree> <aspnet tag>: every lockstep site is on the new major
    local tree="$dir/$1" tag="$2" packages
    grep -q "<TargetFramework>net$next<" "$tree/server/Directory.Build.props" || return 1
    grep -q "^FROM mcr.microsoft.com/dotnet/sdk:$next@$sdk_digest AS server-build$" "$tree/Dockerfile" || return 1
    grep -q "^FROM mcr.microsoft.com/dotnet/aspnet:$tag@$aspnet_digest AS runtime$" "$tree/Dockerfile" || return 1
    ! grep -Eq "dotnet/(sdk|aspnet):${current}[-@]" "$tree/Dockerfile" || return 1
    packages="$(grep -c 'PackageVersion Include="Microsoft\.AspNetCore\.' "$tree/server/Directory.Packages.props")"
    [ "$(grep -c "Include=\"Microsoft\.AspNetCore\.[^\"]*\" Version=\"$next.3\"" "$tree/server/Directory.Packages.props")" = "$packages" ] || return 1
    grep -q "^new-version=$next$" "$tree.output" || return 1
    grep -q "net$current\*\* to \*\*net$next" "$tree.summary.md"
  }
  # shellcheck disable=SC2329  # invoked through check()
  unchanged() { # unchanged <tree>: the three files are byte-identical to the real ones
    cmp -s server/Directory.Build.props "$dir/$1/server/Directory.Build.props" \
      && cmp -s server/Directory.Packages.props "$dir/$1/server/Directory.Packages.props" \
      && cmp -s Dockerfile "$dir/$1/Dockerfile"
  }

  run upgrade index-next.json "$next-$suffix"
  check "a GA major ahead of net$current is taken (exit $code)" [ "$code" -eq 0 ]
  check "every lockstep site moved to net$next: TargetFramework, both image tags with their digests, the AspNetCore packages (stable only), the output and the summary" \
    moved_everything upgrade "$next-$suffix"

  run resuffixed index-next.json "$next-plucky-chiseled"
  check "a runtime image whose OS suffix changed is found from the registry's tag list (exit $code)" [ "$code" -eq 0 ]
  check "the new suffix is what lands in the Dockerfile, and it is called out" \
    moved_everything resuffixed "$next-plucky-chiseled"
  check "the summary says the suffix changed" grep -q "aspnet suffix changed: using $next-plucky-chiseled" <<< "$out"

  run current index-current.json "$next-$suffix"
  check "an index naming the current major changes nothing (exit $code)" [ "$code" -eq 0 ]
  check "it says so" grep -q "net$current is the latest GA major" <<< "$out"
  check "and the three files are untouched" unchanged current

  run unreadable index-empty.json "$next-$suffix"
  check "an index with no GA release fails rather than upgrading to nothing (exit $code)" [ "$code" -ne 0 ]
  check "it says why" grep -q "could not determine latest GA .NET version" <<< "$out"
  check "and the three files are untouched" unchanged unreadable

  if [ "$failed" -eq 0 ]; then
    echo "self-test: a planted stale major was upgraded at every lockstep site, a changed image suffix was found, a current major was left alone, an unreadable index failed"
  fi
  return "$failed"
}

if [ "${1:-}" = --self-test ]; then
  self_test
  exit $?
fi

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
