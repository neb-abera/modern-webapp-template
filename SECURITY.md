# Security Policy

## Supported Versions

Only the latest release (and the `main` branch) receives security updates.

## Reporting a Vulnerability

Please report vulnerabilities privately via
[GitHub's private vulnerability reporting](../../security/advisories/new)
rather than opening a public issue. You should receive a response within a
week. Please include a proof of concept or reproduction steps where possible.

## Hardening in this template

Projects generated from this template ship with:

* security response headers on every response (CSP, `nosniff`,
  `Referrer-Policy`, `Permissions-Policy`) with tests pinning them down,
* IP-partitioned rate limiting on the API,
* a distroless-style chiseled production image running as a non-root user,
  containing only the published app,
* CodeQL static analysis of the C#, TypeScript and workflow files on every
  pull request and weekly,
* GitHub Actions pinned to full commit SHAs, kept current by Dependabot
  (actions, docker, nuget and npm ecosystems),
* least-privilege workflow tokens (`contents: read` except where releasing
  requires write),
* an end-to-end suite that verifies the security headers reach real browsers.

Repo-level settings to enable on generated repositories (GitHub does not
inherit them from templates): secret scanning + push protection, private
vulnerability reporting, Dependabot alerts and security updates, and branch
protection requiring the `verify` and CodeQL checks.
