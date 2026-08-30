[![CI](https://github.com/neb-abera/modern-webapp-template/workflows/CI/badge.svg)](https://github.com/neb-abera/modern-webapp-template/actions)
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

* **One verification suite everywhere** — `make verify` runs six checks with
  a running pass/fail tally: server build+tests (warnings as errors), client
  typecheck+lint+tests, production image build, container smoke test, e2e,
  and a mutation canary proving the tests catch planted bugs. CI runs exactly
  the same script, so green locally means green in CI,

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
  pinning them, IP-partitioned rate limiting, non-root containers, CodeQL
  (C#, TypeScript, workflows) on every PR, GitHub Actions pinned to commit
  SHAs and base images to digests, least-privilege workflow tokens, and a
  SECURITY.md (see it for the full inventory),

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
make dev        # hot-reloading dev servers: client on :5173, API on :8080
```

```bash
make verify     # the full verification suite (what CI runs)
```

```bash
make run        # the production image on :8080
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
scripts/          verify.sh — the verification suite CI and `make verify` share
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

Uncomment the `db` service in [`compose.yaml`](compose.yaml) (PostgreSQL 18)
and add a connection string to the server. Keep the pattern: every dependency
runs in a container.

## After generating from this template

One command finishes the setup — it renames the app after your repository and
enables the repo-level GitHub settings templates cannot carry over (secret
scanning, push protection, private vulnerability reporting, Dependabot
alerts + security updates, and branch protection requiring the `verify` and
CodeQL checks):

```bash
./scripts/setup.sh
```

It needs the [GitHub CLI](https://cli.github.com) authenticated as a repo
admin, and it is safe to re-run. Everything else adapts automatically:
release/image names follow your repository, Docker names follow your
directory.

The complete list of things machinery cannot do for you — the automerge
token, cloud credentials, Cloudflare cache rules, the prerender route list —
lives in [docs/manual-setup.md](docs/manual-setup.md). Work through it once;
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
