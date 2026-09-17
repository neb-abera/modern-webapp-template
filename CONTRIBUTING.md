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

`make verify` is the merge gate run locally: server build and unit tests,
client typecheck/lint/tests, a production image build, a smoke test of the
running container, the Playwright end-to-end suite, and a mutation canary.
If it is green on your machine, CI will agree — both run the same
containers.

`make verify` also fails if `server/Api/openapi.json` or
`client/src/api-types.d.ts` is not what the code generates. After changing a
request or response shape, run `make contract` and commit both files.

It also fails when a dependency's next major cannot install beside the rest of
its manifest (`scripts/check-held-majors.sh`). Dependabot only opens a pull
request for a bump that installs, so without this check such a pin ages with
nothing red. The fix is a manifest of its own for the package (see
`tools/api-types/`); a case you accept goes in `.held-majors` with its reason,
and the check tells you when that entry can be dropped.

## Making a change

* Write tests first, from the entry point a user actually hits (an HTTP
  request, a page interaction), not from internals outward. A change in
  behavior needs a test that fails without it.
* Keep pull requests small and single-purpose, and fill in the pull request
  template.
* Nothing merges on a red check. Branch protection requires every PR-gating
  workflow (the verify suite, the workflow/script lint, dependency review,
  CodeQL, the container scan, the ZAP baseline scan), so a failing check is
  the review — fix it rather than working around it.

## Licensing

This project is licensed under Apache-2.0. By contributing you agree that
your contributions are licensed under the same terms (inbound = outbound).
There is no CLA.

## Security issues

Do not open a public issue for a vulnerability — use the private reporting
flow described in [SECURITY.md](SECURITY.md).
