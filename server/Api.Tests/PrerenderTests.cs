using System.Net;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Api;
using Xunit;

namespace Api.Tests;

// How a route URL finds its prerendered HTML file. The client build writes
// the static routes to wwwroot as <route>/index.html, but a visitor asks for
// the route; this mapping is the bridge. Pure function, testable without a
// filesystem.
public sealed class PrerenderedPagesTests
{
    private static bool Exists(string path) => path is "/about/index.html";

    [Theory]
    [InlineData("/about", "/about/index.html")]
    [InlineData("/about/", "/about/index.html")]
    public void APrerenderedRouteIsRewrittenToItsFile(string requested, string expected)
    {
        Assert.Equal(expected, PrerenderedPages.RewriteFor(requested, Exists));
    }

    [Fact]
    public void ARouteWithoutAPrerenderedFileIsLeftAlone()
    {
        Assert.Null(PrerenderedPages.RewriteFor("/dashboard", Exists));
    }

    [Fact]
    public void TheRootIsLeftToTheDefaultFilesMiddleware()
    {
        Assert.Null(PrerenderedPages.RewriteFor("/", Exists));
    }

    [Fact]
    public void AFileRequestIsNeverRewritten()
    {
        Assert.Null(PrerenderedPages.RewriteFor("/assets/index-abc.js", Exists));
    }

    [Fact]
    public void AnApiRouteIsNeverRewritten()
    {
        Assert.Null(PrerenderedPages.RewriteFor("/api/hello", Exists));
    }
}

// The pipeline, exercised end to end against a fixture wwwroot. This exists
// because of a production incident on aberaTech: with WebApplication's
// implicit routing at the front of the pipeline, the SPA fallback endpoint
// matched every extensionless request and the static middleware stood down —
// so the prerendered pages all served the empty shell. Pipeline order is only
// testable as a pipeline.
public sealed class PrerenderPipelineTests : IDisposable
{
    private readonly string webRoot;
    private readonly WebApplicationFactory<Program> factory;

    public PrerenderPipelineTests()
    {
        webRoot = Directory.CreateTempSubdirectory("wwwroot-fixture").FullName;
        Directory.CreateDirectory(Path.Combine(webRoot, "about"));
        Directory.CreateDirectory(Path.Combine(webRoot, "assets"));
        File.WriteAllText(Path.Combine(webRoot, "index.html"), "<html>prerendered home</html>");
        File.WriteAllText(Path.Combine(webRoot, "spa.html"), "<html>empty shell</html>");
        File.WriteAllText(Path.Combine(webRoot, "about", "index.html"), "<html>prerendered about</html>");
        File.WriteAllText(Path.Combine(webRoot, "assets", "index-abc123.js"), "console.log('app')");

        factory = new WebApplicationFactory<Program>()
            .WithWebHostBuilder(builder => builder.UseWebRoot(webRoot));
    }

    public void Dispose()
    {
        factory.Dispose();
        Directory.Delete(webRoot, recursive: true);
    }

    [Fact]
    public async Task TheRootServesThePrerenderedHomePage()
    {
        using var client = factory.CreateClient();

        var response = await client.GetAsync("/", TestContext.Current.CancellationToken);

        Assert.Contains("prerendered home", await response.Content.ReadAsStringAsync(TestContext.Current.CancellationToken), StringComparison.Ordinal);
        Assert.Equal("no-cache", response.Headers.CacheControl?.ToString());
    }

    [Fact]
    public async Task APrerenderedRouteServesItsOwnPage()
    {
        using var client = factory.CreateClient();

        var response = await client.GetAsync("/about", TestContext.Current.CancellationToken);

        Assert.Contains("prerendered about", await response.Content.ReadAsStringAsync(TestContext.Current.CancellationToken), StringComparison.Ordinal);
    }

    [Fact]
    public async Task ARouteThatIsNotPrerenderedFallsBackToTheEmptyShell()
    {
        // spa.html, not index.html: the root document now carries the home
        // page's markup, and a client-rendered route served over it would
        // flash the wrong page and hydrate against DOM that contradicts it.
        using var client = factory.CreateClient();

        var response = await client.GetAsync("/dashboard", TestContext.Current.CancellationToken);

        Assert.Contains("empty shell", await response.Content.ReadAsStringAsync(TestContext.Current.CancellationToken), StringComparison.Ordinal);
    }

    [Fact]
    public async Task AHeadRequestForAPrerenderedRouteIsServedWithoutARedirect()
    {
        // Link checkers and crawlers probe with HEAD; skipping HEAD in the
        // rewrite hands them a 301 hop to the trailing-slash form instead.
        using var client = factory.CreateClient();
        using var request = new HttpRequestMessage(HttpMethod.Head, "/about");

        var response = await client.SendAsync(request, TestContext.Current.CancellationToken);

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
    }

    [Fact]
    public async Task AHashedAssetStaysImmutable()
    {
        using var client = factory.CreateClient();

        var response = await client.GetAsync("/assets/index-abc123.js", TestContext.Current.CancellationToken);

        Assert.Equal("public, max-age=31536000, immutable", response.Headers.CacheControl?.ToString());
    }
}
