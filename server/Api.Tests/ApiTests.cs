using System.Net;
using System.Net.Http.Json;
using Microsoft.AspNetCore.Mvc.Testing;
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

    // Table-driven example: adding a new failing case (TDD's "red" step) is a
    // one-line change.
    [Theory]
    [InlineData("Content-Security-Policy", "default-src 'self'; frame-ancestors 'none'")]
    [InlineData("X-Content-Type-Options", "nosniff")]
    [InlineData("Referrer-Policy", "no-referrer")]
    [InlineData("Permissions-Policy", "camera=(), geolocation=(), microphone=()")]
    [InlineData("Cross-Origin-Opener-Policy", "same-origin")]
    [InlineData("Cross-Origin-Resource-Policy", "same-origin")]
    [InlineData("X-Frame-Options", "DENY")]
    public async Task SecurityHeadersAreAlwaysSent(string header, string expected)
    {
        using var client = factory.CreateClient();

        var response = await client.GetAsync("/api/hello", TestContext.Current.CancellationToken);

        Assert.True(response.Headers.TryGetValues(header, out var values), $"missing header {header}");
        Assert.Equal(expected, Assert.Single(values));
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
