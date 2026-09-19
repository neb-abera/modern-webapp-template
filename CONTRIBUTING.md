# Contributing

Thanks for wanting to improve this project. The short version: everything
runs in Docker, everything is tested, and every change goes through a pull
request gated on the verification suite.

## Getting started

The host needs only Docker and git — the toolchain lives in containers.

```bash
make dev      # run the app locally (hot reload)
make verify   # run the full verification suite, exactly as CI does
make contract # after changing an API shape: regenerate openapi.json and the client types
```

`make verify` is the merge gate run locally: the required-checks and
template-parity drift guards, server build and unit tests, client
typecheck/lint/tests, the API contract, held-majors and response-DTO checks,
the database runtime-role check, a production image build and its byte
budget, a smoke test of the running container, the Playwright end-to-end
suite, and a mutation canary. Every checker with a `--self-test` runs it
first, so a checker that can no longer fail is a red check, not a green one.
If it is green on your machine, CI will agree — both run the same
containers.

`make verify` also fails if `server/Api/openapi.json` or
`client/src/api-types.d.ts` is not what the code generates. After changing a
request or response shape, run `make contract` and commit both files.

It also fails when a dependency's next major cannot be taken
(`scripts/check-held-majors.sh`): an npm major that cannot install beside the
rest of its manifest, or a NuGet major that ships no framework the referencing
project can consume. Dependabot only offers a bump the project can take, so
without this check such a pin ages with nothing red. The fix is a manifest of
its own for an npm package (see `tools/api-types/`) or a target framework move
for a NuGet one; a case you accept goes in `.held-majors` with its reason, and
the check tells you when that entry can be dropped.

## Making a change

* Write tests first, from the entry point a user actually hits (an HTTP
  request, a page interaction), not from internals outward. A change in
  behavior needs a test that fails without it.
* A response is a record that lists its fields; never return an entity. An
  entity serializes every column the table ever grows — the email, the
  password hash, the reset token — to whoever asks. `make verify` reads the
  response schemas in `server/Api/openapi.json` and fails on a field named
  like personal or secret data (email, phone, address, zip/postcode, dob,
  ssn, password, token, secret). If clients really need one, list it in
  `server/Api/openapi-pii-allowlist.txt` with the reason; a line without a
  reason fails too.
* Keep pull requests small and single-purpose, and fill in the pull request
  template.
* Nothing merges on a red check. Branch protection requires every PR-gating
  workflow (the verify suite, the workflow/script lint, dependency review,
  CodeQL, the container scan, the ZAP baseline scan), so a failing check is
  the review — fix it rather than working around it.

## Raising a byte budget

`make verify` measures the production client build in gzip bytes — the entry
script, the entry stylesheet, the initial total for `/`, and each prerendered
page — against `client/byte-budget.json`, and fails when any of them is over.
The budget sits 15–20% above what was last measured, so ordinary work fits
and a new dependency does not slip in unnoticed. (`entryCss` is `0` because
the template ships no stylesheet: the first one is a deliberate raise.)

When it fails, the run prints every measurement. In this order:

1. Find what grew — `npx vite build` reports each chunk; a dependency that
   arrived for one function is the usual answer, and the fix is not needing
   it, importing less of it, or loading it lazily off the entry path.
2. If the growth is the feature, raise the number **in the same pull request
   as the code that needs it**, to about 15–20% above the new measurement,
   and say in the description what the bytes bought. A budget raised in a
   pull request of its own has no reason attached, and one raised "to make CI
   green" has the wrong one.
3. Never raise a budget to absorb growth you have not explained.

## Licensing

This project is licensed under Apache-2.0. By contributing you agree that
your contributions are licensed under the same terms (inbound = outbound).
There is no CLA.

## Security issues

Do not open a public issue for a vulnerability — use the private reporting
flow described in [SECURITY.md](SECURITY.md).
