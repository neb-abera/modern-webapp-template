using System.Threading.RateLimiting;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddProblemDetails();
builder.Services.AddOpenApi();
builder.Services.AddHealthChecks();
builder.Services.AddRateLimiter(options =>
{
    options.RejectionStatusCode = StatusCodes.Status429TooManyRequests;
    options.GlobalLimiter = PartitionedRateLimiter.Create<HttpContext, string>(context =>
        RateLimitPartition.GetFixedWindowLimiter(
            context.Connection.RemoteIpAddress?.ToString() ?? "unknown",
            _ => new FixedWindowRateLimiterOptions { PermitLimit = 100, Window = TimeSpan.FromSeconds(10) }));
});

var app = builder.Build();

app.UseExceptionHandler();
app.UseStatusCodePages();

// Security headers on every response. TLS termination (and therefore HSTS)
// belongs to the ingress in front of the container.
app.Use(async (context, next) =>
{
    var headers = context.Response.Headers;
    headers.ContentSecurityPolicy = "default-src 'self'; frame-ancestors 'none'";
    headers.XContentTypeOptions = "nosniff";
    headers["Referrer-Policy"] = "no-referrer";
    headers["Permissions-Policy"] = "camera=(), geolocation=(), microphone=()";
    await next().ConfigureAwait(false);
});

app.UseRateLimiter();

// The production image serves the built client from wwwroot.
app.UseDefaultFiles();
app.UseStaticFiles();

if (app.Environment.IsDevelopment())
{
    app.MapOpenApi();
}

app.MapHealthChecks("/healthz");

app.MapGet("/api/hello", () => Results.Ok(new Greeting("Hello from the API")));

app.MapFallbackToFile("index.html");

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
