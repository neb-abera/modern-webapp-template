# Security Policy

## Supported Versions

Only the latest release (and the `main` branch) receives security updates.

## Reporting a Vulnerability

Please report vulnerabilities privately via
[GitHub's private vulnerability reporting](https://github.com/neb-abera/modern-webapp-template/security/advisories/new)
rather than opening a public issue. If you cannot use GitHub's flow, email
<support@alias.abera.tech> instead. Please include a proof of concept or
reproduction steps where possible.

What to expect:

* an acknowledgement within 7 days.
* coordinated disclosure: we ask that you keep the report private until a
  fix is released, and we will credit you in the advisory unless you prefer
  otherwise.
* a fix, or a status update explaining what is taking longer, within 90
  days of the report.

## Hardening in this template

Projects generated from this template ship with:

* security response headers on every response (CSP, `nosniff`,
  `Referrer-Policy`, `Permissions-Policy`) with tests pinning them down.
* rate limiting on every endpoint, partitioned by the real client address
  behind trusted proxies (static files and `/healthz` are not counted), with
  each refusal logged as a security event (below).
* authorization on by default: the fallback policy requires an authenticated
  user on every endpoint that does not declare `AllowAnonymous`, a test
  fails on an endpoint that declares nothing, and 401/403 are logged as
  security events, all before any sign-in exists.
* a host allowlist (`server/Api/HostAllowlist.cs`): only configured `Host`
  names are answered, `/healthz` excepted so platform probes by pod IP work,
  and outside Development the app refuses to start with none configured.
* a settings file with deliberate values: request bodies over 1 MB are
  refused, and authorization failures are not filtered out of the log.
* a distroless-style chiseled production image containing only the published
  app and running as a non-root user. The user is declared (`USER $APP_UID`
  in the Dockerfile) and asserted by the verify suite's smoke check, so a
  base-image change cannot silently revert it to root.
* CodeQL static analysis of the C#, TypeScript and workflow files on every
  pull request and weekly.
* GitHub Actions pinned to full commit SHAs and container base images to
  digests, both kept current by Dependabot (actions, docker, docker-compose,
  nuget and both npm ecosystems, patch/minor bumps grouped per ecosystem),
  with the monthly `dotnet-major-upgrade` workflow covering the cross-major
  .NET jump Dependabot cannot make, and the verify suite's held-majors check
  covering the npm major Dependabot cannot offer because it does not install
  and the NuGet major it cannot offer because no referencing project can
  consume it (accepted cases, with reasons, in [.held-majors](.held-majors)).
* least-privilege workflow tokens (`contents: read` except where releasing
  requires write).
* an end-to-end suite that verifies the security headers reach real browsers.
* continuous vulnerability search beyond static analysis: trivy scans the
  production image for known CVEs and OWASP ZAP baseline-scans the running
  container, on every PR and weekly (`security-scan.yml`). The two accepted
  ZAP findings are documented in [.zap/rules.tsv](.zap/rules.tsv).

## Security event log

Security-relevant refusals are logged under the category `Api.SecurityEvents`
with event ids that never change, so alerts and saved queries can be written
against the number (`server/Api/SecurityEvents.cs`, and a test pins the table).

| EventId | Name | Raised when | Carries |
| --- | --- | --- | --- |
| 1001 | `RateLimitRejected` | a request is refused with 429 | method, route pattern, client address |
| 1002 | `AuthenticationRequired` | a request is refused with 401 | method, route pattern, client address |
| 1003 | `AccessDenied` | an authenticated user is refused with 403 | method, route pattern, client address, user id |
| 1004 | `AntiforgeryRejected` | an antiforgery token is missing or invalid | method, route pattern, client address |
| 1005 | `SignInRefused` | a sign-in attempt is refused | reason (an enum), client address |
| 1006 | `WebhookSignatureRejected` | a webhook's signature does not verify | route pattern, client address |
| 1007 | `HostRejected` | a request's `Host` is not in the allowlist (400) | method, area (`api` or `page`), client address (never the refused `Host` value) |

An event carries the **route pattern** (`/api/notes/{id}`), the **resolved
client address** (`ClientAddress`, the same one the rate limiter keys on, see
[docs/deploying.md](docs/deploying.md)) and an opaque user id where there is
one. It does not carry the path that matched the pattern or the query string.
It never carries a header, cookie, body, token, email address or name. A test
sends all of those and asserts none reaches the log.

1001–1003 and 1007 fire in the template as shipped. 1004–1006 are named slots:
the first code that signs a user in, accepts a webhook or posts a form calls
the matching method ([docs/manual-setup.md](docs/manual-setup.md) says
where), so the numbers are already stable when the first alert is written.

GitHub does not inherit repo-level settings from templates (secret scanning +
push protection, private vulnerability reporting, Dependabot alerts and
security updates, branch protection requiring every PR-gating check:
`verify`, the workflow/script lint, dependency review, CodeQL, trivy and
ZAP). Running
[`./scripts/setup.sh`](scripts/setup.sh) once on a generated repository
enables all of them. `scripts/check-required-contexts.sh` (part of `make
verify`) fails the suite if that required list and the workflows ever drift
apart.
