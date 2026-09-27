#!/usr/bin/env bash
#
# check-dotnet-major.sh — detect a newer GA .NET major and rewrite every
# version site that must move in lockstep with it:
#
#   1. <TargetFramework> in every .csproj and .props file that declares one
#   2. the dotnet/sdk and dotnet/aspnet base images in every Dockerfile that
#      uses them (tag and digest together, preserving the supply-chain
#      pinning)
#   3. every PackageVersion in a Directory.Packages.props whose version
#      carries the framework's major: Microsoft.AspNetCore.*,
#      Microsoft.Extensions.*, Microsoft.EntityFrameworkCore.*, the Npgsql
#      providers, whatever the project uses
#
# The sites are found by what they contain, not by a path or a package list,
# so one byte-identical file serves the template and every repository
# ported from it. A hand list of package prefixes once missed
# Microsoft.Extensions.ApiDescription.Server, which versions with the
# framework and would have stayed a major behind.
#
# Dependabot keeps everything current within a major but never crosses one,
# because the TargetFramework gates it; this script makes the cross-major
# jump. Run weekly by .github/workflows/dotnet-major-upgrade.yml, and safe
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
# The newest GA major is taken, LTS or STS: the releases index marks each
# channel's support phase, and active or maintenance is GA. A preview or a
# go-live release candidate is never taken by this script.
# scripts/check-newest-majors.sh fails when the repository is 45 days behind
# it.
#
# A repository may run ahead of GA on purpose: a release candidate taken by
# hand once the full gate suite was green on it. Then the script never moves
# it back. While its major is not GA it changes nothing and says so. Once
# that major is GA it promotes the prerelease pins to GA: every PackageVersion
# on the framework's major with a prerelease label (11.0.0-rc.1.x) moves to
# the newest stable release of that major, and every .NET image tag on that
# channel carrying a prerelease marker (11.0-preview-resolute,
# 11.0.100-rc.1-resolute) moves to the channel tag (11.0-resolute) with a
# fresh digest. A package with no stable release yet is listed and left, and
# the next run picks it up.
#
# --self-test is the upgrade, rehearsed. Every site above is copied into a
# temp tree with this script beside it, and two packages are planted in each
# Directory.Packages.props: one versioned with the framework and one not.
# curl and docker are replaced on PATH by stubs that answer from fixtures (a
# releases index with an STS major two ahead and a newer preview, a
# registry that knows the new tags, a NuGet feed with a preview and a stable
# release of the new major). The copy is run and every lockstep site must
# have moved to the STS major, exactly, with the other package untouched.
# Run again with a registry whose runtime-image suffix changed it must find
# the new tag, and with an index it cannot read it must fail saying so.
#
# The prerelease path has four more. A prerelease package and a preview sdk
# tag are planted on the current major. With an index whose newest GA major is
# one behind, nothing moves. With an index that has the current major GA, the
# prerelease pins move to GA and nothing else does, and a second run on that
# result changes nothing. With a registry that lacks the GA tag it fails before
# editing a file. Last, a copy of this script with the package promotion cut
# out is run on the same tree, and the check must catch it. Runs unattended,
# so this is the only time anyone watches it work: CI runs it on every pull
# request.

set -euo pipefail
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
cd "$(dirname "$0")/.."

RELEASES_INDEX_URL="https://raw.githubusercontent.com/dotnet/core/main/release-notes/releases-index.json"
SUMMARY_FILE="${SUMMARY_FILE:-/dev/null}"

note() { echo "$*"; }

# source_files <find name tests>: files under the current directory, with
# git metadata, dependencies and build output left out. Paths carry no
# leading ./ and are sorted.
source_files() {
  find . \( -name .git -o -name node_modules -o -name bin -o -name obj \) -prune \
    -o -type f \( "$@" \) -print | sed 's|^\./||' | sort
}
# framework_files: every .csproj and .props that declares a TargetFramework.
framework_files() {
  local f
  for f in $(source_files -name '*.csproj' -o -name '*.props'); do
    if grep -q '<TargetFramework>net' "$f"; then echo "$f"; fi
  done
}
# image_files: every Dockerfile that builds on a .NET sdk or aspnet image.
image_files() {
  local f
  for f in $(source_files -name Dockerfile -o -name '*.Dockerfile'); do
    if grep -Eq '^FROM mcr\.microsoft\.com/dotnet/(sdk|aspnet):' "$f"; then echo "$f"; fi
  done
}
# package_files: every central package-version file.
package_files() { source_files -name Directory.Packages.props; }
# current_framework: the one TargetFramework version the projects share.
current_framework() {
  local files versions
  files="$(framework_files)"
  [ -n "$files" ] || { echo "error: no .csproj or .props file declares a TargetFramework" >&2; return 1; }
  # shellcheck disable=SC2086 # one path per word
  versions="$(sed -n 's/.*<TargetFramework>net\([0-9][0-9.]*\)<.*/\1/p' $files | sort -u)"
  if [ "$(printf '%s\n' "$versions" | grep -c .)" -ne 1 ]; then
    echo "error: the projects do not agree on one TargetFramework: $(printf '%s' "$versions" | tr '\n' ' ')" >&2
    return 1
  fi
  printf '%s\n' "$versions"
}
# aspnet_suffix: the OS suffix of the aspnet image tag (10.0-resolute-chiseled
# gives resolute-chiseled), from the first Dockerfile that names one. A
# preview marker is not part of it (11.0-preview-resolute-chiseled gives
# resolute-chiseled too).
aspnet_suffix() {
  local f
  for f in $(image_files); do
    sed -n 's|^FROM mcr\.microsoft\.com/dotnet/aspnet:[0-9.]*-\([a-z-]*\)@.*|\1|p' "$f"
  done | head -1 | sed 's/^preview-//'
}
# sdk_suffix: the OS suffix of the sdk image tag (10.0-resolute gives
# resolute), empty when the sdk tag is the bare channel version.
sdk_suffix() {
  local f
  for f in $(image_files); do
    sed -n 's|^FROM mcr\.microsoft\.com/dotnet/sdk:[0-9.]*-\([a-z-]*\)@.*|\1|p' "$f"
  done | head -1 | sed 's/^preview$//; s/^preview-//'
}

self_test() {
  local dir current major prev next sts suffix sdk_tag_suffix sdk_digest aspnet_digest ga_digest failed=0 sites f
  dir="$(mktemp -d)"
  # shellcheck disable=SC2064 # expand now: the directory name is fixed
  trap "rm -rf '$dir'" EXIT

  current="$(current_framework)" || { echo "self-test FAILED: could not read the TargetFramework" >&2; return 1; }
  suffix="$(aspnet_suffix)"
  sdk_tag_suffix="$(sdk_suffix)"
  sdk_tag_suffix="${sdk_tag_suffix:+-$sdk_tag_suffix}"
  sites="$(framework_files; image_files; package_files)"
  if [ -z "$suffix" ] || [ -z "$(package_files)" ]; then
    echo "self-test FAILED: found no aspnet image with an OS suffix, or no Directory.Packages.props" >&2
    return 1
  fi
  major="${current%%.*}"
  prev="$((major - 1)).0"
  next="$((major + 2)).0"
  sts="$((major + 1)).0"
  sdk_digest="sha256:$(printf '%064d' 0 | tr 0 a)"
  aspnet_digest="sha256:$(printf '%064d' 0 | tr 0 b)"
  ga_digest="sha256:$(printf '%064d' 0 | tr 0 c)"

  # The planted tree: every real site, three planted packages in each package
  # file (one on the framework's major, one on a prerelease of it, one with
  # its own versioning), and this script. Each scenario runs on its own copy
  # of it.
  mkdir -p "$dir/planted/scripts"
  for f in $sites; do
    mkdir -p "$dir/planted/$(dirname "$f")"
    cp "$f" "$dir/planted/$f"
  done
  for f in $(package_files); do
    perl -0pi -e "s|(\\n\\s*</ItemGroup>)|\\n    <PackageVersion Include=\"Planted.Tracks.Framework\" Version=\"$major.0.4\" />\\n    <PackageVersion Include=\"Planted.Prerelease\" Version=\"$major.0.0-rc.1.1\" />\n    <PackageVersion Include=\"Planted.Own.Versioning\" Version=\"3.2.1\" />\$1|" "$dir/planted/$f"
  done
  cp "$SELF" "$dir/planted/scripts/check-dotnet-major.sh"
  local tree
  for tree in upgrade resuffixed ahead promote nogatag mutant unreadable; do cp -R "$dir/planted" "$dir/$tree"; done
  # The prerelease trees also carry a preview sdk tag on the current channel.
  for tree in ahead promote nogatag mutant; do
    for f in $(cd "$dir/planted" && image_files); do
      perl -pi -e "s|dotnet/sdk:\\Q$current\\E(-[a-z-]+)?\\@|dotnet/sdk:$current-preview\\1\\@|" "$dir/$tree/$f"
    done
  done
  # The mutant runs a copy of this script with the package promotion cut
  # out. The check below must catch it, or it proves nothing.
  perl -ni -e 'print unless /# self-test: the mutant drops this line$/' "$dir/mutant/scripts/check-dotnet-major.sh"
  if cmp -s "$SELF" "$dir/mutant/scripts/check-dotnet-major.sh"; then
    echo "self-test FAILED: the mutant is identical to the script; the marked line is gone" >&2
    return 1
  fi

  # Fixtures the stubs answer from.
  mkdir -p "$dir/fixture" "$dir/bin"
  # The newest GA channel is an STS major two ahead, past an LTS one in
  # maintenance: the STS one must be taken. A preview and a go-live release
  # candidate further out are skipped.
  printf '{"releases-index":[{"channel-version":"%s","release-type":"lts","support-phase":"preview"},{"channel-version":"%s","release-type":"sts","support-phase":"go-live"},{"channel-version":"%s","release-type":"sts","support-phase":"active"},{"channel-version":"%s","release-type":"lts","support-phase":"maintenance"}]}\n' \
    "$((major + 4)).0" "$((major + 3)).0" "$next" "$sts" > "$dir/fixture/index-next.json"
  printf '{"releases-index":[{"channel-version":"%s","release-type":"sts","support-phase":"go-live"},{"channel-version":"%s","release-type":"lts","support-phase":"active"}]}\n' \
    "$sts" "$current" > "$dir/fixture/index-current.json"
  # The current major is a go-live release candidate and the newest GA major
  # is the one before it: a repository ahead of GA on purpose.
  printf '{"releases-index":[{"channel-version":"%s","release-type":"sts","support-phase":"go-live"},{"channel-version":"%s","release-type":"lts","support-phase":"active"}]}\n' \
    "$current" "$prev" > "$dir/fixture/index-ahead.json"
  printf '{"releases-index":[{"channel-version":"%s","release-type":"sts","support-phase":"preview"}]}\n' "$sts" > "$dir/fixture/index-empty.json"
  # For the new major, a preview that must be skipped and a stable one that
  # must be taken. For the current one, a release candidate and two stable
  # releases, the newer of which a promotion must take.
  printf '{"versions":["%s.0.0-rc.1.1","%s.0","%s.0.2","%s.0-preview.1","%s.3"]}\n' "$major" "$current" "$major" "$next" "$next" > "$dir/fixture/nuget.json"

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
  mcr.microsoft.com/dotnet/sdk:$next$sdk_tag_suffix) echo "$sdk_digest" ;;
  mcr.microsoft.com/dotnet/aspnet:\$STUB_ASPNET_TAG) echo "$aspnet_digest" ;;
  mcr.microsoft.com/dotnet/sdk:$current$sdk_tag_suffix) [ -z "\$STUB_NO_GA_TAG" ] || exit 1; echo "$ga_digest" ;;
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
    local tree="$dir/$1" tag="$2" f
    for f in $(cd "$dir/planted" && framework_files); do
      grep -q "<TargetFramework>net$next<" "$tree/$f" || return 1
      ! grep -q "<TargetFramework>net$current<" "$tree/$f" || return 1
    done
    for f in $(cd "$dir/planted" && image_files); do
      ! grep -Eq "dotnet/(sdk|aspnet):${current}[-@]" "$tree/$f" || return 1
      ! grep -E '^FROM mcr\.microsoft\.com/dotnet/sdk:' "$tree/$f" | grep -vq "^FROM mcr.microsoft.com/dotnet/sdk:$next$sdk_tag_suffix@$sdk_digest " || return 1
      ! grep -E '^FROM mcr\.microsoft\.com/dotnet/aspnet:' "$tree/$f" | grep -vq "^FROM mcr.microsoft.com/dotnet/aspnet:$tag@$aspnet_digest " || return 1
    done
    grep -rq "^FROM mcr.microsoft.com/dotnet/sdk:$next$sdk_tag_suffix@$sdk_digest " "$tree" || return 1
    grep -rq "^FROM mcr.microsoft.com/dotnet/aspnet:$tag@$aspnet_digest " "$tree" || return 1
    for f in $(cd "$dir/planted" && package_files); do
      # Every package on the old major is on the new one, the planted one
      # included, and every other line is untouched.
      grep -q "Include=\"Planted.Tracks.Framework\" Version=\"$next.3\"" "$tree/$f" || return 1
      grep -q "Include=\"Planted.Own.Versioning\" Version=\"3.2.1\"" "$tree/$f" || return 1
      [ "$(grep -c "PackageVersion Include=\"[^\"]*\" Version=\"$major\\." "$dir/planted/$f")" \
        = "$(grep -c "PackageVersion Include=\"[^\"]*\" Version=\"$next.3\"" "$tree/$f")" ] || return 1
      [ "$(grep -v "Version=\"$major\\." "$dir/planted/$f")" = "$(grep -v "Version=\"$next.3\"" "$tree/$f")" ] || return 1
    done
    grep -q "^new-version=$next$" "$tree.output" || return 1
    grep -q "net$current\*\* to \*\*net$next" "$tree.summary.md"
  }
  # shellcheck disable=SC2329  # invoked through check()
  promoted() { # promoted <tree>: the prerelease pins, and nothing else, are on GA
    local tree="$dir/$1" f pre
    for f in $(cd "$dir/planted" && framework_files); do
      cmp -s "$dir/planted/$f" "$tree/$f" || return 1
    done
    for f in $(cd "$dir/planted" && image_files); do
      ! grep -Eq "dotnet/(sdk|aspnet):[^ @]*-(preview|rc)" "$tree/$f" || return 1
      [ "$(grep -E '^FROM mcr\.microsoft\.com/dotnet/aspnet:' "$dir/planted/$f")" \
        = "$(grep -E '^FROM mcr\.microsoft\.com/dotnet/aspnet:' "$tree/$f")" ] || return 1
    done
    grep -rq "^FROM mcr.microsoft.com/dotnet/sdk:$current$sdk_tag_suffix@$ga_digest " "$tree" || return 1
    for f in $(cd "$dir/planted" && package_files); do
      ! grep -q "Version=\"$major\.[^\"]*-" "$tree/$f" || return 1
      grep -q "Include=\"Planted.Prerelease\" Version=\"$major.0.2\"" "$tree/$f" || return 1
      grep -q "Include=\"Planted.Tracks.Framework\" Version=\"$major.0.4\"" "$tree/$f" || return 1
      grep -q "Include=\"Planted.Own.Versioning\" Version=\"3.2.1\"" "$tree/$f" || return 1
      pre="Version=\"$major\.[^\"]*-"
      [ "$(grep -c "$pre" "$dir/planted/$f")" = "$(grep -c "Version=\"$major.0.2\"" "$tree/$f")" ] || return 1
      [ "$(grep -v "$pre" "$dir/planted/$f")" = "$(grep -v "Version=\"$major.0.2\"" "$tree/$f")" ] || return 1
    done
    grep -q "^new-version=$current$" "$tree.output" || return 1
    grep -q "net$current\*\* from its prerelease pins to GA" "$tree.summary.md"
  }
  # shellcheck disable=SC2329  # invoked through check()
  unchanged() { # unchanged <tree> [<before>]: every site is byte-identical to the planted tree, or to <before>
    diff -r "${2:-$dir/planted}" "$dir/$1" > /dev/null
  }

  run upgrade index-next.json "$next-$suffix"
  check "the STS major ahead of net$current is taken past an LTS one (exit $code)" [ "$code" -eq 0 ]
  check "every lockstep site moved to net$next: each TargetFramework, every image tag with its digest, every package on the framework's major (stable only, Microsoft.Extensions included), the output and the summary, and a package with its own versioning untouched" \
    moved_everything upgrade "$next-$suffix"

  run resuffixed index-next.json "$next-plucky-chiseled"
  check "a runtime image whose OS suffix changed is found from the registry's tag list (exit $code)" [ "$code" -eq 0 ]
  check "the new suffix is what lands in the Dockerfile, and it is called out" \
    moved_everything resuffixed "$next-plucky-chiseled"
  check "the summary says the suffix changed" grep -q "aspnet suffix changed: using $next-plucky-chiseled" <<< "$out"

  cp -R "$dir/ahead" "$dir/prerelease"
  run ahead index-ahead.json "$next-$suffix"
  check "a repository on a release candidate ahead of the newest GA major (net$prev) is not moved back (exit $code)" [ "$code" -eq 0 ]
  check "it says so" grep -q "net$current is ahead of the newest GA major" <<< "$out"
  check "and every site is untouched" unchanged ahead "$dir/prerelease"

  run promote index-current.json "$next-$suffix"
  check "once net$current is GA its prerelease pins are promoted, while a newer major that is only a release candidate is skipped (exit $code)" [ "$code" -eq 0 ]
  check "every prerelease package on the major and the preview sdk tag moved to GA, and nothing else did: the TargetFramework, a stable package on the major, a package with its own versioning, the aspnet image" \
    promoted promote
  cp -R "$dir/promote" "$dir/promote.before"
  run promote index-current.json "$next-$suffix"
  check "a second run on the promoted tree (exit $code)" [ "$code" -eq 0 ]
  check "says the major is GA with nothing to promote" grep -q "net$current is the latest GA major" <<< "$out"
  check "and changes nothing" unchanged promote "$dir/promote.before"

  STUB_NO_GA_TAG=1 run nogatag index-current.json "$next-$suffix"
  check "a registry without the GA image tag fails the promotion (exit $code)" [ "$code" -ne 0 ]
  check "it says which tag" grep -q "no GA image mcr.microsoft.com/dotnet/sdk:$current$sdk_tag_suffix" <<< "$out"
  check "and every site is untouched" unchanged nogatag "$dir/prerelease"

  run mutant index-current.json "$next-$suffix"
  check "a copy of the script with the package promotion cut out still exits 0 (exit $code)" [ "$code" -eq 0 ]
  check "and the promotion check catches it: a planted failure, so the check above is proven to fail" \
    eval '! promoted mutant'

  run unreadable index-empty.json "$next-$suffix"
  check "an index with no GA release fails rather than upgrading to nothing (exit $code)" [ "$code" -ne 0 ]
  check "it says why" grep -q "could not determine the latest GA .NET version" <<< "$out"
  check "and every site is untouched" unchanged unreadable

  if [ "$failed" -eq 0 ]; then
    echo "self-test: a planted stale major was upgraded to the next GA major (an STS one) at every lockstep site, a changed image suffix was found, a release candidate ahead of GA was left alone and promoted once GA, a missing GA tag failed, a mutant was caught, an index with no GA release failed"
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

current="$(current_framework)"

latest="$(curl -fsSL "$RELEASES_INDEX_URL" | jq -r '
  ."releases-index"
  | map(select(."support-phase" == "active" or ."support-phase" == "maintenance"))
  | max_by(."channel-version" | split(".") | map(tonumber))
  | ."channel-version"')"
[ -n "$latest" ] && [ "$latest" != "null" ] || { echo "error: could not determine the latest GA .NET version" >&2; exit 1; }

cur_major="${current%%.*}"
new_major="${latest%%.*}"

if [ "$new_major" -lt "$cur_major" ]; then
  note "net${current} is ahead of the newest GA major (index says ${latest}): a prerelease taken on purpose. Nothing moves until ${cur_major}.0 is GA."
  echo "net${current} is ahead of the newest GA .NET major (${latest}). Nothing to do until it is GA." > "$SUMMARY_FILE"
  exit 0
fi

projects="$(framework_files)"
images="$(image_files)"
packages="$(package_files)"

digest_of() { docker buildx imagetools inspect "$1" --format '{{.Manifest.Digest}}'; }
bullets() { local f; for f in "$@"; do echo "- \`$f\`"; done; }

# promote: the current major is GA. Move its prerelease pins to GA: each
# package on the major with a prerelease label to the major's newest stable
# release, each image tag on the channel with a prerelease marker to the
# channel tag. Every image is resolved before any file is edited, so a GA tag
# the registry does not have yet fails with the tree untouched.
promote() {
  local f ref tag new_tag digest moves="" pkg lower new_ver bumped="" pending="" old new
  for ref in $(for f in $images; do
      grep -ohE "mcr\.microsoft\.com/dotnet/(sdk|aspnet):${current//./\\.}[^@ ]*@sha256:[0-9a-f]+" "$f"
    done | sort -u); do
    tag="${ref%@*}"
    [[ "$tag" =~ -(preview|rc) ]] || continue
    new_tag="$(printf '%s' "$tag" | perl -pe "s/:\Q${current}\E(?:\.\d+)*-(?:preview|rc)(?:\.\d+)*(?=-|\$)/:${current}/")"
    digest="$(digest_of "$new_tag")" || { echo "error: no GA image $new_tag in the registry yet; nothing was changed" >&2; exit 1; }
    moves="${moves}${ref} ${new_tag}@${digest}"$'\n'
  done

  # shellcheck disable=SC2086 # one path per word
  while read -r pkg; do
    [ -n "$pkg" ] || continue
    lower="$(echo "$pkg" | tr '[:upper:]' '[:lower:]')"
    new_ver="$(curl -fsSL "https://api.nuget.org/v3-flatcontainer/${lower}/index.json" \
      | jq -r --arg m "${cur_major}." '.versions | map(select(startswith($m) and (contains("-") | not))) | last // empty')"
    if [ -n "$new_ver" ]; then
      for f in $packages; do replace "$f" "s|(Include=\"\Q${pkg}\E\" Version=\")\Q${cur_major}\E\.[^\"]*-[^\"]*|\${1}${new_ver}|"; done # self-test: the mutant drops this line
      bumped="${bumped}- \`${pkg}\` → ${new_ver}\n"
    else
      pending="${pending}- \`${pkg}\` has no stable ${cur_major}.x release yet\n"
    fi
  done < <(sed -n "s/.*PackageVersion Include=\"\([^\"]*\)\" Version=\"${cur_major}\.[^\"]*-.*/\1/p" $packages | sort -u)

  while read -r old new; do
    [ -n "$old" ] || continue
    # Through the environment: perl would read @sha256 in the program text as
    # an array.
    for f in $images; do OLD="$old" NEW="$new" perl -pi -e 's/\Q$ENV{OLD}\E/$ENV{NEW}/g' "$f"; done
  done <<< "$moves"

  if [ -z "$moves" ] && [ -z "$bumped" ]; then
    note "net${current} is the latest GA major (index says ${latest}); nothing to do."
    {
      echo "Already on the latest GA .NET major (net${current}), with no prerelease pin that has a GA release."
      [ -z "$pending" ] || printf '\n%b' "$pending"
    } > "$SUMMARY_FILE"
    [ -z "$pending" ] || printf '%b' "$pending"
    return 0
  fi

  note ".NET ${current} is GA; moving its prerelease pins to GA."
  {
    echo "Moves **net${current}** from its prerelease pins to GA. The releases index lists .NET ${current} as GA."
    if [ -n "$bumped" ]; then
      echo
      echo "Packages:"
      echo
      printf '%b' "$bumped"
    fi
    if [ -n "$moves" ]; then
      echo
      echo "Images, digest-pinned:"
      echo
      while read -r old new; do
        [ -z "$old" ] || echo "- \`${old%@*}\` → \`${new%@*}\`"
      done <<< "$moves"
    fi
    locks="$(source_files -name packages.lock.json)"
    if [ -n "$locks" ]; then
      echo
      echo "Regenerate the lock files on this branch before it can build. Run \`dotnet restore --force-evaluate\` in the SDK image for each project below, then commit every lock file that moved:"
      echo
      # shellcheck disable=SC2046 # one path per word
      bullets $(for f in $locks; do dirname "$f"; done)
    fi
    if [ -n "$pending" ]; then
      echo
      echo "Left for the next run, once these ship:"
      echo
      printf '%b' "$pending"
    fi
    echo
    echo "Opened by \`dotnet-major-upgrade.yml\`. CI does not run on a pull request opened with the workflow token. Close and reopen this one, or push an empty commit, to run the checks."
  } > "$SUMMARY_FILE"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "new-version=${current}" >> "$GITHUB_OUTPUT"
    echo "title=Move .NET ${current} from prerelease to GA" >> "$GITHUB_OUTPUT"
  fi
  note "done: net${current} prerelease pins -> GA"
}

if [ "$new_major" -eq "$cur_major" ]; then
  promote
  exit 0
fi

note ".NET ${latest} is GA; currently on net${current}. Rewriting the lockstep sites."

# The sdk tag is the channel version with the OS suffix the Dockerfile
# already uses, if any (10.0-resolute). The aspnet tag carries an OS
# suffix (e.g. 10.0-resolute-chiseled) that can change between majors, so
# discover the new major's chiseled tag from the registry rather than
# assuming the suffix survives.
sdk_tag="${latest}$(sdk_suffix | sed 's/^./-&/')"
sdk_digest="$(digest_of "mcr.microsoft.com/dotnet/sdk:${sdk_tag}")"

aspnet_tag="${latest}-$(aspnet_suffix)"
if ! docker buildx imagetools inspect "mcr.microsoft.com/dotnet/aspnet:${aspnet_tag}" >/dev/null 2>&1; then
  aspnet_tag="$(curl -fsSL https://mcr.microsoft.com/v2/dotnet/aspnet/tags/list \
    | jq -r '.tags[]' | grep -E "^${latest}-[a-z]+-chiseled$" | sort | head -1)"
  [ -n "$aspnet_tag" ] || { echo "error: no ${latest} chiseled aspnet tag found; the tag layout changed" >&2; exit 1; }
  note "aspnet suffix changed: using ${aspnet_tag}"
fi
aspnet_digest="$(digest_of "mcr.microsoft.com/dotnet/aspnet:${aspnet_tag}")"

for f in $projects; do
  replace "$f" "s|<TargetFramework>net\Q${current}\E<|<TargetFramework>net${latest}<|"
done
for f in $images; do
  replace "$f" "s|dotnet/sdk:\Q${current}\E(-[a-z-]+)?\@sha256:[0-9a-f]+|dotnet/sdk:${sdk_tag}\@${sdk_digest}|g"
  replace "$f" "s|dotnet/aspnet:\Q${current}\E-[a-z-]+\@sha256:[0-9a-f]+|dotnet/aspnet:${aspnet_tag}\@${aspnet_digest}|g"
  if grep -Eq "dotnet/(sdk|aspnet):${current//./\\.}([-@ ]|$)" "$f"; then
    echo "error: $f still names a .NET ${current} image that is not in tag@digest form; move it by hand" >&2
    exit 1
  fi
done

# Framework-tracking packages: every PackageVersion on the framework's major
# moves to the latest stable release of the new major. Anything without one
# yet is left alone and called out in the summary.
pending=""
bumped=""
# shellcheck disable=SC2086 # one path per word
while read -r pkg; do
  [ -n "$pkg" ] || continue
  lower="$(echo "$pkg" | tr '[:upper:]' '[:lower:]')"
  new_ver="$(curl -fsSL "https://api.nuget.org/v3-flatcontainer/${lower}/index.json" \
    | jq -r --arg m "${new_major}." '.versions | map(select(startswith($m) and (contains("-") | not))) | last // empty')"
  if [ -n "$new_ver" ]; then
    for f in $packages; do
      replace "$f" "s|(Include=\"\Q${pkg}\E\" Version=\")\Q${cur_major}\E\.[^\"]+|\${1}${new_ver}|"
    done
    bumped="${bumped}- \`${pkg}\` → ${new_ver}\n"
  else
    pending="${pending}- \`${pkg}\` has no stable ${new_major}.x release yet\n"
  fi
done < <(sed -n "s/.*PackageVersion Include=\"\([^\"]*\)\" Version=\"${cur_major}\..*/\1/p" $packages | sort -u)

locks="$(source_files -name packages.lock.json)"

{
  echo "Moves the repo from **net${current}** to **net${latest}**, the latest GA .NET major."
  echo
  echo "Every lockstep site moves together."
  echo
  echo "TargetFramework:"
  echo
  # shellcheck disable=SC2086 # one path per word
  bullets $projects
  echo
  echo "\`dotnet/sdk:${sdk_tag}\` and \`dotnet/aspnet:${aspnet_tag}\`, digest-pinned:"
  echo
  # shellcheck disable=SC2086
  bullets $images
  echo
  echo "Packages versioned with the framework:"
  echo
  printf '%b' "$bumped"
  if [ -n "$locks" ]; then
    echo
    echo "Regenerate the lock files on this branch before it can build. Run \`dotnet restore --force-evaluate\` in the new SDK image for each project below, then commit every lock file that moved:"
    echo
    # shellcheck disable=SC2046 # one path per word
    bullets $(for f in $locks; do dirname "$f"; done)
  fi
  if [ -n "$pending" ]; then
    echo
    echo "Left for a human. Re-run the workflow once these ship. A package whose version shares the framework's major by coincidence can stay where it is:"
    echo
    printf '%b' "$pending"
  fi
  echo
  echo "Review the [breaking changes for .NET ${new_major}](https://learn.microsoft.com/dotnet/core/compatibility/${latest}) before merging."
  echo
  echo "Opened by \`dotnet-major-upgrade.yml\`. CI does not run on a pull request opened with the workflow token. Close and reopen this one, or push an empty commit, to run the checks."
} > "$SUMMARY_FILE"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "new-version=${latest}" >> "$GITHUB_OUTPUT"
  echo "title=Upgrade to .NET ${latest}" >> "$GITHUB_OUTPUT"
fi

note "done: net${current} -> net${latest}"
