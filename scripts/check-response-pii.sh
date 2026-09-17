#!/usr/bin/env bash
#
# check-response-pii.sh — response DTO discipline, as a gate.
#
# The defect: an endpoint returns a database entity, and every column the
# table ever grows — email, phone, a password hash, a reset token — is
# serialized to whoever asks. The rule: a response is a record that lists its
# fields. The committed OpenAPI document is what the server actually emits
# (verify.sh's contract check proves that), so this reads its RESPONSE schemas
# and fails on a property named like personal or secret data unless
# server/Api/openapi-pii-allowlist.txt lists it with a reason.
#
# A checker that has never been seen to fail is not a checker, so the same run
# plants three documents and requires the right answer on each:
#   - a response reaching an emailAddress through a nested $ref must FAIL
#   - the same document with that field allowlisted, with a reason, must PASS
#   - the same allowlist line without a reason must FAIL
#
# Runs in the Node image the Dockerfile pins; the host needs only Docker.

set -euo pipefail
cd "$(dirname "$0")/.."

NODE_IMAGE="$(sed -n 's|^FROM \(node:[^ ]*\) AS node-base$|\1|p' Dockerfile)"
[ -n "$NODE_IMAGE" ] || { echo "error: could not derive the Node image from the Dockerfile" >&2; exit 1; }

NAME="$(basename "$PWD" | tr '[:upper:]' '[:lower:]')"

docker run --rm --name "$NAME-check-pii" -v "$PWD":/src:ro "$NODE_IMAGE" sh -c '
  set -eu
  check="node /src/scripts/check-response-pii.mjs"

  $check /src/server/Api/openapi.json /src/server/Api/openapi-pii-allowlist.txt

  mkdir /planted && cd /planted
  cat > leaky.json <<JSON
{"paths":{"/api/users/{id}":{"get":{"responses":{"200":{"content":{"application/json":{"schema":
  {"type":"array","items":{"\$ref":"#/components/schemas/User"}}}}}}}}},
 "components":{"schemas":{
  "User":{"type":"object","properties":{"id":{"type":"string"},"contact":{"\$ref":"#/components/schemas/Contact"}}},
  "Contact":{"type":"object","properties":{"emailAddress":{"type":"string"}}}}}}
JSON
  : > empty.txt
  echo "Contact.emailAddress  shown to the account owner on their own profile" > reasoned.txt
  echo "Contact.emailAddress" > unreasoned.txt

  if $check leaky.json empty.txt 2> out.txt; then
    echo "self-test FAILED: a response exposing Contact.emailAddress passed" >&2; exit 1
  fi
  grep -q "Contact.emailAddress" out.txt || { echo "self-test FAILED: the failure did not name the field" >&2; cat out.txt >&2; exit 1; }
  if ! $check leaky.json reasoned.txt > /dev/null; then
    echo "self-test FAILED: an allowlisted field with a reason was refused" >&2; exit 1
  fi
  if $check leaky.json unreasoned.txt 2> /dev/null; then
    echo "self-test FAILED: an allowlist line without a reason was accepted" >&2; exit 1
  fi
  echo "self-test: planted leak caught, reasoned allowlist honoured, unreasoned allowlist refused"
'
