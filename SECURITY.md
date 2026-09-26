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
  with the monthly `dotnet-major-upgrade` workflow covering the jump to the
  next LTS .NET major that Dependabot cannot make, ignore ranges holding back
  every .NET and Node major that is not LTS (`scripts/check-lts-majors.sh`),
  and the verify suite's held-majors check
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

## Standards this template is checked against

The hardening above is the machinery. A project made from this template
carries a table like the one below in its own `SECURITY.md`, naming for
each published control the gate that answers it, so a reviewer with the
standard in hand can find the evidence, and so a control with no
machinery is written down as a deviation rather than forgotten. The
application standard is DISA's Application Security and Development STIG
(V6R4, 2025-09-09). Identity controls are NIST SP 800-63B. Supply chain is
NIST SP 800-218 (SSDF) and the OpenSSF Scorecard checks.

| Control | Requirement | Here | Evidence |
|---|---|---|---|
| ASD V-222425 | Enforce approved authorizations | Met | Fallback policy denies by default. A test fails the build on an endpoint that declares nothing (`AuthorizationTests`) |
| ASD V-222430 | Execute without excessive permissions | Met | Non-root chiseled image. The runtime database role has DML only and a test proves DDL is refused (verify check 9) |
| ASD V-222441 to V-222449, V-222462 | Audit refusals with time, source address and outcome | Met | Security events 1001 to 1007 (below), with the resolved client address |
| ASD V-222444 | No sensitive data in logs | Met | Events carry no path, query, header, cookie or account. Tests assert what is omitted |
| ASD V-222594, V-222667 | Restrict denial of service | Met | Rate limits on every endpoint, partitioned by the real client address. Body limits |
| ASD V-222602 | Protect from XSS | Met | React escaping. CSP with no `unsafe-inline` for scripts. The property test above shows arbitrary API text renders as text |
| ASD V-222606, V-222609 | Validate all input. No input-handling vulnerabilities | Partly met | Typed DTOs and body limits. The fast-check harness is where a project's parsers get their properties |
| ASD V-222614, V-222658 | Patches current, products supported | Met | Dependabot on every ecosystem, auto-merge for non-majors, the held-majors gate (verify check 7) |
| ASD V-222645 | Application files hashed before deployment | Met | Build provenance attestation and SBOM on every release |
| ASD V-222648 | Code review | Met | Every change is a pull request with CodeQL, Trivy, ZAP, dependency review and Scorecard |
| ASD V-222575 to V-222583 | Session cookie protections | Prescribed | No sign-in ships. `docs/manual-setup.md` §7 prescribes `__Host-`, `Secure`, `HttpOnly`, `SameSite` and key-ring persistence on the day one is added |
| ASD V-222655 | Threat model per release | Met | `docs/threat-model.md`: assets, entry points, trust boundaries, each threat with its answer and the gate that holds it. A project copies it and reviews it with every release |
| SP 800-218 PW.4, PW.7, PW.8 | Reuse well-secured components, review code, test executable code | Met | Pinned images and actions, locked restores, the verify checks with planted defects |

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
enables all of them. The required list is `.github/required-checks`.
`scripts/check-required-contexts.sh` (part of `make verify`) fails the suite
when that list and the workflows disagree.
