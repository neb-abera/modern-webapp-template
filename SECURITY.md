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

* an acknowledgement within 7 days,
* coordinated disclosure: we ask that you keep the report private until a
  fix is released, and we will credit you in the advisory unless you prefer
  otherwise,
* a fix, or a status update explaining what is taking longer, within 90
  days of the report.

## Hardening in this template

Projects generated from this template ship with:

* security response headers on every response (CSP, `nosniff`,
  `Referrer-Policy`, `Permissions-Policy`) with tests pinning them down,
* IP-partitioned rate limiting on the API,
* a distroless-style chiseled production image running as a non-root user —
  declared explicitly (`USER $APP_UID` in the Dockerfile) and asserted by
  the verify suite's smoke check, so a base-image change cannot silently
  revert it to root,
  containing only the published app,
* CodeQL static analysis of the C#, TypeScript and workflow files on every
  pull request and weekly,
* GitHub Actions pinned to full commit SHAs and container base images to
  digests, both kept current by Dependabot (actions, docker, docker-compose,
  nuget and both npm ecosystems, patch/minor bumps grouped per ecosystem),
  with the monthly `dotnet-major-upgrade` workflow covering the cross-major
  .NET jump Dependabot cannot make,
* least-privilege workflow tokens (`contents: read` except where releasing
  requires write),
* an end-to-end suite that verifies the security headers reach real browsers,
* continuous vulnerability search beyond static analysis: trivy scans the
  production image for known CVEs and OWASP ZAP baseline-scans the running
  container, on every PR and weekly (`security-scan.yml`); the two accepted
  ZAP findings are documented in [.zap/rules.tsv](.zap/rules.tsv).

GitHub does not inherit repo-level settings from templates (secret scanning +
push protection, private vulnerability reporting, Dependabot alerts and
security updates, branch protection requiring every PR-gating check —
`verify`, the workflow/script lint, dependency review, CodeQL, trivy and
ZAP). Running
[`./scripts/setup.sh`](scripts/setup.sh) once on a generated repository
enables all of them; `scripts/check-required-contexts.sh` (part of `make
verify`) fails the suite if that required list and the workflows ever drift
apart.
