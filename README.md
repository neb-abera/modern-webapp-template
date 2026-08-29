[![CI](https://github.com/neb-abera/modern-webapp-template/workflows/CI/badge.svg)](https://github.com/neb-abera/modern-webapp-template/actions)

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

* **Delivery performance by default** — responses are compressed, Vite's
  content-hashed assets are served `immutable` while the document stays
  `no-cache`, and the e2e suite pins all of it, because an uncompressed
  bundle or a cached document is a regression nothing else notices,

* **Security by default** — CSP and companion response headers with tests
  pinning them, IP-partitioned rate limiting, non-root containers, CodeQL
  (C#, TypeScript, workflows) on every PR, GitHub Actions pinned to commit
  SHAs, least-privilege workflow tokens, Dependabot across all ecosystems,
  and a SECURITY.md (see it for the full inventory),

* **Cutting-edge, not bleeding-edge toolchain** — .NET 10 LTS, React 19,
  Vite 8, Vitest 4, TypeScript 7, Biome 2 (one fast linter+formatter instead
  of ESLint+Prettier), Playwright, Node 24 LTS,

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

## Deploying

A production-proven Azure Container Apps pipeline ships as
[`deploy.yml.example`](.github/workflows/deploy.yml.example) — deploys gated
on green CI, secretless OIDC login, immutable image tags, and a post-deploy
health gate. [`docs/deploying.md`](docs/deploying.md) has the one-time setup
and the reasoning, host-agnostic.

## License

This project is licensed under the [Unlicense](https://unlicense.org/) - see
the [LICENSE](LICENSE) file for details.
