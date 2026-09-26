#!/usr/bin/env bash
#
# check-lts-majors.sh: the .NET and Node majors stay on LTS releases.
#
# Every Dependabot pull request auto-merges on green CI, majors included.
# Dependabot cannot read a support phase, so .github/dependabot.yml ignores
# each major that is not LTS with a range of the form ">= N, < N+1", and
# this script keeps those ranges honest.
#
# .NET: even majors are LTS, odd majors are STS. One major ships each
# November: 11 in 2026, 13 in 2028.
#   1. Every mcr.microsoft.com/dotnet image in a tracked Dockerfile and every
#      <TargetFramework> is an even major.
#   2. The docker entry that updates each of those images, and the nuget
#      entry that updates each framework package on the runtime major
#      (Microsoft.AspNetCore.*, Microsoft.EntityFrameworkCore*,
#      Microsoft.Extensions.*, Npgsql.EntityFrameworkCore.*), ignores every
#      odd major through the one due two years from now, and no even major.
# Node: a major is LTS once a release of it in NODE_INDEX_URL carries an lts
# codename. From 27 on each major ships in April and turns LTS in October.
#   3. The docker entry that updates each node image ignores every major
#      above the one in use, through the one due two years from now, that is
#      not LTS yet. It ignores no LTS major. The range comes out when its
#      major turns LTS, and this check fails until it does.
#   4. Every npm entry for a package.json with @types/node ignores the same
#      majors of @types/node, so the types never run ahead of the runtime.
#
#   scripts/check-lts-majors.sh              check the repository
#   scripts/check-lts-majors.sh --self-test  prove each check fails on a
#                                            planted defect
#
# Exit 1 on a finding. Exit 2 when NODE_INDEX_URL cannot be read: an
# outage, not a pass. LTS_YEAR (two digits) overrides the current year.

set -euo pipefail
cd "$(dirname "$0")/.."

NODE_INDEX_URL="${NODE_INDEX_URL:-https://nodejs.org/dist/index.json}"
FRAMEWORK='^(Microsoft\.AspNetCore\.|Microsoft\.EntityFrameworkCore|Microsoft\.Extensions\.|Npgsql\.EntityFrameworkCore\.)'
FROM='^[[:space:]]*FROM[[:space:]]+(--platform=[^[:space:]]+[[:space:]]+)?'
DOTNET_FROM="${FROM}mcr\\.microsoft\\.com/(dotnet/[a-z-]+):([0-9]+)\\..*"
NODE_FROM="${FROM}(docker\\.io/)?(library/)?node:([0-9]+)([^0-9.].*)?\$"

# table <dependabot.yml>: one line per fact.
#   E <entry> <ecosystem> <directory>
#   I <entry> <dependency-name> <lo> <hi>   an ignore range ">= lo, < hi"
#   I <entry> <dependency-name> bad <text>  any other ignore version
table() {
  awk '
    function ind(s) { match(s, /^ */); return RLENGTH }
    function val(s) { s = substr(s, index(s, ":") + 1); gsub(/^[ "]+|[ "]+$/, "", s); return s }
    function range(s,   t, v) {
      t = s; gsub(/[ "]/, "", t)
      if (t ~ /^>=[0-9]+,<[0-9]+$/) { split(t, v, /[^0-9]+/); print "I", n, name, v[2], v[3] }
      else print "I", n, name, "bad", t
    }
    /^[ \t]*(#|$)/ { next }
    { i = ind($0); line = substr($0, i + 1) }
    i <= 2 && line ~ /^- package-ecosystem:/ { n++; eco = val(line); key = ""; next }
    i <= 2 { key = ""; next }
    i == 4 {
      key = line; sub(/:.*/, "", key)
      if (key == "directory") print "E", n, eco, val(line)
      next
    }
    key == "directories" && line ~ /^- / { s = substr(line, 3); gsub(/[ "]/, "", s); print "E", n, eco, s; next }
    key == "ignore" && i == 6 && line ~ /^- dependency-name:/ { name = val(line); vk = 0; next }
    key == "ignore" && i == 8 {
      vk = (line ~ /^versions:/)
      if (vk && line ~ /\[/) {
        s = line; sub(/^[^[]*\[/, "", s)
        while (match(s, /"[^"]*"/)) { range(substr(s, RSTART, RLENGTH)); s = substr(s, RSTART + RLENGTH) }
        vk = 0
      }
      next
    }
    key == "ignore" && vk && i == 10 && line ~ /^- / { range(substr(line, 3)); next }
  ' "$1"
}

# listed <pattern>...: the files the check reads. git ls-files in the
# repository, find in a self-test copy.
listed() {
  if [ "${LTS_LISTING:-git}" = find ]; then
    local f p
    find . -type f | sed 's|^\./||' | sort | while IFS= read -r f; do
      for p; do
        # shellcheck disable=SC2053 # the pattern is a glob on purpose
        if [[ "$f" == $p ]]; then echo "$f"; break; fi
      done
    done
  else
    git ls-files -- "$@"
  fi
}

dirof() { # dirof <file>: its directory as dependabot.yml writes it
  local d
  d="$(dirname "$1")"
  if [ "$d" = . ]; then echo /; else echo "/$d"; fi
}

# entries <ecosystem> <directory> [prefix]: the entries updating that
# directory. With prefix, an entry for any parent directory counts too.
entries() {
  local eco="$1" dir="$2" prefix="${3:-}" tag n e d
  while read -r tag n e d; do
    [ "$tag" = E ] && [ "$e" = "$eco" ] || continue
    [ "$d" = / ] || d="${d%/}"
    if [ "$d" = "$dir" ] || { [ -n "$prefix" ] && { [ "$d" = / ] || [[ "$dir" == "$d"/* ]]; }; }; then
      echo "$n"
    fi
  done < "$TABLE"
}

# ranges <entry> <dependency>: "lo hi" for each ignore range in that entry
# whose dependency-name (a Dependabot wildcard) matches the dependency.
ranges() {
  local entry="$1" dep="$2" tag n pat lo hi
  while read -r tag n pat lo hi; do
    [ "$tag" = I ] && [ "$n" = "$entry" ] || continue
    # shellcheck disable=SC2053 # the pattern is a Dependabot wildcard
    [[ "$dep" == $pat ]] || continue
    echo "$lo $hi"
  done < "$TABLE"
}

# judge <what> <ranges> <need> <free>: every major in need is inside a
# range, none in free is.
judge() {
  local what="$1" rs="$2" need="$3" free="$4" m lo hi hit
  if grep -q '^bad' <<< "$rs"; then
    echo "error: $what: every ignore version must read \">= N, < M\"" >&2
    STATUS=1
    return
  fi
  for m in $need $free; do
    hit=0
    while read -r lo hi; do
      [ -n "$lo" ] || continue
      if [ "$lo" -le "$m" ] && [ "$hi" -gt "$m" ]; then hit=1; fi
    done <<< "$rs"
    if [[ " $need " == *" $m "* ]] && [ "$hit" = 0 ]; then
      echo "error: $what: major $m is not LTS and not ignored; add \">= $m, < $((m + 1))\"" >&2
      STATUS=1
    elif [[ " $free " == *" $m "* ]] && [ "$hit" = 1 ]; then
      echo "error: $what: major $m is LTS or in use, and an ignore range covers it" >&2
      STATUS=1
    fi
  done
}

# each <ecosystem> <file> <dependency> <need> <free> [prefix]: judge the
# ranges of every entry that updates the file.
each() {
  local eco="$1" file="$2" dep="$3" need="$4" free="$5" prefix="${6:-}" dir n found=0
  dir="$(dirof "$file")"
  for n in $(entries "$eco" "$dir" "$prefix"); do
    found=1
    judge "$file: $dep in the $eco entry for $dir" "$(ranges "$n" "$dep")" "$need" "$free"
  done
  if [ "$found" = 0 ]; then
    echo "error: $file: no $eco entry in .github/dependabot.yml updates $dep in $dir" >&2
    STATUS=1
  fi
}

check_dotnet() {
  local yy="$1" dockerfiles projects f img major cur=0 due m need="" free="" id ver
  dockerfiles="$(listed Dockerfile '*/Dockerfile' '*.Dockerfile' 'Dockerfile.*')"
  projects="$(listed '*.props' '*.csproj')"
  local images
  images="$(for f in $dockerfiles; do sed -nE "s#${DOTNET_FROM}#${f} \\2 \\3#p" "$f"; done | sort -u)"
  [ -n "$images" ] || return 0

  while read -r f img major; do
    if [ $((major % 2)) -eq 1 ]; then
      echo "error: $f: $img:$major is an STS major; .NET LTS majors are even" >&2
      STATUS=1
    fi
    [ "$major" -gt "$cur" ] && cur="$major"
  done <<< "$images"
  for f in $projects; do
    for major in $(grep -Eo '<TargetFrameworks?>[^<]*' "$f" | grep -Eo 'net[0-9]+' | tr -d net); do
      if [ $((major % 2)) -eq 1 ]; then
        echo "error: $f: net$major is an STS major; .NET LTS majors are even" >&2
        STATUS=1
      fi
    done
  done

  due=$((yy - 15 + 2))
  for ((m = cur + 1; m <= due; m++)); do
    if [ $((m % 2)) -eq 1 ]; then need="$need $m"; fi
  done
  for ((m = cur - cur % 2; m <= cur + 8; m += 2)); do free="$free $m"; done

  while read -r f img major; do
    each docker "$f" "$img" "$need" "$free"
  done <<< "$images"

  for f in $projects; do
    while read -r id ver; do
      [ -n "$id" ] || continue
      if [[ "$id" =~ $FRAMEWORK ]] && [ "${ver%%.*}" = "$cur" ]; then
        each nuget "$f" "$id" "$need" "$free" prefix
      fi
    done < <(sed -nE 's#.*Include="([^"]+)"[[:space:]]+Version="([0-9][^"]*)".*#\1 \2#p' "$f")
  done
}

check_node() {
  local yy="$1" dockerfiles images f major cur=0 due m need="" free="" index lts
  dockerfiles="$(listed Dockerfile '*/Dockerfile' '*.Dockerfile' 'Dockerfile.*')"
  images="$(for f in $dockerfiles; do sed -nE "s#${NODE_FROM}#${f} \\4#p" "$f"; done | sort -u)"
  [ -n "$images" ] || return 0

  index="$(mktemp)"
  if ! curl -fsSL --max-time 60 "$NODE_INDEX_URL" -o "$index" 2>/dev/null; then
    sleep 5
    if ! curl -fsSL --max-time 60 "$NODE_INDEX_URL" -o "$index"; then
      rm -f "$index"
      echo "error: could not read $NODE_INDEX_URL: an outage, not a pass" >&2
      exit 2
    fi
  fi
  lts="$(jq -r '[.[] | select(.lts != false) | .version | ltrimstr("v") | split(".")[0] | tonumber] | unique | .[]' "$index" 2>/dev/null || true)"
  rm -f "$index"
  if [ -z "$lts" ]; then
    echo "error: $NODE_INDEX_URL names no LTS release: an outage, not a pass" >&2
    exit 2
  fi

  while read -r f major; do
    [ "$major" -gt "$cur" ] && cur="$major"
  done <<< "$images"
  due=$((yy + 2))
  free="$cur"
  for ((m = cur + 1; m <= due; m++)); do
    if grep -qx "$m" <<< "$lts"; then free="$free $m"; else need="$need $m"; fi
  done

  while read -r f major; do
    each docker "$f" node "$need" "$free"
  done <<< "$images"
  for f in $(listed package.json '*/package.json'); do
    if grep -q '"@types/node"' "$f"; then
      each npm "$f" @types/node "$need" "$free"
    fi
  done
}

# check: exit 1 naming each defect, 2 on an outage.
check() {
  local yy="${LTS_YEAR:-$(date -u +%y)}"
  yy=$((10#$yy))
  STATUS=0
  TABLE="$(mktemp)"
  table .github/dependabot.yml > "$TABLE"
  check_dotnet "$yy"
  check_node "$yy"
  rm -f "$TABLE"
  return "$STATUS"
}

SELF_TEST_FAILED=0
expect() { # expect <exit> <text> <label> <case> [env...]
  local want="$1" needle="$2" label="$3" case="$4" code=0 out
  shift 4
  # shellcheck disable=SC2163 # the arguments are NAME=value pairs
  out="$(cd "$DIR/$case" && export LTS_LISTING=find NODE_INDEX_URL="file://$DIR/index.json" "$@" && check 2>&1)" || code=$?
  if [ "$code" -eq "$want" ] && grep -qF -- "$needle" <<< "$out"; then
    echo "self-test: ok: $label (exit $code)"
  else
    echo "self-test FAILED: $label: wanted exit $want and '$needle', got exit $code:" >&2
    printf '%s\n' "$out" | sed 's/^/    /' >&2
    SELF_TEST_FAILED=1
  fi
}

self_test() {
  local files f case yy cur m lo hi first="" dn=""
  DIR="$(mktemp -d)"
  # shellcheck disable=SC2064 # expand now: the directory name is fixed
  trap "rm -rf '$DIR'" EXIT
  files="$(git ls-files -- .github/dependabot.yml Dockerfile '*/Dockerfile' '*.Dockerfile' 'Dockerfile.*' \
    '*.props' '*.csproj' package.json '*/package.json')"
  for case in clean promoted missing types outage lapsed dotnet-sts dotnet-swallow dotnet-nuget; do
    for f in $files; do
      mkdir -p "$DIR/$case/$(dirname "$f")"
      cp "$f" "$DIR/$case/$f"
    done
  done

  # The index names every major LTS except the ones the real ranges
  # ignore, so the real files pass whatever the date.
  yy="$(date -u +%y)"
  yy=$((10#$yy))
  TABLE="$(mktemp)"
  table .github/dependabot.yml > "$TABLE"
  local ignored
  ignored="$(awk '$1 == "I" && $3 == "node" && $4 != "bad" { for (m = $4; m < $5; m++) print m }' "$TABLE" | sort -un)"
  rm -f "$TABLE"
  cur="$(for f in $files; do sed -nE "s#${NODE_FROM}#\\4#p" "$f"; done | sort -n | tail -1)"
  if [ -z "$cur" ] || [ -z "$ignored" ]; then
    echo "self-test FAILED: no node image, or no node ignore ranges, to test against" >&2
    return 1
  fi
  first="$(head -1 <<< "$ignored")"
  index() { # index <major that is LTS despite its range>
    local m sep=""
    printf '['
    for ((m = 18; m <= yy + 4; m++)); do
      if [ "$m" = "$1" ] || ! grep -qx "$m" <<< "$ignored"; then
        printf '%s{"version":"v%s.0.0","lts":"Name%s"}' "$sep" "$m" "$m"
      else
        printf '%s{"version":"v%s.0.0","lts":false}' "$sep" "$m"
      fi
      sep=,
    done
    printf ']\n'
  }
  index none > "$DIR/index.json"
  index "$first" > "$DIR/promoted-index.json"

  # Planted defects, one per case.
  awk -v r=">= $first, < $((first + 1))" '!index($0, r)' .github/dependabot.yml > "$DIR/missing/.github/dependabot.yml"
  awk -v r=">= $first, < $((first + 1))" '
    /dependency-name: *"?@types\/node/ { t = 1 }
    t && index($0, r) { t = 0; next }
    { print }
  ' .github/dependabot.yml > "$DIR/types/.github/dependabot.yml"

  expect 0 "" "the real Dockerfiles, projects and dependabot.yml pass" clean LTS_YEAR="$yy"
  expect 1 "major $first is LTS or in use, and an ignore range covers it" \
    "a node major that turned LTS and is still ignored fails" promoted LTS_YEAR="$yy" NODE_INDEX_URL="file://$DIR/promoted-index.json"
  expect 1 "major $first is not LTS and not ignored" \
    "a missing range for a node major that is not LTS fails" missing LTS_YEAR="$yy"
  if grep -rqs '"@types/node"' --include=package.json "$DIR/types"; then
    expect 1 "@types/node in the npm entry for" \
      "@types/node out of lockstep with the node image fails" types LTS_YEAR="$yy"
  fi
  expect 2 "an outage, not a pass" "an unreadable Node index is an outage" outage \
    LTS_YEAR="$yy" NODE_INDEX_URL="file://$DIR/no-such-index.json"
  expect 1 "is not LTS and not ignored" "ranges that lapse within two years fail" lapsed LTS_YEAR=40

  dn="$(for f in $files; do sed -nE "s#${DOTNET_FROM}#\\3#p" "$f"; done | sort -n | tail -1)"
  if [ -n "$dn" ]; then
    m=$((dn + 1))
    for f in $files; do
      case "$f" in *Dockerfile*) sed -E -i "s#(mcr\\.microsoft\\.com/dotnet/aspnet:)$dn\\.#\\1$m.#" "$DIR/dotnet-sts/$f" ;; esac
    done
    sed -i "s/\">= $m, < $((m + 1))\"/\">= $m, < $((m + 2))\"/" "$DIR/dotnet-swallow/.github/dependabot.yml"
    sed -i 's/dependency-name: "Microsoft\.AspNetCore\.\*"/dependency-name: "Microsoft.AspNetCoreX.*"/' \
      "$DIR/dotnet-nuget/.github/dependabot.yml"
    expect 1 "dotnet/aspnet:$m is an STS major" "a planted STS .NET image fails" dotnet-sts LTS_YEAR="$yy"
    expect 1 "major $((m + 1)) is LTS or in use, and an ignore range covers it" \
      "a .NET range that swallows the next LTS fails" dotnet-swallow LTS_YEAR="$yy"
    expect 1 ": Microsoft.AspNetCore." "a framework package without its ignore fails" dotnet-nuget LTS_YEAR="$yy"
  else
    echo "self-test: no .NET image here, the .NET cases do not apply"
  fi

  if [ "$SELF_TEST_FAILED" -eq 0 ]; then
    echo "self-test: every planted defect was caught; the real files pass"
  fi
  return "$SELF_TEST_FAILED"
}

if [ "${1:-}" = --self-test ]; then
  self_test
else
  code=0
  check || code=$?
  if [ "$code" -eq 0 ]; then
    echo ".NET and Node images are on LTS majors, and the Dependabot ignore ranges hold back every major that is not LTS through 20$(( 10#${LTS_YEAR:-$(date -u +%y)} + 2 ))"
  fi
  exit "$code"
fi
