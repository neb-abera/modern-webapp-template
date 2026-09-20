# Fixture: clean prose

scripts/check-prose.sh --self-test runs the rules over this file and fails if
any of them fires. Prose in the target style produces no alerts.

The build runs in a container. The host needs Docker and git.

`make verify` runs the suite CI runs. It took 6 minutes on a 4-core laptop.

The cold start fell from 4.1 s to 2.0 s after ReadyToRun publishing. The
image grew by 30 MB.
