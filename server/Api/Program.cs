using System.Threading.RateLimiting;
using Microsoft.AspNetCore.ResponseCompression;
using Microsoft.Net.Http.Headers;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddProblemDetails();
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
app.UseDefaultFiles();
app.UseStaticFiles(staticFiles);

if (app.Environment.IsDevelopment())
{
    app.MapOpenApi();
}

app.MapHealthChecks("/healthz");

app.MapGet("/api/hello", () => Results.Ok(new Greeting("Hello from the API")));

app.MapFallbackToFile("index.html", staticFiles);

app.Run();

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
