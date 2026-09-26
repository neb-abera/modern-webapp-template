# Performance

## Seeing before guessing

The server ships with OpenTelemetry traces and metrics for every request and
outgoing call. They activate when the standard `OTEL_EXPORTER_OTLP_ENDPOINT`
variable is set (Azure Container Apps and every collector understand OTLP).
Unset, the instrumentation is silent. Measure before changing.

## Cold starts

The production image publishes with **ReadyToRun**, which precompiles IL and
cuts cold-start time when scaling from zero. The next step, if your
dependencies allow it, is **Native AOT** (`<PublishAot>true</PublishAot>`
plus removing anything reflection-heavy): faster startup and lower memory, at
the cost of constraining library choices. That is why it is a documented
option here rather than the template default.

## Load harness

`make load` runs a k6 baseline against the production-like container: enough
traffic to surface gross regressions (a lost cache header, an accidental
N+1), with thresholds on error rate and p95 latency. Run it on quiet
hardware and tune `load/smoke.js` to your app's real endpoints.

`make verify` runs the same script with `LOAD_PROFILE=smoke`: one user,
three passes, and thresholds on checks and failed requests only. That gate
proves the harness still builds, runs and reaches the app. It never judges
latency, because shared runners make load numbers noise.

## Delivery

Compression, immutable hashed-asset caching, and the e2e tests pinning both
are covered in the delivery test suite (`e2e/delivery.spec.ts`).

### Static responses carry no cookies

The document, the prerendered pages, the SPA shell and everything under
`/assets` are identical for every visitor, which is what lets a CDN serve
them. One `Set-Cookie` header ends that: the edge stops caching the response
(or caches one visitor's cookie for everyone), and the browser starts sending
the cookie back with every asset request. Session, antiforgery or
authentication middleware added to the whole pipeline issues its cookie on
the first response, whatever that response is.

So those mount **under `/api` only**: scope them with
`app.UseWhen(context => context.Request.Path.StartsWithSegments("/api"), api => api.UseSession())`
(or a route group), and never call them above `UseStaticFiles`. A server test
(`StaticResponsesSetNoCookies`) and an e2e test (`the document and hashed
assets set no cookies`) fail the day a static response sets one.


## Images

The template's one image (`client/src/App.tsx`) carries the conventions, and
the lint enforces the first of them:

- **`width` and `height` on every `<img>`.** Biome's
  `correctness/useImageSize` fails `npm run lint` without them, and
  `client/tests/image-rule.test.ts` proves the rule is on. The browser
  reserves the box before the file arrives, so the page does not jump
  (cumulative layout shift). CSS may still resize it. The attributes give the
  aspect ratio.
- **`decoding="async"`** always.
- By position, one of: nothing for a small image above the fold,
  **`loading="lazy"`** for anything below it, or **`fetchPriority="high"`**
  for the single largest image of the first screen (never together with
  `lazy`).
- Imported images are emitted under `/assets` with a content hash (immutable
  caching applies) and are **never inlined as `data:` URIs**
  (`assetsInlineLimit: 0` in `vite.config.ts`): the Content-Security-Policy
  refuses `data:` images, so an inlined icon would build and then not render.
- **`preconnect` only to an origin the first screen needs**, and only
  once there is one: `<link rel="preconnect" href="https://images.example.com" crossorigin>`
  in `client/index.html`'s `<head>`, for a host that is also in
  `UrlAllowlist__Hosts` (which is what puts it in the CSP's `img-src`). Each
  preconnect costs a TLS handshake on every visit. One for an origin used
  below the fold is a net loss. The template has no external origin, so
  `index.html` has none.
