#!/usr/bin/env bash
#
# check-newest-majors.sh: the .NET and Node majors are the newest GA releases.
#
# A GA release is taken whether or not it is LTS: an STS .NET major and a
# Node Current major count. Previews, release candidates and nightlies do not.
#   1. .github/dependabot.yml holds back no major of a .NET image, a framework
#      package on the runtime major (Microsoft.AspNetCore.*,
#      Microsoft.EntityFrameworkCore*, Microsoft.Extensions.*,
#      Npgsql.EntityFrameworkCore.*), a node image or @types/node. An ignore
#      entry for one of those names may hold an exact version, never a range
#      or a semver-major update type.
#   2. Every mcr.microsoft.com/dotnet image in a tracked Dockerfile and every
#      <TargetFramework> is on the newest .NET major whose support phase in
#      RELEASES_INDEX_URL is active or maintenance, once its first GA release
#      has been out GRACE_DAYS.
#   3. Every node image is on the newest major in NODE_INDEX_URL, which lists
#      releases only, once its first release has been out GRACE_DAYS.
# GRACE_DAYS (45) covers the monthly dotnet-major-upgrade run and a weekly
# Dependabot major that has to be fixed before it merges.
#
#   scripts/check-newest-majors.sh              check the repository
#   scripts/check-newest-majors.sh --self-test  prove each check fails on a
#                                               planted defect
#
# Exit 1 on a finding. Exit 2 when an index cannot be read: an outage, not a
# pass.

set -euo pipefail
cd "$(dirname "$0")/.."

RELEASES_INDEX_URL="${RELEASES_INDEX_URL:-https://raw.githubusercontent.com/dotnet/core/main/release-notes/releases-index.json}"
NODE_INDEX_URL="${NODE_INDEX_URL:-https://nodejs.org/dist/index.json}"
GRACE_DAYS="${GRACE_DAYS:-45}"
RUNTIME='^("?)(node|@types/node|dotnet/.*|mcr\.microsoft\.com/dotnet.*|Microsoft\.AspNetCore\..*|Microsoft\.EntityFrameworkCore.*|Microsoft\.Extensions\..*|Npgsql\.EntityFrameworkCore\..*)("?)$'
FROM='^[[:space:]]*FROM[[:space:]]+(--platform=[^[:space:]]+[[:space:]]+)?'
DOTNET_FROM="${FROM}mcr\\.microsoft\\.com/(dotnet/[a-z-]+):([0-9]+)\\..*"
NODE_FROM="${FROM}(docker\\.io/)?(library/)?node:([0-9]+)([^0-9.].*)?\$"

# listed <pattern>...: the files the check reads. git ls-files in the
# repository, find in a self-test copy.
listed() {
  if [ "${NEWEST_LISTING:-git}" = find ]; then
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

fetch() { # fetch <url> <file>: one retry, then exit 2
  if ! curl -fsSL --max-time 60 "$1" -o "$2" 2>/dev/null; then
    sleep 5
    if ! curl -fsSL --max-time 60 "$1" -o "$2"; then
      echo "error: could not read $1: an outage, not a pass" >&2
      exit 2
    fi
  fi
}

# due <YYYY-MM-DD>: true once the date is GRACE_DAYS in the past.
due() {
  local since now
  since="$(date -u -d "$1" +%s)"
  now="$(date -u +%s)"
  [ $(((now - since) / 86400)) -ge "$GRACE_DAYS" ]
}

check_holds() {
  local found
  found="$(RT="$RUNTIME" awk '
    function ind(s) { match(s, /^ */); return RLENGTH }
    /^[ \t]*(#|$)/ { next }
    { i = ind($0); line = substr($0, i + 1) }
    i <= 4 { ig = (i == 4 && line ~ /^ignore:/); name = ""; next }
    ig && line ~ /^- dependency-name:/ {
      name = line; sub(/^- dependency-name:[ ]*/, "", name); gsub(/"/, "", name)
      if (name !~ ENVIRON["RT"]) name = ""
      next
    }
    ig && name != "" && (line ~ /[<>*]/ || line ~ /semver-major/) {
      print NR ": " name " " line
    }
  ' .github/dependabot.yml)"
  if [ -n "$found" ]; then
    while IFS= read -r l; do
      echo "error: .github/dependabot.yml:$l holds back a GA major; hold an exact version or nothing" >&2
    done <<< "$found"
    STATUS=1
  fi
}

check_dotnet() {
  local dockerfiles projects sites f major newest index url rel ga
  dockerfiles="$(listed Dockerfile '*/Dockerfile' '*.Dockerfile' 'Dockerfile.*')"
  projects="$(listed '*.props' '*.csproj')"
  sites="$(
    for f in $dockerfiles; do sed -nE "s#${DOTNET_FROM}#${f} \\2:\\3 \\3#p" "$f"; done
    for f in $projects; do
      for major in $(grep -Eo '<TargetFrameworks?>[^<]*' "$f" | grep -Eo 'net[0-9]+' | tr -d net); do
        echo "$f net$major $major"
      done
    done | sort -u
  )"
  [ -n "$sites" ] || return 0

  index="$(mktemp)"
  fetch "$RELEASES_INDEX_URL" "$index"
  read -r newest url < <(jq -r '[."releases-index"[]
      | select(."support-phase" == "active" or ."support-phase" == "maintenance")
      | {m: (."channel-version" | split(".")[0] | tonumber), u: ."releases.json"}]
    | max_by(.m) | "\(.m) \(.u)"' "$index" 2>/dev/null || true)
  rm -f "$index"
  if [ -z "${newest:-}" ] || [ "$newest" = null ]; then
    echo "error: $RELEASES_INDEX_URL names no GA .NET major: an outage, not a pass" >&2
    exit 2
  fi
  rel="$(mktemp)"
  fetch "$url" "$rel"
  ga="$(jq -r --arg v "$newest.0.0" '.releases[] | select(."release-version" == $v) | ."release-date"' "$rel" 2>/dev/null || true)"
  rm -f "$rel"
  if [ -z "$ga" ]; then
    echo "error: $url names no $newest.0.0 release: an outage, not a pass" >&2
    exit 2
  fi
  due "$ga" || return 0

  while read -r f what major; do
    if [ "$major" -lt "$newest" ]; then
      echo "error: $f: $what is behind .NET $newest, GA since $ga" >&2
      STATUS=1
    fi
  done <<< "$sites"
}

check_node() {
  local dockerfiles images f major newest ga index
  dockerfiles="$(listed Dockerfile '*/Dockerfile' '*.Dockerfile' 'Dockerfile.*')"
  images="$(for f in $dockerfiles; do sed -nE "s#${NODE_FROM}#${f} \\4#p" "$f"; done | sort -u)"
  [ -n "$images" ] || return 0

  index="$(mktemp)"
  fetch "$NODE_INDEX_URL" "$index"
  read -r newest ga < <(jq -r '[.[] | {m: (.version | ltrimstr("v") | split(".")[0] | tonumber), d: .date}]
    | max_by(.m) as $top | [.[] | select(.m == $top.m)] | min_by(.d) | "\(.m) \(.d)"' "$index" 2>/dev/null || true)
  rm -f "$index"
  if [ -z "${newest:-}" ] || [ "$newest" = null ]; then
    echo "error: $NODE_INDEX_URL names no release: an outage, not a pass" >&2
    exit 2
  fi
  due "$ga" || return 0

  while read -r f major; do
    if [ "$major" -lt "$newest" ]; then
      echo "error: $f: node:$major is behind Node $newest, released $ga" >&2
      STATUS=1
    fi
  done <<< "$images"
}

check() {
  STATUS=0
  check_holds
  check_dotnet
  check_node
  return "$STATUS"
}

SELF_TEST_FAILED=0
expect() { # expect <exit> <text> <label> <case> [env...]
  local want="$1" needle="$2" label="$3" case="$4" code=0 out
  shift 4
  # shellcheck disable=SC2163 # the arguments are NAME=value pairs
  out="$(cd "$DIR/$case" && export NEWEST_LISTING=find "$@" && check 2>&1)" || code=$?
  if [ "$code" -eq "$want" ] && grep -qF -- "$needle" <<< "$out"; then
    echo "self-test: ok: $label (exit $code)"
  else
    echo "self-test FAILED: $label: wanted exit $want and '$needle', got exit $code:" >&2
    printf '%s\n' "$out" | sed 's/^/    /' >&2
    SELF_TEST_FAILED=1
  fi
}

self_test() {
  local files f case node dn old recent
  DIR="$(mktemp -d)"
  # shellcheck disable=SC2064 # expand now: the directory name is fixed
  trap "rm -rf '$DIR'" EXIT
  files="$(git ls-files -- .github/dependabot.yml Dockerfile '*/Dockerfile' '*.Dockerfile' 'Dockerfile.*' '*.props' '*.csproj')"
  for case in clean node-hold dotnet-hold; do
    for f in $files; do
      mkdir -p "$DIR/$case/$(dirname "$f")"
      cp "$f" "$DIR/$case/$f"
    done
  done
  old="$(date -u -d '-200 days' +%F)"
  recent="$(date -u -d '-10 days' +%F)"

  node="$(for f in $files; do sed -nE "s#${NODE_FROM}#\\4#p" "$f"; done | sort -n | tail -1)"
  dn="$(for f in $files; do sed -nE "s#${DOTNET_FROM}#\\3#p" "$f"; done | sort -n | tail -1)"
  node="${node:-24}"
  dn="${dn:-10}"

  # node <major> <date>: an index whose newest major is that one.
  nodeix() {
    printf '[{"version":"v%s.1.0","date":"%s"},{"version":"v%s.0.0","date":"%s"},{"version":"v%s.0.0","date":"2020-01-01"}]\n' \
      "$1" "$recent" "$1" "$2" "$node"
  }
  # dotnetix <name> <major> <phase> <type> <date>: an index whose newest
  # channel is that one, beside the current major and a preview after it.
  dotnetix() {
    printf '{"releases":[{"release-version":"%s.0.0","release-date":"%s"}]}\n' "$2" "$5" > "$DIR/$1-rel.json"
    printf '{"releases":[{"release-version":"%s.0.0","release-date":"2020-01-01"}]}\n' "$dn" > "$DIR/cur-rel.json"
    printf '{"releases-index":[{"channel-version":"%s.0","support-phase":"preview","release-type":"lts","releases.json":"file://%s/cur-rel.json"},{"channel-version":"%s.0","support-phase":"%s","release-type":"%s","releases.json":"file://%s/%s-rel.json"},{"channel-version":"%s.0","support-phase":"active","release-type":"lts","releases.json":"file://%s/cur-rel.json"}]}\n' \
      "$(($2 + 1))" "$DIR" "$2" "$3" "$4" "$DIR" "$1" "$dn" "$DIR" > "$DIR/$1-index.json"
  }
  nodeix "$node" "$old" > "$DIR/node-same.json"
  nodeix "$((node + 1))" "$old" > "$DIR/node-behind.json"
  nodeix "$((node + 1))" "$recent" > "$DIR/node-grace.json"
  dotnetix same "$dn" active lts "$old"
  dotnetix sts "$((dn + 1))" active sts "$old"
  dotnetix grace "$((dn + 1))" active sts "$recent"
  dotnetix preview "$((dn + 1))" go-live sts "$old"

  awk '{ print } /^[ ]{4}ignore:/ && !done { print "      - dependency-name: node\n        versions:\n          - \">= 99, < 100\""; done = 1 }' \
    .github/dependabot.yml > "$DIR/node-hold/.github/dependabot.yml"
  awk '{ print } /^[ ]{4}ignore:/ && !done { print "      - dependency-name: \"Microsoft.AspNetCore.*\"\n        update-types:\n          - version-update:semver-major"; done = 1 }' \
    .github/dependabot.yml > "$DIR/dotnet-hold/.github/dependabot.yml"

  local base=(RELEASES_INDEX_URL="file://$DIR/same-index.json" NODE_INDEX_URL="file://$DIR/node-same.json")
  expect 0 "" "the real files pass when they are on the newest majors" clean "${base[@]}"
  expect 1 "is behind Node $((node + 1))" "a node image a major behind past the grace fails" clean \
    RELEASES_INDEX_URL="file://$DIR/same-index.json" NODE_INDEX_URL="file://$DIR/node-behind.json"
  expect 0 "" "a node major inside the grace passes" clean \
    RELEASES_INDEX_URL="file://$DIR/same-index.json" NODE_INDEX_URL="file://$DIR/node-grace.json"
  expect 1 "holds back a GA major" "a range held on node fails" node-hold "${base[@]}"
  expect 1 "holds back a GA major" "a semver-major hold on a framework package fails" dotnet-hold "${base[@]}"
  expect 2 "an outage, not a pass" "an unreadable Node index is an outage" clean \
    RELEASES_INDEX_URL="file://$DIR/same-index.json" NODE_INDEX_URL="file://$DIR/none.json"
  # shellcheck disable=SC2086 # one argument per file on purpose
  if grep -Eqs 'mcr\.microsoft\.com/dotnet|<TargetFramework' $files; then
    expect 1 "behind .NET $((dn + 1))" "an STS .NET major past the grace is required" clean \
      RELEASES_INDEX_URL="file://$DIR/sts-index.json" NODE_INDEX_URL="file://$DIR/node-same.json"
    expect 0 "" "a .NET major inside the grace passes" clean \
      RELEASES_INDEX_URL="file://$DIR/grace-index.json" NODE_INDEX_URL="file://$DIR/node-same.json"
    expect 0 "" "a .NET go-live release candidate is not required" clean \
      RELEASES_INDEX_URL="file://$DIR/preview-index.json" NODE_INDEX_URL="file://$DIR/node-same.json"
    expect 2 "an outage, not a pass" "an unreadable .NET index is an outage" clean \
      RELEASES_INDEX_URL="file://$DIR/none.json" NODE_INDEX_URL="file://$DIR/node-same.json"
  else
    echo "self-test: no .NET here, the .NET cases do not apply"
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
    echo ".NET and Node are on their newest GA majors (or inside the ${GRACE_DAYS}-day grace), and Dependabot holds back no major of either"
  fi
  exit "$code"
fi
