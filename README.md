[![CI](https://github.com/neb-abera/modern-webapp-template/workflows/CI/badge.svg)](https://github.com/neb-abera/modern-webapp-template/actions)
[![codecov](https://codecov.io/gh/neb-abera/modern-webapp-template/graph/badge.svg)](https://codecov.io/gh/neb-abera/modern-webapp-template)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/neb-abera/modern-webapp-template/badge)](https://scorecard.dev/viewer/?uri=github.com/neb-abera/modern-webapp-template)

# Modern Web App Template

A starting point for web applications: .NET 10 minimal API, React 19,
TypeScript, Vite 8. Everything runs in Docker. One verification suite gates
every change, and CI runs the same script.

## Features

* **Docker-first.** The host needs Docker and git. `make dev` runs
  hot-reloading client and server containers. `make shell` opens a toolchain
  shell. The production image is a chiseled .NET image, non-root, serving
  the API and the built client from one container.

* **Test-driven.** xUnit v3 API tests, Vitest and Testing Library component
  tests, and a Playwright suite that runs against the production image.

* **A threat model.** [docs/threat-model.md](docs/threat-model.md) names
  the assets, the entry points and every threat with the gate that answers
  it. A project copies it, fills in its own rows, and reviews it with each
  release. A new entry point is a row there before it is a feature.

* **Property tests, with fast-check.** `client/tests/App.property.test.tsx`
  states one property of the page over generated input and runs in the same
  Vitest pass as everything else. It is the harness a project copies for its
  own parsers: anything that reads untrusted bytes gets a property here,
  the way the C++ and Rust templates give it a libFuzzer or cargo-fuzz
  target. Seeded, bounded, and a failing run prints the seed and the
  shrunk input.

* **One verification suite.** `make verify` runs every check with a
  pass/fail tally. CI runs the same script. Each checker plants the defect it
  exists to catch on every run, so a checker that can no longer fail is
  caught. The list is at the top of [scripts/verify.sh](scripts/verify.sh).

* **A generated API contract.** The server emits `server/Api/openapi.json`
  at build time. The client's types in `client/src/api-types.d.ts` are
  generated from it (`make contract`). The suite regenerates both and fails
  on drift.

* **Observability.** OpenTelemetry traces and metrics on every request,
  exported over OTLP when `OTEL_EXPORTER_OTLP_ENDPOINT` is set. ReadyToRun
  publishing and a k6 load harness (`make load`). See
  [docs/performance.md](docs/performance.md).

* **Delivery.** Responses are compressed. Hashed assets are served
  `immutable`, the document `no-cache`, and static responses carry no
  cookies. The e2e suite pins all of it.

* **Prerendered first paint.** Routes listed in
  `client/src/prerenderedRoutes.ts` are baked to HTML at build time
  (`client/tools/prerender.mjs`, `src/entry-server.tsx`) and hydrated in the
  browser. Routes with live data stay client-rendered from `spa.html`. The
  server maps extensionless URLs to the baked files (`PrerenderedPages`),
  pipeline tests pin the middleware order, and an e2e test loads the home
  page with JavaScript off. Adding a page to the baked set is one line
  ([docs/manual-setup.md](docs/manual-setup.md)).

* **Security.** CSP and companion headers, with tests. Rate limiting on
  every endpoint, keyed on the client address behind a configured number of
  trusted proxies, with static files and `/healthz` uncounted.
  Authorization required by default, with a test that fails on an endpoint
  that does not declare who may call it. A host allowlist that exempts the
  health route and refuses to start outside Development without one. A 1 MB
  request body limit. A security event log with stable ids and no headers,
  bodies or PII. `/healthz` and `/api` answers are `no-store`, so no edge
  or browser can hold one. `/.well-known/security.txt` and `robots.txt`
  are served from the first deploy. `UrlAllowlist` and `WebhookSignature` helpers, tested.
  Non-root containers, CodeQL (C#, TypeScript, workflows) on every PR,
  SHA-pinned actions, digest-pinned images, least-privilege tokens.
  [SECURITY.md](SECURITY.md) has the inventory.

* **A byte budget.** The production client build is measured in gzip bytes
  (entry script, entry stylesheet, initial total for `/`, each prerendered
  page) against `client/byte-budget.json`. Bytes, so the gate reads the same
  on every machine. Images must declare their dimensions (a Biome rule,
  itself tested).

* **A database extension point.** No data layer ships. `--migrate` runs as
  its own deploy step with `MIGRATE_ON_BOOT` off, PostgreSQL waits behind a
  compose profile pinned by digest, and the serving role is proven on every
  run unable to `CREATE`, `ALTER` or `DROP`.

* **Prose is linted, on the pages too.** `make prose` runs Vale with the
  rules in `.vale/styles/Abera` over every Markdown file, then over the
  prerendered HTML the image ships, as a reader is given it. Check 3 of the
  suite.

* **Toolchain.** .NET 10, React 19, Vite 8, Vitest 4, TypeScript 7,
  Biome 2, Playwright, Node 26.

* **Kept current by Dependabot** on every ecosystem (both npm manifests,
  NuGet, Docker, compose, Actions), patch and minor grouped into one PR per
  ecosystem, pinned digests updated with the tags. The
  `dependabot-automerge` workflow arms auto-merge on every Dependabot PR,
  majors included, once the repository enables Allow auto-merge and holds a
  `DEPENDABOT_AUTOMERGE_TOKEN` secret (a fine-grained PAT with contents and
  pull-requests write, so the merge still triggers CI and deploys). A major
  that passes merges itself. One that breaks stays open and red. The monthly
  `dotnet-major-upgrade` workflow opens the PR for the next GA .NET major
  (close and reopen it to trigger CI). Scripts derive toolchain versions from
  the Dockerfile and `e2e/package.json`.
  The newest GA major of .NET and Node arrives, LTS or not.
  `scripts/check-newest-majors.sh` in the lint job fails when Dependabot
  holds one back, and when a site is 45 days behind it.

* **Releases from tags.** Pushing `v*` re-verifies, publishes the image to
  GHCR and creates a GitHub Release.

* **Generic by construction.** Docker names derive from the checkout
  directory and release names from the repository.

## Getting started

Generate a repository from this template on GitHub, clone it, then:

```bash
make ports      # which host ports this copy of the repository uses
make dev        # hot-reloading dev servers
```

`make ports` first. Container names come from the checkout directory and
the published ports from a `.env` derived from it, so two worktrees or two
clones run side by side. The main checkout keeps :5173 and :8080. Override
for one run with `APP_PORT=9001 make run`, or edit the `.env` the first
`make` writes.

```bash
make verify     # the full verification suite (what CI runs)
```

```bash
make run        # the production image; `make ports` says where
```

`make help` lists the rest (`shell`, `prose`, `test-server`, `test-client`,
`clean`).

### Prerequisites

* **Docker**, from [docker.com](https://www.docker.com/)
* **git**

The .NET SDK, Node, Playwright browsers and all analysis tools run in
containers.

## Project layout

```
server/           .NET 10 minimal API (Api/) and its xUnit v3 tests (Api.Tests/)
client/           React 19 + TypeScript + Vite app, Vitest tests, Biome config
e2e/              Playwright suite, run against the production container
tools/api-types/  openapi-typescript and the TypeScript 5 it needs, in a manifest of their own
scripts/          verify.sh, the suite CI and `make verify` share, and the checkers it runs
                  (check-*.sh, db/), each with its own negative test
.vale/            the writing rules (styles/Abera) and their self-test fixtures
Dockerfile        client build, server build, dev toolchain, prose linter and runtime stages
compose.yaml      `app` (production-like) plus a hot-reloading `dev` profile
.github/          CI, CodeQL and release workflows (SHA-pinned), Dependabot
```

## Development workflow

1. Write a failing test in the layer that owns the behavior (server, client
   or e2e).
2. `make dev` and implement until the test passes.
3. `make verify` before pushing. CI runs the identical suite.
4. When a milestone works, tag it (`git tag v1.2.0 && git push origin
   v1.2.0`) to publish an image and a release.

### Adding a database

`docker compose --profile db up -d db` starts PostgreSQL 18, digest-pinned in
[`compose.yaml`](compose.yaml). `DB_PORT` in `.env` says where. Every
dependency runs in a container. `--migrate` is a separate deploy step,
`MIGRATE_ON_BOOT` is off, and the runtime database role is proven unable to
change the schema.
[docs/manual-setup.md](docs/manual-setup.md#8-the-day-you-add-a-database)
has the data-layer defaults to adopt with it.

## Where the practices come from

Each source below is wired to a failing check.

* **OWASP Top 10 / ASVS, broken access control.** Authorization is the
  fallback policy. `EveryEndpointDeclaresWhoMayCallIt` fails on an
  undeclared endpoint. A "user B is refused user A's object" test helper is
  there for the first owned object.
* **OWASP API Security, excessive data exposure.** Responses are records
  that list their fields. The response-DTO check reads `openapi.json` and
  fails on a PII-named field without an allowlisted reason.
* **OWASP Secure Headers and Cheat Sheets.** The header table tests, host
  filtering, the 1 MB body limit, cookie-free static responses, and the
  `UrlAllowlist` and constant-time `WebhookSignature` helpers with their
  failure cases tested.
* **OWASP Logging Cheat Sheet.** The security event table with stable ids,
  and a test that sends credentials and asserts none reaches the log.
* **Least privilege (CIS PostgreSQL benchmark).** The runtime database
  role, refused DDL against a real PostgreSQL. Migrations as a separate step
  under a separate role.
* **Web performance budgets (web.dev).** The byte budget, image dimensions
  enforced by the linter, compression and immutable caching pinned by the
  e2e delivery suite.
* **OpenSSF supply-chain guidance.** SHA-pinned actions, digest-pinned
  images, locked restores, Dependabot on every ecosystem, Scorecard, CodeQL,
  trivy and ZAP on every PR, and the held-majors check for the bump
  Dependabot stays silent about: an npm major that cannot install beside its
  manifest, or a NuGet major that ships no framework the project can
  consume. The C++ and Rust templates have no counterpart. Cargo has no peer
  ranges, so a held major there fails red, and CMake dependencies have no
  Dependabot ecosystem.

Naming, small functions and honest tests are what the mutation canary, the
test-first workflow and code review are for.

## After generating from this template

One command renames the app after your repository and enables the
repository settings templates cannot carry over: secret scanning, push
protection, private vulnerability reporting, Dependabot alerts and security
updates, and branch protection requiring every PR-gating check (`verify`,
the workflow and script lint, dependency review, CodeQL, the trivy container
scan and the ZAP baseline scan).

```bash
./scripts/setup.sh
```

It needs the [GitHub CLI](https://cli.github.com) authenticated as a repo
admin, and it is safe to re-run. Release and image names follow your
repository. Docker names follow your directory.

The coverage badge shows "unknown" until you add a `CODECOV_TOKEN`
repository secret from [codecov.io](https://about.codecov.io/). Codecov is
dashboard-only. The blocking coverage floors are in the verify suite.

What machinery cannot do for you (the automerge token, cloud credentials,
the app's hostnames and proxy count, Cloudflare cache rules, the prerender
route list, and what to adopt on the day you add sign-in, a database or a
webhook) is in [docs/manual-setup.md](docs/manual-setup.md). Each entry says
why it is manual.

## Deploying

An Azure Container Apps pipeline ships as
[`deploy.yml.example`](.github/workflows/deploy.yml.example): deploys gated
on green CI, secretless OIDC login, immutable image tags, and a post-deploy
health gate. [`docs/deploying.md`](docs/deploying.md) has the one-time setup
and the reasoning, host-agnostic.

## License

[Apache License 2.0](https://www.apache.org/licenses/LICENSE-2.0). See
[LICENSE](LICENSE), and keep the [NOTICE](NOTICE) attribution with any
copies.
