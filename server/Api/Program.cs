using Api;
using System.Threading.RateLimiting;
using OpenTelemetry.Metrics;
using OpenTelemetry.Trace;
using Microsoft.AspNetCore.ResponseCompression;
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
        using var healthResponse = await healthClient.GetAsync(new Uri($"http://localhost:{port}/healthz")).ConfigureAwait(false);
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

// The permit limit is env-configurable because CI and e2e suites arrive from
// one address: a test suite tripping a rate limit looks like a broken app
// rather than a working control. Production leaves the default alone.
var permitLimit = builder.Configuration.GetValue<int?>("RATE_LIMIT_PERMIT") ?? 100;
builder.Services.AddRateLimiter(options =>
{
    options.RejectionStatusCode = StatusCodes.Status429TooManyRequests;
    options.GlobalLimiter = PartitionedRateLimiter.Create<HttpContext, string>(context =>
        RateLimitPartition.GetFixedWindowLimiter(
            context.Connection.RemoteIpAddress?.ToString() ?? "unknown",
            _ => new FixedWindowRateLimiterOptions { PermitLimit = permitLimit, Window = TimeSpan.FromSeconds(10) }));
});

var app = builder.Build();

app.UseExceptionHandler();
app.UseStatusCodePages();

// Security headers on every response. TLS termination (and therefore HSTS)
// belongs to the ingress in front of the container.
app.Use(async (context, next) =>
{
    var headers = context.Response.Headers;
    headers.ContentSecurityPolicy = "default-src 'self'; base-uri 'self'; form-action 'self'; frame-ancestors 'none'";
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
app.UseRateLimiter();

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

if (app.Environment.IsDevelopment())
{
    app.MapOpenApi();
}

app.MapHealthChecks("/healthz");

// TypedResults, not Results: the typed return value is what puts Greeting's
// schema into the OpenAPI document that the build emits (openapi.json) and
// the client's generated types are made from — an untyped Results.Ok would
// leave the contract empty and the drift gate blind.
app.MapGet("/api/hello", () => TypedResults.Ok(new Greeting("Hello from the API")));

// spa.html, not index.html: index.html carries the home page's prerendered
// markup, and a client-rendered route served over it would flash the wrong
// page and then hydrate against DOM that contradicts it. spa.html is the
// same shell with the root div left empty.
app.MapFallbackToFile("spa.html", staticFiles);

// RunAsync, not Run: the --healthcheck branch above makes the entry point
// async, and CA1849 rightly refuses a synchronous block inside it.
await app.RunAsync().ConfigureAwait(false);

return 0;

internal sealed record Greeting(string Message);

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
