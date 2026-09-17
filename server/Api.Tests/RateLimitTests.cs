using System.Net;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Xunit;

namespace Api.Tests;

// What the limiter counts. A page load is a document plus every asset on it;
// when those spent API permits, one visitor opening the site could be refused
// the API call the page then makes.
public sealed class RateLimitTests : IDisposable
{
    private readonly string webRoot = FixtureWebRoot.Create();
    private readonly WebApplicationFactory<Program> factory;

    public RateLimitTests()
    {
        factory = new WebApplicationFactory<Program>().WithWebHostBuilder(builder =>
            builder.UseWebRoot(webRoot).UseSetting("RATE_LIMIT_PERMIT", "2"));
    }

    public void Dispose()
    {
        factory.Dispose();
        Directory.Delete(webRoot, recursive: true);
    }

    private async Task<HttpStatusCode> Get(HttpClient client, string path)
    {
        using var response = await client.GetAsync(path, TestContext.Current.CancellationToken);
        return response.StatusCode;
    }

    [Fact]
    public async Task RequestsOverThePermitLimitAre429()
    {
        using var client = factory.CreateClient();

        Assert.Equal(HttpStatusCode.OK, await Get(client, "/api/hello"));
        Assert.Equal(HttpStatusCode.OK, await Get(client, "/api/hello"));
        Assert.Equal(HttpStatusCode.TooManyRequests, await Get(client, "/api/hello"));
    }

    [Theory]
    [InlineData("/")]
    [InlineData("/about")]
    [InlineData("/assets/index-abc123.js")]
    [InlineData("/dashboard")] // the SPA fallback shell
    [InlineData("/healthz")]
    public async Task StaticFilesTheShellAndHealthSpendNoPermits(string path)
    {
        using var client = factory.CreateClient();

        for (var i = 0; i < 10; i++)
        {
            Assert.Equal(HttpStatusCode.OK, await Get(client, path));
        }

        // The visitor's API permits are all still there...
        Assert.Equal(HttpStatusCode.OK, await Get(client, "/api/hello"));
        Assert.Equal(HttpStatusCode.OK, await Get(client, "/api/hello"));
        Assert.Equal(HttpStatusCode.TooManyRequests, await Get(client, "/api/hello"));
        // ...and spending them does not take the page away.
        Assert.Equal(HttpStatusCode.OK, await Get(client, path));
    }
}
