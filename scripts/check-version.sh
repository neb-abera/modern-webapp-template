#!/usr/bin/env bash
#
# check-version.sh — one version number per repository, and it is the tag.
#
#   scripts/check-version.sh              check the manifests against .versioning
#   scripts/check-version.sh --tag vX     check a release tag against them
#   scripts/check-version.sh --next       print the next date tag (date scheme)
#   scripts/check-version.sh --self-test  prove the check can fail
#
# .versioning names the scheme, and for semver the one manifest that carries
# the product's version:
#
#   scheme: semver                     scheme: date
#   product: Cargo.toml
#
# semver (the templates): the product manifest holds MAJOR.MINOR.PATCH, and
# a release tag is that number with a v. Every other manifest in the tree
# (package.json, Cargo.toml, *.csproj, *.props, CMakeLists.txt project(),
# vcpkg.json) is not a product: it has no version or 0.0.0.
#
# date (the deployed sites): nothing is published for anyone to depend on,
# so no manifest carries a version. A milestone is tagged vYYYY.MM.DD, or
# vYYYY.MM.DD.N for the Nth of a day. --next reads the existing tag names on
# stdin and prints the next one for today (UTC, or VERSION_TODAY).
#
# On 2026-09-27 every repository's tags and manifests disagreed. A C++
# template tagged v2.6.0 had 0.1.0 in CMakeLists.txt, and cargo-semver-checks
# judged each Rust release against a Cargo.toml that never moved. The
# comment names no repository: setup.sh fails a renamed copy that still
# names its template.

set -euo pipefail
cd "$(dirname "$0")/.."

CONF=.versioning
SEMVER='^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'
DATETAG='^v[0-9]{4}\.[0-9]{2}\.[0-9]{2}(\.[0-9]+)?$'

# version_of <file>: the version the manifest declares, or nothing.
version_of() {
  case "$1" in
    *package.json|*vcpkg.json)
      sed -nE 's/^  "version(-string|-semver)?": *"([^"]*)".*/\2/p' "$1" | head -1 ;;
    *Cargo.toml)
      awk '/^\[/ { pkg = ($0 == "[package]") } pkg && /^version *=/ { gsub(/.*= *"|".*/, ""); print; exit }' "$1" ;;
    *.csproj|*.props)
      sed -nE 's|.*<Version(Prefix)?>([^<]*)</Version(Prefix)?>.*|\2|p' "$1" | head -1 ;;
    *CMakeLists.txt)
      # The VERSION argument of project(), which may span lines. The
      # VERSION of cmake_minimum_required() is not the project's.
      awk '
        /^[[:space:]]*project[[:space:]]*\(/ { inproj = 1; buf = "" }
        inproj { buf = buf " " $0; if ($0 ~ /\)/) {
          n = split(buf, w, /[[:space:]()]+/)
          for (i = 1; i < n; i++) if (w[i] == "VERSION") { print w[i + 1]; exit }
          inproj = 0 } }' "$1" ;;
  esac
}

# manifests: every manifest in the tree, relative, skipping installed and
# built trees. find rather than git ls-files: inside a container a
# worktree's .git names a host path and git cannot read it.
manifests() {
  find . \( -name node_modules -o -name .git -o -name target -o -name build \
            -o -name bin -o -name obj -o -name dist \) -prune -o -type f \
         \( -name package.json -o -name vcpkg.json -o -name Cargo.toml \
            -o -name '*.csproj' -o -name '*.props' -o -name CMakeLists.txt \) -print \
    | sed 's|^\./||' | sort
}

conf() { sed -n "s/^$1: *//p" "$CONF" | head -1; }

# check [tag]: against the repository in the current directory. A subshell,
# so an exit inside it ends the check and not the caller.
check() (
  [ -f "$CONF" ] || { echo "error: $CONF not found" >&2; exit 1; }
  scheme="$(conf scheme)"
  product="$(conf product)"
  status=0
  case "$scheme" in
    semver)
      [ -n "$product" ] || { echo "error: $CONF: scheme semver needs a 'product: <manifest>' line" >&2; exit 1; }
      [ -f "$product" ] || { echo "error: $CONF names $product, which does not exist" >&2; exit 1; }
      version="$(version_of "$product")"
      if ! printf '%s\n' "$version" | grep -Eq "$SEMVER"; then
        echo "error: $product declares version '${version}', not MAJOR.MINOR.PATCH" >&2
        exit 1
      fi
      ;;
    date) product="" ;;
    *) echo "error: $CONF: scheme is '$scheme', expected semver or date" >&2; exit 1 ;;
  esac

  while IFS= read -r m; do
    [ "$m" = "$product" ] && continue
    v="$(version_of "$m")"
    case "$v" in
      ""|0.0.0) ;;
      *) echo "error: $m declares version $v. Only ${product:-the tag} carries this repository's version. Set it to 0.0.0." >&2
         status=1 ;;
    esac
  done < <(manifests)

  if [ $# -gt 0 ]; then
    tag="$1"
    if [ "$scheme" = semver ]; then
      if [ "$tag" != "v$version" ]; then
        echo "error: tag $tag, but $product says $version. Merge a pull request setting $product to ${tag#v}, then tag that commit." >&2
        status=1
      fi
    elif ! valid_date_tag "$tag"; then
      echo "error: tag $tag is not vYYYY.MM.DD or vYYYY.MM.DD.N with a real month and day" >&2
      status=1
    fi
  fi

  [ $status -eq 0 ] && echo "version: $scheme${version:+ $version}${1:+, tag $1}: ok"
  exit $status
)

valid_date_tag() {
  printf '%s\n' "$1" | grep -Eq "$DATETAG" || return 1
  local month day
  month="$(printf '%s' "$1" | cut -d. -f2)"
  day="$(printf '%s' "$1" | cut -d. -f3)"
  [ "$((10#$month))" -ge 1 ] && [ "$((10#$month))" -le 12 ] \
    && [ "$((10#$day))" -ge 1 ] && [ "$((10#$day))" -le 31 ]
}

# next: the existing tag names on stdin, the next date tag on stdout.
next() {
  local today n
  today="v${VERSION_TODAY:-$(date -u +%Y.%m.%d)}"
  valid_date_tag "$today" || { echo "error: today's tag $today is malformed" >&2; return 1; }
  n="$(grep -E "^${today//./\\.}(\.[0-9]+)?$" | awk -F. -v base="$today" '
        $0 == base { if (max < 1) max = 1; next }
        { if ($4 + 0 > max) max = $4 + 0 }
        END { print max + 0 }' || true)"
  if [ "${n:-0}" -eq 0 ]; then echo "$today"; else echo "$today.$((n + 1))"; fi
}

self_test() {
  local root fails=0
  root="$(mktemp -d)"
  trap 'rm -rf "$root"' RETURN

  # expect <want exit> <name> <message fragment or ""> <dir> [check args]
  expect() {
    local want="$1" name="$2" frag="$3" dir="$4" out rc=0
    shift 4
    out="$(cd "$dir" && check "$@" 2>&1)" || rc=$?
    if [ "$rc" -ne "$want" ] || { [ -n "$frag" ] && ! grep -qF -- "$frag" <<<"$out"; }; then
      echo "self-test FAILED: $name (exit $rc, wanted $want${frag:+ with \"$frag\"}): $out" >&2
      fails=$((fails + 1))
    else
      echo "self-test ok: $name"
    fi
  }

  # Rust: product Cargo.toml, a fuzz crate at 0.0.0, a dependency table
  # whose version must not be read as the package's.
  local rust="$root/rust"
  mkdir -p "$rust/fuzz" "$rust/node_modules/x"
  printf 'scheme: semver\nproduct: Cargo.toml\n' > "$rust/$CONF"
  printf '[package]\nname = "a"\nversion = "1.2.0"\n\n[dependencies.b]\nversion = "9.9.9"\n' > "$rust/Cargo.toml"
  printf '[package]\nname = "a-fuzz"\nversion = "0.0.0"\n' > "$rust/fuzz/Cargo.toml"
  printf '{\n  "version": "5.0.0"\n}\n' > "$rust/node_modules/x/package.json"
  expect 0 "semver: product 1.2.0, fuzz 0.0.0, node_modules ignored" "" "$rust"
  expect 0 "semver: tag v1.2.0 matches Cargo.toml" "" "$rust" v1.2.0
  expect 1 "semver: tag v1.3.0 does not match 1.2.0" "says 1.2.0" "$rust" v1.3.0
  printf '[package]\nname = "a-fuzz"\nversion = "0.1.0"\n' > "$rust/fuzz/Cargo.toml"
  expect 1 "semver: a second manifest with a version fails naming it" "fuzz/Cargo.toml declares version 0.1.0" "$rust"
  printf '[package]\nname = "a-fuzz"\n' > "$rust/fuzz/Cargo.toml"
  printf '[package]\nname = "a"\nversion = "1.2"\n' > "$rust/Cargo.toml"
  expect 1 "semver: a product version that is not MAJOR.MINOR.PATCH" "not MAJOR.MINOR.PATCH" "$rust"

  # C++: project() across lines, after cmake_minimum_required(VERSION).
  local cpp="$root/cpp"
  mkdir -p "$cpp/test"
  printf 'scheme: semver\nproduct: CMakeLists.txt\n' > "$cpp/$CONF"
  printf 'cmake_minimum_required(VERSION 3.28)\n\nproject(\n  Demo\n  VERSION 2.6.0\n  LANGUAGES CXX)\n' > "$cpp/CMakeLists.txt"
  printf 'cmake_minimum_required(VERSION 3.28)\n' > "$cpp/test/CMakeLists.txt"
  expect 0 "semver: CMake project VERSION read past cmake_minimum_required" "" "$cpp" v2.6.0
  expect 1 "semver: CMake tag mismatch" "says 2.6.0" "$cpp" v2.5.0

  # .NET: <Version> in Directory.Build.props, package.json at 0.1.0 fails.
  local web="$root/web"
  mkdir -p "$web/server" "$web/client"
  printf 'scheme: semver\nproduct: server/Directory.Build.props\n' > "$web/$CONF"
  printf '<Project>\n  <PropertyGroup>\n    <Version>2.0.0</Version>\n  </PropertyGroup>\n</Project>\n' > "$web/server/Directory.Build.props"
  printf '{\n  "name": "client",\n  "version": "0.0.0"\n}\n' > "$web/client/package.json"
  expect 0 "semver: <Version> in Directory.Build.props, client at 0.0.0" "" "$web" v2.0.0
  printf '{\n  "name": "client",\n  "version": "0.1.0"\n}\n' > "$web/client/package.json"
  expect 1 "semver: client package.json at 0.1.0 fails" "client/package.json declares version 0.1.0" "$web"
  rm "$web/server/Directory.Build.props"
  expect 1 "semver: a missing product manifest fails" "does not exist" "$web"

  # Date scheme: no manifest carries a version.
  local site="$root/site"
  mkdir -p "$site/e2e"
  printf 'scheme: date\n' > "$site/$CONF"
  printf '{\n  "name": "site",\n  "private": true,\n  "version": "0.0.0"\n}\n' > "$site/package.json"
  printf '{\n  "name": "e2e"\n}\n' > "$site/e2e/package.json"
  expect 0 "date: manifests at 0.0.0 or none" "" "$site"
  expect 0 "date: tag v2026.09.27" "" "$site" v2026.09.27
  expect 0 "date: tag v2026.09.27.2" "" "$site" v2026.09.27.2
  expect 1 "date: a SemVer tag fails" "is not vYYYY.MM.DD" "$site" v1.2.0
  expect 1 "date: month 13 fails" "is not vYYYY.MM.DD" "$site" v2026.13.01
  printf '{\n  "name": "site",\n  "version": "1.2.0"\n}\n' > "$site/package.json"
  expect 1 "date: package.json at 1.2.0 fails" "package.json declares version 1.2.0" "$site"

  printf 'scheme: calver\n' > "$site/$CONF"
  expect 1 "an unknown scheme fails" "expected semver or date" "$site"
  rm "$site/$CONF"
  expect 1 "a missing .versioning fails" ".versioning not found" "$site"

  # --next.
  expect_next() {
    local name="$1" want="$2" got
    got="$(printf '%b' "$3" | VERSION_TODAY=2026.09.27 next)"
    if [ "$got" = "$want" ]; then echo "self-test ok: $name"
    else echo "self-test FAILED: $name: got '$got', wanted '$want'" >&2; fails=$((fails + 1)); fi
  }
  expect_next "next: first of the day" v2026.09.27 'v1.0.0\nv2.0.0\n'
  expect_next "next: no tags at all" v2026.09.27 ''
  expect_next "next: second of the day" v2026.09.27.2 'v2.0.0\nv2026.09.27\n'
  expect_next "next: fourth, out of order" v2026.09.27.4 'v2026.09.27.3\nv2026.09.27\nv2026.09.27.2\nv2026.09.26.9\n'

  if [ "$fails" -ne 0 ]; then
    echo "check-version self-test: $fails failed" >&2
    return 1
  fi
  echo "check-version self-test: all passed"
}

case "${1:-}" in
  "") check ;;
  --tag) [ -n "${2:-}" ] || { echo "usage: $0 --tag vX" >&2; exit 2; }; check "$2" ;;
  --next) next ;;
  --self-test) self_test ;;
  *) echo "usage: $0 [--tag vX | --next | --self-test]" >&2; exit 2 ;;
esac
