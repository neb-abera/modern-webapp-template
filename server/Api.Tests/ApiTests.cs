using System.Net;
using System.Net.Http.Json;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Options;
using Xunit;

namespace Api.Tests;

// Behavioral contract of the API: these tests pin down what production
// serves, so a regression fails loudly and early.
public sealed class ApiTests : IDisposable
{
    private readonly WebApplicationFactory<Program> factory = new();

    [Fact]
    public async Task HelloReturnsGreeting()
    {
        using var client = factory.CreateClient();

        var greeting = await client.GetFromJsonAsync<Greeting>("/api/hello", TestContext.Current.CancellationToken);

        Assert.NotNull(greeting);
        Assert.Equal("Hello from the API", greeting.Message);
    }

    [Fact]
    public async Task HealthCheckIsHealthy()
    {
        using var client = factory.CreateClient();

        var response = await client.GetAsync("/healthz", TestContext.Current.CancellationToken);

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
    }

    // /healthz once came back from a CDN edge cache with an age of 83,725
    // seconds. A probe that can be answered from a cache is not a probe, and
    // an API answer held by a browser is stale by the next request.
    [Theory]
    [InlineData("/healthz")]
    [InlineData("/api/hello")]
    public async Task AnAnswerIsNeverStored(string path)
    {
        using var client = factory.CreateClient();

        var response = await client.GetAsync(path, TestContext.Current.CancellationToken);

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Contains("no-store", response.Headers.CacheControl?.ToString() ?? "", StringComparison.Ordinal);
    }

    [Fact]
    public async Task SecurityTxtSaysWhereToReport()
    {
        using var client = factory.CreateClient();

        var response = await client.GetAsync(SecurityTxt.Path, TestContext.Current.CancellationToken);
        var body = await response.Content.ReadAsStringAsync(TestContext.Current.CancellationToken);

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Equal("text/plain", response.Content.Headers.ContentType?.MediaType);
        Assert.Contains("Contact: " + SecurityTxt.Contact, body, StringComparison.Ordinal);
        Assert.Contains("Contact: " + SecurityTxt.Advisories, body, StringComparison.Ordinal);
        Assert.Equal("public, max-age=86400", response.Headers.CacheControl?.ToString());
    }

    [Fact]
    public void SecurityTxtExpiresAYearFromTodayToTheDay()
    {
        // 18:30 UTC on the 21st, whatever the caller's offset says.
        var text = SecurityTxt.Render(new DateTimeOffset(2026, 9, 21, 14, 30, 0, TimeSpan.FromHours(-4)));

        Assert.Contains("Expires: 2027-09-21T00:00:00Z", text, StringComparison.Ordinal);
    }

    // Table-driven example: adding a new failing case (TDD's "red" step) is a
    // one-line change.
    [Theory]
    [InlineData("Content-Security-Policy", "default-src 'self'; base-uri 'self'; form-action 'self'; frame-ancestors 'none'")]
    [InlineData("X-Content-Type-Options", "nosniff")]
    [InlineData("Referrer-Policy", "no-referrer")]
    [InlineData("Permissions-Policy", "camera=(), geolocation=(), microphone=()")]
    [InlineData("Cross-Origin-Opener-Policy", "same-origin")]
    [InlineData("Cross-Origin-Resource-Policy", "same-origin")]
    [InlineData("Cross-Origin-Embedder-Policy", "require-corp")]
    [InlineData("X-Frame-Options", "DENY")]
    public async Task SecurityHeadersAreAlwaysSent(string header, string expected)
    {
        using var client = factory.CreateClient();

        var response = await client.GetAsync("/api/hello", TestContext.Current.CancellationToken);

        Assert.True(response.Headers.TryGetValues(header, out var values), $"missing header {header}");
        Assert.Equal(expected, Assert.Single(values));
    }

    // Redeploys deliver SIGTERM, and Docker sends SIGKILL after
    // stop_grace_period (default 10s, pinned in compose.yaml) — but the
    // ASP.NET Core host's default shutdown timeout is 30s, so with no
    // configuration every in-flight request is hard-killed on redeploy.
    // Pin the configured timeout inside the orchestrator's window.
    [Fact]
    public void ShutdownTimeoutFitsInsideTheDockerStopGracePeriod()
    {
        var hostOptions = factory.Services.GetRequiredService<IOptions<HostOptions>>().Value;

        Assert.Equal(TimeSpan.FromSeconds(8), hostOptions.ShutdownTimeout);
        Assert.True(hostOptions.ShutdownTimeout < TimeSpan.FromSeconds(10),
            "shutdown timeout must finish inside Docker's 10s SIGTERM->SIGKILL window");
    }

    [Fact]
    public async Task UnknownApiRouteIs404()
    {
        using var client = factory.CreateClient();

        var response = await client.GetAsync("/api/does-not-exist", TestContext.Current.CancellationToken);

        Assert.Equal(HttpStatusCode.NotFound, response.StatusCode);
    }

    public void Dispose() => factory.Dispose();
}
