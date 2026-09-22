# Threat model

What the template protects, who it protects it from, and which gate holds
each answer. A project made from this template copies this file and fills
in its own assets and entry points. The application STIG (V-222655) asks
for one per release. Reviewing it is part of every release.

## Assets

- The API and the client it serves, on one origin.
- The database, when a project adds one (`docs/manual-setup.md` §8).
- The container image and the supply chain that builds it.
- The signing keys and secrets the deployment holds.

## Entry points and trust boundaries

| Boundary | What crosses it | Who is on the far side |
|---|---|---|
| Internet to the edge | Every request, over TLS | Anyone |
| Edge to origin | Requests from the edge's address ranges only | The CDN |
| Origin to database | Parameterised queries as the runtime role | The application |
| Repository to registry | Images built by CI from a pull request | GitHub Actions |

Inside the origin, the fallback policy treats every endpoint as owned by a
signed-in caller unless it says otherwise, so a new route starts closed.

## Threats and answers

| Threat | Class | Answer | Gate |
|---|---|---|---|
| A stranger calls an endpoint nobody meant to expose | Elevation | Deny by default. Every endpoint declares its policy or `AllowAnonymous` | `AuthorizationTests` fails the build on one that declares nothing |
| A response carries a field the screen does not show | Disclosure | Responses are DTOs that list their fields | `check-response-pii.sh`, verify check 8 |
| A flood of requests takes the origin down | Denial | Rate limits on every endpoint, keyed by the real client address. Body limits | Tests for the limiter and the address resolution |
| A client-supplied header moves the rate-limit key | Spoofing | The hop count is configuration. The limiter reads the address from one place | A test sends `X-Forwarded-For` and the key does not move |
| A request with a guessed `Host` reaches the app | Spoofing | A host allowlist that exempts `/healthz` | Smoke check 12: unknown `Host` is 400 |
| Script in API text runs in the page | Tampering | React escapes. CSP with no `unsafe-inline` for scripts | The fast-check property: any message renders as text |
| A dependency ships a vulnerability | Tampering | Pinned digests and SHAs, locked restores, Dependabot, Trivy, CodeQL, the held-majors gate | Verify checks 7 and 10. Scanners on every push |
| The build is not what the source says | Tampering | Build provenance attestation and an SBOM on every release | `release.yml` |
| The runtime identity changes the schema | Elevation | The runtime role has DML only | Verify check 9 refuses DDL as that role |
| A refusal goes unnoticed | Repudiation | Events 1001 to 1007 with the client address, never a secret | `SecurityEventTests` assert what each carries and omits |
| A probe is answered by a cache | Denial | `no-store` on probes and `/api`, the edge rule excludes them | The deploy smoke test fails on a HIT |

## Accepted, and why

- No sign-in ships. A project adds one the day it needs it, with the
  cookie defaults in `docs/manual-setup.md` §7.
- The load, fuzz and bench harnesses are smoke gates. Numbers from shared
  runners are noise, so nothing in CI judges a timing.
- Client-side rendering of the app pages needs the script. The public
  pages are prerendered and a test loads them with scripts off.

## When to revisit

A new entry point, a new asset (a database, an upload, a webhook, a
second origin), a new class of caller, or a change to the edge. Each is a
row here before it is a feature.
