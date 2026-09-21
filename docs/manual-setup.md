# What the engineer must do by hand

Everything else in this template is machinery. These are the steps machinery
cannot do, either because they need credentials only a human holds or because
they are per-project judgment calls. Work through them once when adopting the
template, in order.

## 1. Repo settings: `./scripts/setup.sh`

Renames the project after your repository and enables the GitHub settings
templates cannot carry over: secret scanning, push protection, private
vulnerability reporting, Dependabot alerts + security updates, and branch
protection requiring the CI checks. Needs the `gh` CLI authenticated as an
admin of the repo.

## 2. Dependency automerge: one setting, one token

- Enable **Settings → General → Allow auto-merge** on the repository.
- Create a fine-grained personal access token
  (github.com/settings/personal-access-tokens): repository access limited to
  this repo (add it to an existing fleet token if you have one), permissions
  **Contents: read/write** and **Pull requests: read/write**. Store it:

  ```bash
  gh secret set DEPENDABOT_AUTOMERGE_TOKEN --repo <owner>/<repo>
  ```

  A PAT rather than `GITHUB_TOKEN` on purpose: merges performed with
  `GITHUB_TOKEN` trigger no workflows, so the default branch would run no CI
  or deploy on the dependency it just took. Until both the setting and the
  secret exist, the automerge workflow warns and does nothing. When the
  token expires (set an expiry, ~90 days), CI on the next Dependabot PR goes
  red. That is the renewal reminder. The token's *repository access list* is
  part of the setup: a token that exists but does not cover this repo fails
  with "Resource not accessible", which reads as red CI on every Dependabot
  PR.

## 3. Deploy: copy `deploy.yml.example` and wire the cloud

- Azure: create the app registration with **OIDC federated credentials**
  (no client secret), with both subject formats, `repo:<owner>/<repo>:ref:...`
  and `:environment:...` if you use environments. See `docs/deploying.md`.
- Cloudflare (only if you proxy the site through it):
  - a cache rule that edge-caches HTML (Edge TTL override, browser TTL
    respects origin), safe **only** together with the purge job.
  - an API token with **Zone → Cache Purge** on the zone, stored with the
    zone id:

    ```bash
    gh secret set CLOUDFLARE_PURGE_TOKEN --repo <owner>/<repo>
    gh secret set CLOUDFLARE_ZONE_ID --repo <owner>/<repo>
    ```

  Without the secrets the purge job warns and skips. With the cache rule but
  no purge, deploys serve stale pages for up to the rule's TTL.

  The rule must exclude `/healthz`, `/api/*` and `/.well-known/*`. An edge
  TTL override ignores the origin's `no-store`, and a probe answered from
  the edge cannot see an outage: on abera.tech, 2026-09-21, `/healthz` came
  back with an age of 83,725 seconds. Match the rule on HTML content type or
  on the page paths. A rule that matches the whole host caches the probes.

- **Tell the app its hostnames.** Set the `ALLOWED_HOSTS` repository variable
  (the deploy passes it to the container as `HostAllowlist__Hosts`) to the
  domains it serves, comma-separated: `www.example.com,example.com`, or
  `*.example.io` for any subdomain. Outside Development the app refuses to
  start without it, so a deployment that skips this fails its first deploy
  instead of answering every Host header. Health probes need no entry:
  `/healthz` is exempt. Manual because only you know your domain.
- **Tell the app how many proxies are in front of it.** Set the
  `TRUSTED_HOPS` repository variable (`ForwardedHeaders__TrustedHops` on the
  container: `2` for Cloudflare +
  cloud ingress, `1` for an ingress alone) and lock the origin to the CDN's
  ranges. Left at the default `0` behind a proxy, every visitor shares one
  rate-limit bucket. Manual because only you know your topology.
  [deploying.md](deploying.md#behind-a-proxy-whose-address-is-it) has the
  reasoning.

## 4. Commit signing: one script per machine

`setup.sh` configures signing automatically: `scripts/setup-signing.sh`
creates a dedicated signing key if the machine has none, configures the
repository to sign every commit, registers the key with GitHub, and only
then does setup enable **require signed commits** on the default branch.
If any of that fails (usually a `gh` token missing the
`admin:ssh_signing_key` scope), signatures are not required, and setup
prints the two commands that enable them later.

What stays manual, forever:

- **Each new machine you commit from** runs `./scripts/setup-signing.sh`
  once. Until it does, that machine's pushes to the protected branch are
  rejected as unsigned. That rejection is the reminder.
- **Never delete the signing key from GitHub** (Settings → SSH and GPG
  keys). For a lost machine, run the script on its replacement. Removing the
  public key retroactively flips every commit it verified back to Unverified.
- Bot commits are already handled: the `dotnet-major-upgrade` workflow
  commits through GitHub's API (`sign-commits: true`), which GitHub signs
  itself, and Dependabot's commits are GitHub-signed natively.

## 5. .NET major upgrades: close and reopen the PR

The monthly `dotnet-major-upgrade` workflow opens its PR with the default
token, and workflow-opened PRs do not start checks on their own. Close and
reopen that PR once to trigger CI on it, then merge on green.

## 6. Prerendering: keep the route list honest

`client/src/prerenderedRoutes.ts` lists the routes baked to HTML at build
time. When you add a page whose content is the same for every visitor
between deploys, add its route there. That is the entire step. Never list a
page that shows live or per-visitor data. Its snapshot would open stale. The
day you add a client-side router, wrap the app in its static router inside
`client/src/entry-server.tsx` and the matching browser router in
`client/src/main.tsx`. Both entries must compose the same tree, because
hydration compares the prerendered markup against it.

## 7. The day you add sign-in

The template has no users, but it is already closed: the fallback
authorization policy requires an authenticated user on every endpoint that
does not say `AllowAnonymous()`, a test
(`EveryEndpointDeclaresWhoMayCallIt`) fails on an endpoint that says nothing,
and 401/403 are already security events 1002/1003
(`server/Api/AuthorizationRefusals.cs`). Adding a scheme changes none of
that. What is left is judgment, so it is manual:

- **Register the scheme and leave the policy alone.**

  ```csharp
  builder.Services.AddAuthentication(CookieAuthenticationDefaults.AuthenticationScheme).AddCookie(...);
  ```

  `UseAuthentication` is added for you, ahead of the pipeline. Do not replace
  the fallback policy with per-endpoint `[Authorize]`: opt-in authorization is
  the defect this default exists to prevent.
- **Every object read or written by id gets the IDOR test, before the
  endpoint is written.** "User B is refused user A's object" is one line with
  the helper in `server/Api.Tests/AuthorizationTests.cs`:

  ```csharp
  using var host = TestIdentity.Host(factory);
  await TestIdentity.AssertOnlyTheOwnerCanRead(host, $"/api/notes/{alicesNoteId}", owner: "alice", someoneElse: "bob");
  ```

  It asserts 200 for the owner, **404** for another signed-in user (a 403
  confirms the object exists) and 401 for nobody. The query that makes it
  pass filters by owner in the database (`WHERE id = @id AND owner_id =
  @user`). `TestIdentity` signs a test user in with a header and exists only
  in the test host.
- **Cookie defaults, all of them, on the first cookie.**

  ```csharp
  .AddCookie(options =>
  {
      options.Cookie.Name = "__Host-session";   // the prefix makes the browser enforce Secure, Path=/, no Domain
      options.Cookie.SecurePolicy = CookieSecurePolicy.Always;
      options.Cookie.HttpOnly = true;
      options.Cookie.SameSite = SameSiteMode.Lax; // Strict if nothing links into a signed-in page
  });
  ```

  The same four for the antiforgery cookie (`AddAntiforgery(o => o.Cookie...)`,
  name `__Host-antiforgery`). Behind a TLS-terminating proxy the app sees
  `http`. `ForwardedHeaders__TrustedHops` (step 3) is what makes `Secure`
  cookies and HTTPS redirects work there. Mount the cookie-issuing middleware
  under `/api` only. Static responses must stay cookie-free
  ([performance.md](performance.md#static-responses-carry-no-cookies), and a
  test enforces it).
- **Persist the Data Protection key ring, and let it rotate.** Cookies and
  antiforgery tokens are encrypted with keys that default to the container's
  filesystem: every deploy signs everyone out, and two replicas cannot read
  each other's cookies. Persist to shared storage and protect at rest
  (`PersistKeysToAzureBlobStorage(...).ProtectKeysWithAzureKeyVault(...)`, or
  `PersistKeysToDbContext`), call `SetApplicationName` so revisions share
  keys, and leave the 90-day rotation on. Never pin a single key.
- **Call the named security events** (`server/Api/SecurityEvents.cs`,
  table in [SECURITY.md](../SECURITY.md)): `SignInRefused` wherever a sign-in
  attempt is turned away (with the enum reason and without the attempted user
  name) and `AntiforgeryRejected` where antiforgery validation fails.

## 8. The day you add a database

Already machinery, and nothing to do: the `db` compose profile, `--migrate`
as a separate deploy step with `MIGRATE_ON_BOOT` off
([deploying.md](deploying.md#databases)), and the runtime role proven unable
to change the schema (`scripts/db/check-runtime-role.sh`). What needs a
person:

- **Create two roles, and give the app the lesser one.** A migrator that owns
  the database, and a runtime login. Run `scripts/db/runtime-role.sql` once as
  the migrator. The app's `ConnectionStrings__Default` is the runtime role's.
  The migrator's exists only as the `MIGRATOR_CONNECTION_STRING` deploy
  secret. Manual because creating logins needs your platform's credentials.
- **Put the migration call in `Migrations.ApplyAsync`.** It is one line,
  `Database.MigrateAsync()`, and the method's comment says where.
- **Register the DbContext read-only by default.** Most requests only read,
  and change tracking is the cost nobody asked for:

  ```csharp
  builder.Services.AddDbContext<AppDbContext>(options => options
      .UseNpgsql(connectionString, npgsql => npgsql.UseQuerySplittingBehavior(QuerySplittingBehavior.SplitQuery))
      .UseQueryTrackingBehavior(QueryTrackingBehavior.NoTracking));
  ```

  A handler that writes asks for tracking (`.AsTracking()`), so the expensive
  path is the visible one. Split queries stop two `Include`d collections
  multiplying into a cartesian product.
- **Count commands in tests.** N+1 is invisible until production. An
  interceptor makes it an assertion. Register it in the test host and assert
  on the endpoints that list things:

  ```csharp
  internal sealed class CommandCounter : DbCommandInterceptor
  {
      private int count;
      public int Count => count;

      public override ValueTask<InterceptionResult<DbDataReader>> ReaderExecutingAsync(
          DbCommand command, CommandEventData eventData, InterceptionResult<DbDataReader> result,
          CancellationToken cancellationToken = default)
      {
          Interlocked.Increment(ref count);
          return base.ReaderExecutingAsync(command, eventData, result, cancellationToken);
      }
  }

  // Twenty notes must cost what two cost.
  Assert.True(counter.Count <= 2, $"GET /api/notes ran {counter.Count} commands");
  ```
- **Output caching goes after authorization.** `UseOutputCache`
  below `UseAuthorization`, so a cached body is only ever served to a request
  that was just authorized for it. Anything per-user varies by the user
  (`policy.VaryByValue(context => new("user", context.User.FindFirstValue(ClaimTypes.NameIdentifier) ?? ""))`),
  every cached read carries a tag, and every write evicts it
  (`IOutputCacheStore.EvictByTagAsync`). The test that must exist before the
  policy does: two principals request the same URL and **never** receive each
  other's body. `TestIdentity.As(host, "alice")` and `"bob"` make it four
  lines.
- **Review migrations for indexes.** The pull request template has the
  checklist: an index for each `WHERE` + `ORDER BY` pair, and one for the
  second column of a composite key when it is filtered alone.

## 9. The first upload, webhook or stored URL

Three helpers exist so these are not hand-rolled on a deadline. Each is a few
dozen lines with its failure cases already tested.

- **A URL a user gives you to store or show** goes through
  `UrlAllowlist.Allows(url)` (`server/Api/UrlAllowlist.cs`): https only, exact
  allowlisted host, default port, no `user@`. Hosts come from
  `UrlAllowlist__Hosts__0`, `…__1`. The same list is appended to the
  Content-Security-Policy as `img-src`, so what is storable is what the
  browser will load. Two things it cannot do for you. The app sends
  `Cross-Origin-Embedder-Policy: require-corp`, so an external image host must
  send `Cross-Origin-Resource-Policy: cross-origin` (or the `<img>` needs
  `crossorigin` and the host CORS). If the *server* ever fetches a stored
  URL, resolve and check the address too, because an allowlisted name can
  point at an internal IP.
- **A webhook** reads the raw body and verifies before parsing:

  ```csharp
  app.MapPost("/api/webhooks/payments", async (HttpContext context, IConfiguration configuration) =>
  {
      using var raw = new MemoryStream();
      await context.Request.Body.CopyToAsync(raw);
      var secret = Encoding.UTF8.GetBytes(configuration["Webhooks:PaymentsSecret"] ?? "");
      if (!WebhookSignature.IsValid(secret, raw.ToArray(), context.Request.Headers["X-Signature"]))
      {
          SecurityEvents.WebhookSignatureRejected(SecurityEvents.Logger(context), SecurityEvents.Route(context), SecurityEvents.Client(context));
          return Results.Unauthorized();
      }
      // parse raw, then act — idempotently: senders retry.
      return Results.Ok();
  }).AllowAnonymous(); // the signature is the authentication
  ```

  `WebhookSignature` compares in constant time and treats a missing secret as
  "nothing verifies". The 1 MB body limit already applies.
- **An upload endpoint** raises its own body limit and nobody else's
  (`.WithMetadata(new RequestSizeLimitAttribute(20 * 1024 * 1024))`), checks
  the content by its bytes rather than its file name, stores outside
  `wwwroot`, and serves it back with `Content-Disposition: attachment` unless
  it is an image type you re-encoded.
