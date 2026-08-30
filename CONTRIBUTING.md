# Contributing

Thanks for wanting to improve this project. The short version: everything
runs in Docker, everything is tested, and every change goes through a pull
request gated on the verification suite.

## Getting started

The host needs only Docker and git — the toolchain lives in containers.

```bash
make dev      # run the app locally (hot reload)
make verify   # run the full verification suite, exactly as CI does
```

`make verify` is the merge gate run locally: server build and unit tests,
client typecheck/lint/tests, a production image build, a smoke test of the
running container, the Playwright end-to-end suite, and a mutation canary.
If it is green on your machine, CI will agree — both run the same
containers.

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
