# Deploying

This template does not assume a host, but it ships a proven pipeline shape for
**Azure Container Apps** — the pattern running aberaTech and Facewoof in
production — as [`deploy.yml.example`](../.github/workflows/deploy.yml.example).
To use it: complete the one-time Azure setup below, rename the file to
`deploy.yml`, and set the repository variables/secrets it names. Every rule in
it was learned the hard way; keep them if you adapt it to another host.

## The rules the pipeline encodes

1. **Deploys are gated on the checks.** The workflow triggers on
   `workflow_run` of CI, and filters on
   `workflow_run.conclusion == 'success'` — `workflow_run` fires whether or
   not the checks passed, so a failed run must be filtered out rather than
   assumed away. `workflow_dispatch` stays available for redeploying the
   current main without a new commit.

2. **One deploy at a time, never cancelled mid-flight**
   (`concurrency: deploy-production, cancel-in-progress: false`).

3. **Secretless via OIDC.** `azure/login` exchanges the workflow's OIDC token
   for credentials; no client secret exists anywhere. When creating the
   federated credential, register **both** subject formats —
   `repo:<owner>/<repo>:ref:refs/heads/main` **and**
   `repo:<owner>/<repo>:environment:production` — deploys fail with only one,
   and the error does not say why.

4. **Build on the runner, push with a narrow grant.** `az acr build` schedules
   a task inside the registry and needs Contributor-level rights on it;
   building on the runner and pushing keeps the deploy identity at
   AcrPush + Reader.

5. **Deploy by immutable tag** (`:$GITHUB_SHA`), not `:latest`, so a revision
   names exactly what it runs and rollback is redeploying a previous SHA.

6. **Gate on post-deploy health.** `az containerapp update` returns when the
   revision is *created*, not when it is *serving* — without polling
   `/healthz` on the public FQDN afterwards, a broken deploy looks green.

7. **Give the app time to drain.** On every revision swap the old container
   gets SIGTERM, then SIGKILL when the grace period runs out. The app's
   shutdown timeout is 8 seconds (`HostOptions.ShutdownTimeout` in
   `Program.cs`, pinned by a test) — chosen to fit inside Docker's 10-second
   default, the tightest window it runs under. Azure Container Apps defaults
   `terminationGracePeriodSeconds` to 30; if you set it explicitly, keep it
   above 10 so the drain window never shrinks below what the app expects.

8. **If a CDN caches your responses** (e.g. Cloudflare in front of the app),
   the cache rule and the purge job in the pipeline only work as a set: a
   cache rule without a purge on deploy serves stale pages, and neither half
   is useful alone. The example ships a `purge-edge-cache` job that reads
   `CLOUDFLARE_ZONE_ID` and `CLOUDFLARE_PURGE_TOKEN` secrets (a token scoped
   to *Zone → Cache Purge* only) and skips with a warning until they exist —
   so it is safe before Cloudflare is configured and correct after.

## Behind a proxy: whose address is it?

The rate limiter gives each client its own bucket, and the security log names
the client that was refused. Behind a CDN and a cloud ingress the socket peer
is the ingress, for every visitor — so unless the app is told how many proxies
stand in front of it, all visitors share one bucket and one burst locks
everyone out. `server/Api/ClientAddress.cs` is the single place the client
address is resolved; it is configured with one number:

| Setting (environment variable) | Value | When |
| --- | --- | --- |
| `ForwardedHeaders__TrustedHops` | `0` (default) | Nothing in front of the app: the socket peer is the client, `X-Forwarded-For` is ignored. Local runs, tests, CI. |
| | `1` | One proxy (a cloud ingress or load balancer). |
| | `2` | **Cloudflare → cloud ingress → app**, the shape this template's production estate runs. |
| `ForwardedHeaders__KnownProxies__0`, `…__1` | IP addresses | Optional second lock: a hop is honoured only when the address reporting it is listed. |
| `ForwardedHeaders__KnownNetworks__0`, `…__1` | CIDR ranges | The same, for ranges (the CDN's published ranges, the ingress subnet). |

The number is the count of proxies **you operate or contract**, not the number
of entries in the header. Each proxy appends the peer it saw, so with two
trusted hops the second entry from the right was written by infrastructure;
anything further left is whatever the client chose to send, and is ignored. Set
it too low and visitors share a bucket; set it too high and a client chooses
its own bucket by writing the header itself.

Hop counting is only sound while **the origin accepts traffic from the proxy
chain and nothing else**. Lock the container app's ingress to the CDN's
published ranges (Cloudflare: <https://www.cloudflare.com/ips/>; Azure
Container Apps: ingress IP restrictions, allow-list mode). With the origin
open, anyone who finds its hostname connects with one hop fewer than you
counted and their forged entry lands exactly where the app looks. If you cannot
lock the origin, set `KnownNetworks` — a forged chain from an unlisted peer is
then refused rather than believed.

```bash
az containerapp update --name "$CONTAINER_APP" --resource-group "$RESOURCE_GROUP" \
  --set-env-vars ForwardedHeaders__TrustedHops=2
```

IPv6 clients are bucketed per /64, the unit an ISP hands one subscriber.

## Configuration that reaches the browser

Client-side configuration (`import.meta.env.VITE_*`) is resolved when the
bundle is **built**, so it must be passed as build args to `docker build` in
the deploy — setting it on the running container does nothing. Values that
ship in the bundle are visible to every browser by design: store them as
repository *variables*, never secrets, and make the app degrade gracefully
when they are unset so the deploy stays safe before they are configured.

## Databases

Run migrations from the production image (the same code path production
uses), and make the on-startup migration a no-op when everything is already
applied — CI should exercise both, against a real database service.
