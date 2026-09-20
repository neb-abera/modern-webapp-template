# Fixture: one violation per rule

scripts/check-prose.sh --self-test runs the rules over this file and fails
unless every rule in .vale/styles/Abera fires at least once. A rule without a
line here is a rule nobody has seen fail.

Dash: the build runs in a container — the host needs only Docker.

Semicolon: the build runs in a container; the host needs only Docker.

Exclamation: the build runs in a container!

Intensifiers: the build is very fast.

Hedges: the build is perhaps fast.

Jargon: we leverage containers in order to build.

Buzzwords: the build is a journey.

Pivot: it is scored on gates, not hours.

Preamble: in this guide we build in a container.

Cliches: under the hood, it builds in a container.

Rhetorical: The result? It builds in a container.
