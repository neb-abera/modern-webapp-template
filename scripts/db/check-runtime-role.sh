#!/usr/bin/env bash
#
# check-runtime-role.sh — prove scripts/db/runtime-role.sql against a real
# PostgreSQL: the role the app runs as can read and write rows, and is REFUSED
# CREATE, ALTER, DROP and TRUNCATE.
#
# The template has no data layer yet. This runs anyway, so the role script is
# known-good on the day a database is added, and keeps being proven after:
# against the PostgreSQL image compose.yaml pins (digest and all — Dependabot
# moves it, this follows), in a throwaway container with no published port.
#
# Order matters and is the point: the role script runs FIRST and the table is
# created AFTER, so rows being writable proves the default privileges, not
# just the grants on what already existed.
#
# A checker that has never been seen to fail is not a checker: the same run
# repeats the assertions in a second database where the runtime role was
# (wrongly) granted CREATE and ownership of the table, and requires them to
# FAIL there.

set -euo pipefail
cd "$(dirname "$0")/../.."

NAME="$(basename "$PWD" | tr '[:upper:]' '[:lower:]')"
DB="$NAME-verify-db"
PG_IMAGE="$(sed -n 's|^ *image: \(postgres:[^ ]*\)$|\1|p' compose.yaml | head -1)"
[ -n "$PG_IMAGE" ] || { echo "error: could not derive the postgres image from compose.yaml" >&2; exit 1; }

# shellcheck disable=SC2329  # invoked via the EXIT trap below
cleanup() { docker rm -f "$DB" > /dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup

docker run -d --rm --name "$DB" -e POSTGRES_PASSWORD=throwaway \
  -v "$PWD/scripts/db":/scripts:ro "$PG_IMAGE" > /dev/null

# Ready means accepting TCP connections: the image's first-run setup serves
# the unix socket briefly before restarting for real.
ready=""
for _ in $(seq 1 60); do
  if docker exec "$DB" pg_isready -q -h 127.0.0.1 -U postgres 2> /dev/null; then ready=1; break; fi
  sleep 1
done
[ -n "$ready" ] || { echo "error: PostgreSQL did not become ready" >&2; docker logs "$DB" 2>&1 | tail -20 >&2; exit 1; }

sql() { docker exec -i "$DB" psql -X -q -v ON_ERROR_STOP=1 -h 127.0.0.1 "$@"; }
# As the runtime role. Inside the container the image trusts local
# connections, so no password is involved.
allowed() { sql -U "$1" -d "$2" -c "$3" > /dev/null 2>&1; }

# assert_locked_down <role> <database>: 0 when the role can do DML and is
# refused DDL; otherwise 1, naming what was wrong.
assert_locked_down() {
  local role="$1" db="$2" wrong=0
  for dml in \
    "INSERT INTO widgets (name) VALUES ('a')" \
    "SELECT * FROM widgets" \
    "UPDATE widgets SET name = 'b'" \
    "DELETE FROM widgets"; do
    allowed "$role" "$db" "$dml" || { echo "  [$db] refused, but the app needs it: $dml"; wrong=1; }
  done
  for ddl in \
    "CREATE TABLE smuggled (id int)" \
    "ALTER TABLE widgets ADD COLUMN extra text" \
    "DROP TABLE widgets" \
    "TRUNCATE widgets" \
    "CREATE SCHEMA elsewhere"; do
    if allowed "$role" "$db" "$ddl"; then echo "  [$db] ALLOWED, and must not be: $ddl"; wrong=1; fi
  done
  return "$wrong"
}

sql -U postgres -c "CREATE ROLE app_migrator LOGIN" -c "CREATE ROLE app_runtime LOGIN" -c "CREATE ROLE canary_runtime LOGIN" -c "CREATE DATABASE app OWNER app_migrator" \
  -c "CREATE DATABASE canary OWNER app_migrator"

# The real thing: role script first, table second.
sql -U app_migrator -d app -v runtime=app_runtime -v migrator=app_migrator -f /scripts/runtime-role.sql
sql -U app_migrator -d app -c "CREATE TABLE widgets (id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY, name text)"
# Twice: it must be safe to re-run.
sql -U app_migrator -d app -v runtime=app_runtime -v migrator=app_migrator -f /scripts/runtime-role.sql

if assert_locked_down app_runtime app; then
  echo "runtime role: rows are readable and writable; CREATE, ALTER, DROP and TRUNCATE are refused"
else
  echo "error: scripts/db/runtime-role.sql does not produce a locked-down runtime role" >&2
  exit 1
fi

# The canary: the same script, then the mistakes it exists to prevent.
sql -U app_migrator -d canary -v runtime=canary_runtime -v migrator=app_migrator -f /scripts/runtime-role.sql
sql -U app_migrator -d canary -c "CREATE TABLE widgets (id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY, name text)"
sql -U postgres -d canary -c "GRANT CREATE ON SCHEMA public TO canary_runtime" -c "GRANT CREATE ON DATABASE canary TO canary_runtime" \
  -c "ALTER TABLE widgets OWNER TO canary_runtime"
if assert_locked_down canary_runtime canary > /dev/null; then
  echo "self-test FAILED: a runtime role that owns its table and may CREATE was reported as locked down" >&2
  exit 1
fi
echo "self-test: an over-privileged runtime role was caught"
