using Api;
using System.Threading.RateLimiting;
using OpenTelemetry.Metrics;
using OpenTelemetry.Trace;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.HttpOverrides;
using Microsoft.AspNetCore.ResponseCompression;
using Microsoft.AspNetCore.Server.Kestrel.Core;
using Microsoft.Net.Http.Headers;

// Healthcheck mode: the chiseled runtime image has no shell or curl, so the
// container healthcheck (Dockerfile HEALTHCHECK, honored by compose) re-runs
// this binary with --healthcheck, which probes the serving process's /healthz
// and exits 0 (healthy) or 1. The port comes from the same variable the
// server listens on (the aspnet base image sets ASPNETCORE_HTTP_PORTS=8080).
if (args.Contains("--healthcheck"))
{
    var port = Environment.GetEnvironmentVariable("ASPNETCORE_HTTP_PORTS")?.Split(';')[0] ?? "8080";
    using var healthClient = new HttpClient { Timeout = TimeSpan.FromSeconds(3) };
    try
    {
        using var healthResponse = await healthClient.GetAsync(new Uri($"http://localhost:{port}{HealthRoute.Path}")).ConfigureAwait(false);
        return healthResponse.IsSuccessStatusCode ? 0 : 1;
    }
    catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException)
    {
        return 1;
    }
}

var builder = WebApplication.CreateBuilder(args);

// Graceful shutdown: on redeploy the container gets SIGTERM, and Docker
// waits only stop_grace_period (default 10s, pinned in compose.yaml) before
// SIGKILL — while the host's default shutdown timeout is 30s. Left alone,
// the runtime is still draining in-flight requests when the kill arrives.
// 8s finishes inside Docker's 10s window (and well inside Azure Container
// Apps' 30s terminationGracePeriodSeconds) with margin for process exit.
builder.Services.Configure<HostOptions>(options => options.ShutdownTimeout = TimeSpan.FromSeconds(8));

// appsettings.json holds the deliberate values; every one of them can be
// overridden per environment (HostAllowlist__Hosts=..., Kestrel__Limits__...,
// see docs/deploying.md).
//
// Kestrel reads its endpoints from configuration on its own, but not its
// limits. The one that matters is Limits:MaxRequestBodySize: the framework
// default is 28.6 MB on every endpoint, which nothing here needs. The file sets
// 1 MB; an endpoint that takes uploads raises its own ceiling and no one
// else's: .WithMetadata(new RequestSizeLimitAttribute(20 * 1024 * 1024)).
builder.Services.Configure<KestrelServerOptions>(builder.Configuration.GetSection("Kestrel"));

builder.Services.AddProblemDetails();

// Observability: traces and metrics for every request and outgoing call.
// Exported over OTLP only when OTEL_EXPORTER_OTLP_ENDPOINT is set (the
// standard variable), so local dev and tests stay silent; performance work
// starts with being able to see where time goes.
var otelEndpoint = builder.Configuration["OTEL_EXPORTER_OTLP_ENDPOINT"];
builder.Services.AddOpenTelemetry()
    .WithTracing(tracing =>
    {
        tracing.AddAspNetCoreInstrumentation().AddHttpClientInstrumentation();
        if (!string.IsNullOrEmpty(otelEndpoint))
        {
            tracing.AddOtlpExporter();
        }
    })
    .WithMetrics(metrics =>
    {
        metrics.AddAspNetCoreInstrumentation().AddHttpClientInstrumentation();
        if (!string.IsNullOrEmpty(otelEndpoint))
        {
            metrics.AddOtlpExporter();
        }
    });
builder.Services.AddOpenApi();
builder.Services.AddHealthChecks();

// Compress dynamic responses and the client's JS/CSS. Without this the bundle
// and stylesheet leave the server uncompressed — measured in production, not
// hypothetical. EnableForHttps is safe here: no secrets appear in
// compressible responses (BREACH needs both in one body).
builder.Services.AddResponseCompression(options => options.EnableForHttps = true);

// Who the visitor is, behind however many proxies: see ClientAddress.cs.
builder.Services.Configure<ForwardedHeadersOptions>(options => ClientAddress.Configure(options, builder.Configuration));

// The permit limit is env-configurable because CI and e2e suites arrive from
// one address: a test suite tripping a rate limit looks like a broken app
// rather than a working control. Production leaves the default alone.
var permitLimit = builder.Configuration.GetValue<int?>("RATE_LIMIT_PERMIT") ?? 100;
builder.Services.AddRateLimiter(options =>
{
    options.RejectionStatusCode = StatusCodes.Status429TooManyRequests;
    // A refusal is a security event (SecurityEvents.cs says what one may
    // carry), and the client is told when to come back.
    options.OnRejected = (rejected, _) =>
    {
        var http = rejected.HttpContext;
        if (rejected.Lease.TryGetMetadata(MetadataName.RetryAfter, out var retryAfter))
        {
            http.Response.Headers.RetryAfter = ((int)retryAfter.TotalSeconds).ToString(System.Globalization.CultureInfo.InvariantCulture);
        }

        SecurityEvents.RateLimitRejected(
            SecurityEvents.Logger(http), http.Request.Method, SecurityEvents.Route(http), SecurityEvents.Client(http));
        return ValueTask.CompletedTask;
    };
    options.GlobalLimiter = PartitionedRateLimiter.Create<HttpContext, string>(context =>
        RateLimitPartition.GetFixedWindowLimiter(
            ClientAddress.PartitionKey(context),
            _ => new FixedWindowRateLimiterOptions { PermitLimit = permitLimit, Window = TimeSpan.FromSeconds(10) }));
});

// External hosts the app may store URLs for and show images from; empty by
// default. One list for both, see UrlAllowlist.cs.
var urlAllowlist = UrlAllowlist.From(builder.Configuration);
builder.Services.AddSingleton(urlAllowlist);

// Closed unless opened: an endpoint with no authorization metadata requires an
// authenticated user. Every endpoint below says AllowAnonymous out loud, and a
// test (EveryEndpointDeclaresWhoMayCallIt) fails on one that says nothing.
// AuthorizationRefusals.cs is how this works before any sign-in exists.
builder.Services.AddAuthorizationBuilder()
    .SetFallbackPolicy(new AuthorizationPolicyBuilder().RequireAuthenticatedUser().Build());
builder.Services.AddSingleton<IAuthorizationMiddlewareResultHandler, AuthorizationRefusals>();

var app = builder.Build();

// Schema changes are a deploy step of their own, not something serving does on
// the way up: see Migrations.cs. `--migrate` applies and exits without ever
// listening; MIGRATE_ON_BOOT (default false) is the local-development shortcut.
if (args.Contains(Migrations.Argument))
{
    await Migrations.ApplyAsync(app.Services, Console.Out).ConfigureAwait(false);
    return 0;
}

if (Migrations.OnBoot(app.Configuration))
{
    await Migrations.ApplyAsync(app.Services, Console.Out).ConfigureAwait(false);
}

// First, before anything reads the connection: every later middleware — the
// rate limiter, the logs — must see the resolved client, never the proxy.
app.UseForwardedHeaders();

// Second: only the configured Host names are answered, except on the health
// route, which platform probes reach by pod IP. See HostAllowlist.cs — and
// note it refuses to start outside Development when no host is configured.
app.UseHostAllowlist(HealthRoute.Path);

app.UseExceptionHandler();
app.UseStatusCodePages();

var contentSecurityPolicy =
    "default-src 'self'; base-uri 'self'; form-action 'self'; frame-ancestors 'none'" + urlAllowlist.ImgSrcDirective;

// Security headers on every response. TLS termination (and therefore HSTS)
// belongs to the ingress in front of the container.
app.Use(async (context, next) =>
{
    var headers = context.Response.Headers;
    headers.ContentSecurityPolicy = contentSecurityPolicy;
    headers.XContentTypeOptions = "nosniff";
    headers["Referrer-Policy"] = "no-referrer";
    headers["Permissions-Policy"] = "camera=(), geolocation=(), microphone=()";
    // OWASP Secure Headers: isolate the browsing context and keep resources
    // same-origin (Spectre-class cross-origin leak mitigations).
    headers["Cross-Origin-Opener-Policy"] = "same-origin";
    headers["Cross-Origin-Resource-Policy"] = "same-origin";
    headers["Cross-Origin-Embedder-Policy"] = "require-corp";
    headers.XFrameOptions = "DENY"; // legacy agents; CSP frame-ancestors covers the rest
    await next().ConfigureAwait(false);
});

app.UseResponseCompression();

// The production image serves the built client from wwwroot. Vite
// content-hashes everything under /assets, so those files can be cached
// forever; the document is the one URL that must stay fresh, because it is
// where the hashed names live.
var staticFiles = new StaticFileOptions
{
    OnPrepareResponse = ctx =>
        ctx.Context.Response.Headers.CacheControl =
            ctx.Context.Request.Path.StartsWithSegments("/assets")
                ? "public, max-age=31536000, immutable"
                : CacheControlHeaderValue.NoCacheString,
};
// Prerendered pages: /about is on disk as /about/index.html, so an
// extensionless GET or HEAD whose prerendered file exists is rewritten to it
// before the static file middleware looks. Anything else falls through.
var webRoot = app.Environment.WebRootFileProvider;
app.Use((context, next) =>
{
    if (HttpMethods.IsGet(context.Request.Method) || HttpMethods.IsHead(context.Request.Method))
    {
        var rewritten = PrerenderedPages.RewriteFor(
            context.Request.Path.Value ?? "/",
            candidate => webRoot.GetFileInfo(candidate).Exists);
        if (rewritten is not null)
        {
            context.Request.Path = rewritten;
        }
    }

    return next(context);
});

app.UseDefaultFiles();
app.UseStaticFiles(staticFiles);

// Explicit, and deliberately AFTER the static file middleware. Left implicit,
// WebApplication puts routing at the front of the pipeline, where the SPA
// fallback endpoint matches every extensionless request — and the static file
// middleware stands down once an endpoint has matched, so UseDefaultFiles is
// dead code and every page is served by the fallback. Invisible while both
// serve the same index.html; a production incident on aberaTech the moment
// they differed (prerendered pages all served the empty shell).
app.UseRouting();

// After routing and after the static files, both on purpose. Static files
// never reach this line, so a page load — the document plus every asset on
// it — spends none of the visitor's permits; those are for requests that make
// the server do work. And with routing done, an endpoint can opt out by name
// (DisableRateLimiting, below). Everything else is limited without asking:
// a new endpoint is covered the moment it is mapped.
app.UseRateLimiter();

// Explicit, and after routing for the same reason: left implicit, WebApplication
// adds it at the front, where no endpoint is known yet and the fallback policy
// would turn every static file into a 401.
app.UseAuthorization();

if (app.Environment.IsDevelopment())
{
    app.MapOpenApi().AllowAnonymous();
}

// Probes arrive on a schedule from one address; a limited health endpoint
// turns a traffic spike into a restart.
app.MapHealthChecks(HealthRoute.Path).DisableRateLimiting().AllowAnonymous();

// TypedResults, not Results: the typed return value is what puts Greeting's
// schema into the OpenAPI document that the build emits (openapi.json) and
// the client's generated types are made from — an untyped Results.Ok would
// leave the contract empty and the drift gate blind.
app.MapGet("/api/hello", () => TypedResults.Ok(new Greeting("Hello from the API"))).AllowAnonymous();

// spa.html, not index.html: index.html carries the home page's prerendered
// markup, and a client-rendered route served over it would flash the wrong
// page and then hydrate against DOM that contradicts it. spa.html is the
// same shell with the root div left empty.
// It is a static file that happens to be served by an endpoint, so it is
// unlimited like the rest of them.
app.MapFallbackToFile("spa.html", staticFiles).DisableRateLimiting().AllowAnonymous();

// RunAsync, not Run: the --healthcheck branch above makes the entry point
// async, and CA1849 rightly refuses a synchronous block inside it.
await app.RunAsync().ConfigureAwait(false);

return 0;

internal sealed record Greeting(string Message);

// One name for the health route: where it is mapped, what the container's own
// healthcheck probes, and what the host allowlist lets through. The template
// has no separate readiness route; if one is added, it goes here and into
// UseHostAllowlist above.
internal static class HealthRoute
{
    public const string Path = "/healthz";
}

// Expose the entry point to the test project's WebApplicationFactory; it
// must stay public for that, which CA1515 cannot know.
#pragma warning disable CA1515
public partial class Program
#pragma warning restore CA1515
{
    protected Program()
    {
    }
}
