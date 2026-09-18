[![CI](https://github.com/neb-abera/modern-webapp-template/workflows/CI/badge.svg)](https://github.com/neb-abera/modern-webapp-template/actions)
[![codecov](https://codecov.io/gh/neb-abera/modern-webapp-template/graph/badge.svg)](https://codecov.io/gh/neb-abera/modern-webapp-template)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/neb-abera/modern-webapp-template/badge)](https://scorecard.dev/viewer/?uri=github.com/neb-abera/modern-webapp-template)

# Modern Web App Template

A production-shaped starting point for web applications: **.NET 10 minimal
API** + **React 19** + **TypeScript** + **Vite 8**, developed entirely in
Docker, gated by a test-driven verification suite, and secured by default.

## Features

* **Docker-first development** — the host needs only Docker and git. `make
  dev` gives hot-reloading client and server containers; `make shell` opens a
  toolchain shell; the production image is a distroless-style chiseled .NET
  image running as a non-root user, serving the API and the built client from
  one container,

* **Test-driven by default** — xUnit v3 API tests (including table-driven
  security-header contracts), Vitest + Testing Library component tests,
  and a Playwright end-to-end suite that runs against the *production image*,
  not a dev server,

* **One verification suite everywhere** — `make verify` runs twelve checks
  with a running pass/fail tally: a drift guard proving branch protection
  requires every PR-gating check, server build+tests with a line-coverage
  gate (warnings as errors), client typecheck+lint+tests with coverage
  thresholds, an OpenAPI contract check proving the committed spec and the
  generated client types match the code, a held-majors check that fails when
  an npm or NuGet dependency's next major cannot be taken (the one case
  Dependabot stays silent about), a response-DTO check (no field named like personal or secret
  data leaves the API unlisted), a database runtime-role check against a real
  PostgreSQL, production image build, a byte budget on that image's client
  build, container smoke test (which also asserts the image runs as a
  non-root uid), e2e, and a mutation canary proving the tests catch planted
  bugs. Every checker that was added proves on each run that it can fail, by
  planting the defect it exists to catch. CI runs exactly the same script, so
  green locally means green in CI,

* **A mechanized API contract** — the server emits its OpenAPI document at
  build time (`server/Api/openapi.json`), the client's response types are
  generated from it (`client/src/api-types.d.ts`; `make contract`
  regenerates both), and the verify suite regenerates both and fails on
  any drift — a hand-written client type that silently diverges from the
  server cannot exist here,

* **Observability by default** — OpenTelemetry traces and metrics on every
  request, exported over OTLP when `OTEL_EXPORTER_OTLP_ENDPOINT` is set and
  silent otherwise; ReadyToRun publishing for cold starts and a k6 load
  harness (`make load`) round out [docs/performance.md](docs/performance.md),

* **Delivery performance by default** — responses are compressed, Vite's
  content-hashed assets are served `immutable` while the document stays
  `no-cache`, and the e2e suite pins all of it, because an uncompressed
  bundle or a cached document is a regression nothing else notices,

* **Prerendered first paint** — the routes listed in
  `client/src/prerenderedRoutes.ts` are baked to real HTML at build time
  (`client/tools/prerender.mjs` + `src/entry-server.tsx`) and hydrated in
  the browser, so first paint does not wait for the React bundle; routes
  that show live data stay client-rendered from the empty `spa.html`
  fallback. The server maps extensionless URLs to their baked files
  (`PrerenderedPages`), pipeline tests pin the middleware order that makes
  it work, and an e2e test proves the home page renders with JavaScript
  disabled. Adding a static page to the baked set is one line — see
  [docs/manual-setup.md](docs/manual-setup.md),

* **Security by default** — CSP and companion response headers with tests
  pinning them; rate limiting on every endpoint, keyed on the real client
  address behind a configured number of trusted proxies, with static files
  and `/healthz` left uncounted; authorization required by default, before
  any sign-in exists, with a test that fails on an endpoint that does not
  declare who may call it; a host allowlist that answers only configured host
  names (health route excepted, and no start outside Development without
  one) and a settings file with deliberate values (1 MB request bodies); a security event log
  with stable ids that never carries headers, bodies or PII; small tested
  helpers (`UrlAllowlist`, `WebhookSignature`) so the first stored URL or
  webhook is not hand-rolled; non-root containers, CodeQL (C#, TypeScript,
  workflows) on every PR, GitHub Actions pinned to commit SHAs and base
  images to digests, least-privilege workflow tokens, and a SECURITY.md (see
  it for the full inventory),

* **A byte budget** — the production client build is measured in gzip bytes
  (entry script, entry stylesheet, initial total for `/`, each prerendered
  page) against `client/byte-budget.json`; bytes, never timing, so the gate
  reads the same everywhere. Images must declare their dimensions (a Biome
  rule, itself tested), and static responses are pinned cookie-free so a CDN
  can keep serving them,

* **A database extension point that is machinery** — no data layer ships,
  but `--migrate` already runs as its own deploy step with `MIGRATE_ON_BOOT`
  off, PostgreSQL waits behind a compose profile pinned by digest, and the
  serving app's database role is proven on every run to be unable to
  `CREATE`, `ALTER` or `DROP`,

* **Cutting-edge, not bleeding-edge toolchain** — .NET 10 LTS, React 19,
  Vite 8, Vitest 4, TypeScript 7, Biome 2 (one fast linter+formatter instead
  of ESLint+Prettier), Playwright, Node 26,

* **…and it stays current by machinery, not memory** — Dependabot watches
  every ecosystem (both npm manifests, NuGet, Docker, compose, Actions),
  with patch/minor bumps grouped into one PR per ecosystem and the pinned
  digests updated alongside the tags. Those grouped PRs merge themselves
  when CI is green: the `dependabot-automerge` workflow arms GitHub
  auto-merge on every Dependabot PR — majors included — once the repository
  enables its Allow auto-merge setting and holds a
  `DEPENDABOT_AUTOMERGE_TOKEN` secret (a fine-grained PAT with contents and
  pull-requests write — a PAT so the merge still triggers CI and deploys,
  which `GITHUB_TOKEN` merges do not). Red CI, not update size, is the
  review signal: a major that passes everything merges itself, and one that
  genuinely breaks stays open and red for a human. The one jump Dependabot
  never makes —
  a new .NET major — is handled by the monthly `dotnet-major-upgrade`
  workflow, which opens a PR moving the TargetFramework, base images and
  framework packages together (close and reopen that PR to trigger CI on
  it; workflow-opened PRs don't start checks on their own). Toolchain
  versions are never repeated in scripts: `verify.sh` derives its images
  from the Dockerfile and `e2e/package.json`, so nothing can drift,

* **Releases from tags** — pushing `v*` re-verifies, publishes the container
  image to GHCR and creates a GitHub Release. Tag confirmed-working
  milestones so rollback points are named,

* **Generic by construction** — Docker names derive from your checkout
  directory and release/image names from your repository, so a generated
  project needs almost no renaming.

## Getting started

Generate a repository from this template on GitHub, clone it, then:

```bash
make ports      # which host ports this copy of the repository uses
make dev        # hot-reloading dev servers
```

`make ports` first, because the answer differs per copy. Container names come
from the checkout directory and the published ports from a `.env` derived from
it, so two worktrees — or two clones — run side by side instead of fighting over
8080, and `make clean` only takes down the one you are standing in. The main
checkout keeps :5173 and :8080. Override for one run with `APP_PORT=9001 make
run`, or edit the `.env` the first `make` writes.

```bash
make verify     # the full verification suite (what CI runs)
```

```bash
make run        # the production image; `make ports` says where
```

`make help` lists everything else (`shell`, `test-server`, `test-client`,
`clean`).

### Prerequisites

* **Docker** - found at [https://www.docker.com/](https://www.docker.com/)
* **git**

Nothing else: the .NET SDK, Node, Playwright browsers and all analysis tools
run inside containers.

## Project layout

```
server/           .NET 10 minimal API (Api/) and its xUnit v3 tests (Api.Tests/)
client/           React 19 + TypeScript + Vite app, Vitest tests, Biome config
e2e/              Playwright suite, run against the production container
tools/api-types/  openapi-typescript and the TypeScript 5 it needs, in a manifest of their own
scripts/          verify.sh — the verification suite CI and `make verify` share — and the
                  checkers it runs (check-*.sh, db/), each with its own negative test
Dockerfile        client build, server build, dev toolchain and runtime stages
compose.yaml      `app` (production-like) plus a hot-reloading `dev` profile
.github/          CI, CodeQL and release workflows (SHA-pinned), Dependabot
```

## Development workflow

1. Write a failing test (server, client or e2e — whichever layer owns the
   behavior).
2. `make dev` and implement until the test passes.
3. `make verify` before pushing — CI runs the identical suite, so a local
   green run predicts the PR gate.
4. When a milestone is confirmed working, tag it (`git tag v1.2.0 && git push
   origin v1.2.0`) to publish an image and a release.

### Adding a database

`docker compose --profile db up -d db` starts PostgreSQL 18 (digest-pinned in
[`compose.yaml`](compose.yaml); `make ports`' sibling `DB_PORT` in `.env` says
where). Keep the pattern: every dependency runs in a container. The
extension points are already machinery — `--migrate` as a separate deploy
step, `MIGRATE_ON_BOOT` off, and a runtime database role proven unable to
change the schema — and
[docs/manual-setup.md](docs/manual-setup.md#8-the-day-you-add-a-database)
has the data-layer defaults to adopt with it.

## Where the practices come from

The canon this template enforces, and the gate that enforces it — advice
that is not a failing check decays, so each source is wired to one:

* **OWASP Top 10 / ASVS: broken access control** — authorization is the
  fallback policy, `EveryEndpointDeclaresWhoMayCallIt` fails on an undeclared
  endpoint, and the "user B is refused user A's object" test helper is there
  for the first owned object,
* **OWASP API Security: excessive data exposure** — responses are records
  that list their fields; the response-DTO check reads `openapi.json` and
  fails on a PII-named field without an allowlisted reason,
* **OWASP Secure Headers and Cheat Sheets** — the header table tests, host
  filtering, the 1 MB body limit, the cookie-free static responses, and the
  `UrlAllowlist` / constant-time `WebhookSignature` helpers with their
  failure cases tested,
* **OWASP Logging Cheat Sheet** — the security event table with stable ids,
  and a test that sends credentials and asserts none reaches the log,
* **Least privilege (CIS PostgreSQL benchmark)** — the runtime database role,
  proven against a real PostgreSQL to be refused DDL; migrations as a
  separate step under a separate role,
* **Web performance budgets (web.dev)** — the byte budget, image dimensions
  enforced by the linter, compression and immutable caching pinned by the
  e2e delivery suite,
* **OpenSSF supply-chain guidance** — SHA-pinned actions, digest-pinned
  images, locked restores, Dependabot on every ecosystem, Scorecard, CodeQL,
  trivy and ZAP on every PR, and the held-majors check for the one bump
  Dependabot stays silent about: an npm major that cannot install beside its
  manifest, or a NuGet major that ships no framework the project can
  consume. npm and NuGet only; the C++ and Rust templates have no
  counterpart because Cargo has no peer ranges (a major Dependabot offers
  there fails red, not silently) and CMake dependencies have no Dependabot
  ecosystem at all.

What a gate cannot check — naming things well, small functions, honest tests
— is what the mutation canary, the test-first workflow and code review are
for.

## After generating from this template

One command finishes the setup — it renames the app after your repository and
enables the repo-level GitHub settings templates cannot carry over (secret
scanning, push protection, private vulnerability reporting, Dependabot
alerts + security updates, and branch protection requiring every PR-gating
check — `verify`, the workflow/script lint, dependency review, CodeQL, the
trivy container scan and the ZAP baseline scan):

```bash
./scripts/setup.sh
```

It needs the [GitHub CLI](https://cli.github.com) authenticated as a repo
admin, and it is safe to re-run. Everything else adapts automatically:
release/image names follow your repository, Docker names follow your
directory.

The coverage badge shows "unknown" until you add a `CODECOV_TOKEN`
repository secret (from [codecov.io](https://about.codecov.io/) after
enabling your repo there). Codecov is dashboard-only here — the blocking
coverage floors are enforced by the verify suite itself — so this is
optional and nothing fails without it.

The complete list of things machinery cannot do for you — the automerge
token, cloud credentials, the app's hostnames and proxy count, Cloudflare
cache rules, the prerender route list, and what to adopt on the day you add
sign-in, a database or a webhook — lives in [docs/manual-setup.md](docs/manual-setup.md). Work through it once;
each entry says why it is manual.

## Deploying

A production-proven Azure Container Apps pipeline ships as
[`deploy.yml.example`](.github/workflows/deploy.yml.example) — deploys gated
on green CI, secretless OIDC login, immutable image tags, and a post-deploy
health gate. [`docs/deploying.md`](docs/deploying.md) has the one-time setup
and the reasoning, host-agnostic.

## License

This project is licensed under the
[Apache License 2.0](https://www.apache.org/licenses/LICENSE-2.0) — see the
[LICENSE](LICENSE) file. Keep the [NOTICE](NOTICE) file's attribution with
any copies.
