# Performance

## Seeing before guessing

The server ships with OpenTelemetry traces and metrics for every request and
outgoing call. They activate when the standard `OTEL_EXPORTER_OTLP_ENDPOINT`
variable is set (Azure Container Apps and every collector understand OTLP);
unset, the instrumentation is silent. Performance work starts here — measure,
then change.

## Cold starts

The production image publishes with **ReadyToRun**, which precompiles IL and
meaningfully cuts cold-start time when scaling from zero. The next step, if
your dependencies allow it, is **Native AOT** (`<PublishAot>true</PublishAot>`
plus removing anything reflection-heavy): much faster startup and lower
memory, at the cost of constraining library choices — which is why it is a
documented option here rather than the template default.

## Load harness

`make load` runs a k6 baseline against the production-like container: enough
traffic to surface gross regressions (a lost cache header, an accidental
N+1), with thresholds on error rate and p95 latency. It is a harness, not a
CI gate — shared runners make load numbers noise; run it on quiet hardware
and tune `load/smoke.js` to your app's real endpoints.

## Delivery

Compression, immutable hashed-asset caching, and the e2e tests pinning both
are covered in the delivery test suite (`e2e/delivery.spec.ts`).
