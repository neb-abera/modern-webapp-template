using System.Net;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.Extensions.Logging;
using Xunit;

namespace Api.Tests;

// Which Host headers the app answers to, through the real pipeline. The
// health route is the deliberate exception: platform probes reach the
// container by pod IP, which nobody can list in advance.
public sealed class HostAllowlistTests : IDisposable
{
    private const string Hosts = "www.example.com, *.example.io";
    private readonly string webRoot = FixtureWebRoot.Create();
    private readonly WebApplicationFactory<Program> factory = new();
    private readonly CapturedLogs logs = new();

    public void Dispose()
    {
        factory.Dispose();
        logs.Dispose();
        Directory.Delete(webRoot, recursive: true);
    }

    private WebApplicationFactory<Program> Host(string environment, string? hosts) =>
        CapturedLogs.Attach(factory, logs).WithWebHostBuilder(builder =>
        {
            builder.UseEnvironment(environment).UseWebRoot(webRoot);
            if (hosts is not null)
            {
                builder.UseSetting(HostAllowlist.Setting, hosts);
            }
        });

    internal static async Task<HttpResponseMessage> Get(HttpClient client, string host, string path)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, path);
        request.Headers.Host = host;
        return await client.SendAsync(request, TestContext.Current.CancellationToken);
    }

    [Theory]
    [InlineData("www.example.com")] // exact
    [InlineData("WWW.Example.COM")] // names are case-insensitive
    [InlineData("www.example.com:8443")] // the port is not part of the name
    [InlineData("app.example.io")] // wildcard subdomain
    [InlineData("a.b.example.io")]
    public async Task AnAllowedHostIsServed(string host)
    {
        using var app = Host("Production", Hosts);
        using var client = app.CreateClient();

        using var page = await Get(client, host, "/");
        using var api = await Get(client, host, "/api/hello");

        Assert.Equal(HttpStatusCode.OK, page.StatusCode);
        Assert.Equal(HttpStatusCode.OK, api.StatusCode);
    }

    [Theory]
    [InlineData("evil.example")] // simply wrong
    [InlineData("example.io")] // the bare domain does not match its own wildcard
    [InlineData("notexample.io")] // look-alike suffix: the dot belongs to the pattern
    [InlineData("example.com")] // only www. was listed
    [InlineData("www.example.com.evil.example")]
    [InlineData("localhost")] // nothing is allowed by default once a list exists
    public async Task AnyOtherHostIs400WithNoBody(string host)
    {
        using var app = Host("Production", Hosts);
        using var client = app.CreateClient();

        foreach (var path in new[] { "/", "/about", "/assets/index-abc123.js", "/api/hello", "/api/does-not-exist" })
        {
            using var response = await Get(client, host, path);

            Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
            Assert.Empty(await response.Content.ReadAsByteArrayAsync(TestContext.Current.CancellationToken));
        }
    }

    [Theory]
    [InlineData("10.0.3.17:8080")] // a platform probe, by pod IP
    [InlineData("evil.example")]
    public async Task TheHealthRouteAnswersWhateverTheHost(string host)
    {
        using var app = Host("Production", Hosts);
        using var client = app.CreateClient();

        using var response = await Get(client, host, "/healthz");

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Empty(logs.Security);
    }

    [Fact]
    public async Task AnEmptyListInDevelopmentFiltersNothing()
    {
        using var app = Host("Development", hosts: null);
        using var client = app.CreateClient();

        using var response = await Get(client, "anything.example", "/api/hello");

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData(" , ")]
    public void AnEmptyListOutsideDevelopmentRefusesToStart(string? hosts)
    {
        using var app = Host("Production", hosts);

        var failure = Assert.ThrowsAny<Exception>(() => app.CreateClient());

        // The message names the setting and the variable that sets it.
        Assert.Contains("HostAllowlist:Hosts is empty", failure.ToString(), StringComparison.Ordinal);
        Assert.Contains("HostAllowlist__Hosts", failure.ToString(), StringComparison.Ordinal);
    }

    [Theory]
    [InlineData("*")]
    [InlineData("*.")]
    [InlineData("www.*.example.com")]
    [InlineData("https://www.example.com")]
    public void AnEntryThatIsNotAHostNameRefusesToStart(string entry)
    {
        using var app = Host("Production", entry);

        var failure = Assert.ThrowsAny<Exception>(() => app.CreateClient());
        Assert.Contains("HostAllowlist:Hosts entry", failure.ToString(), StringComparison.Ordinal);
    }

    [Fact]
    public async Task ARefusalIsASecurityEventThatDoesNotRepeatTheHostOrAnyHeader()
    {
        using var app = Host("Production", Hosts);
        using var client = app.CreateClient();
        using var request = new HttpRequestMessage(HttpMethod.Get, "/api/hello?email=visitor@example.com");
        request.Headers.Host = "evil-host.example";
        request.Headers.Add("Authorization", "Bearer header-secret");
        request.Headers.Add("Cookie", "session=cookie-secret");

        using var response = await client.SendAsync(request, TestContext.Current.CancellationToken);

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
        var logged = Assert.Single(logs.Security);
        Assert.Equal(1007, logged.Id.Id);
        Assert.Equal(LogLevel.Warning, logged.Level);
        Assert.Equal("GET", logged.Values["Method"]);
        Assert.Equal("api", logged.Values["Area"]);
        foreach (var leaked in new[] { "evil-host.example", "visitor@example.com", "header-secret", "cookie-secret", "/api/hello" })
        {
            Assert.DoesNotContain(leaked, logged.Everything, StringComparison.Ordinal);
        }
    }
}

// An environment variable belongs to the whole process, and every other test
// host would read it too — so this runs in a collection of its own, after the
// parallel ones.
[CollectionDefinition(nameof(ProcessEnvironment), DisableParallelization = true)]
public sealed class ProcessEnvironment;

[Collection(nameof(ProcessEnvironment))]
public sealed class HostAllowlistEnvironmentTests
{
    // The mechanism a deployment uses: ONE environment variable, comma-
    // separated, read by the default configuration providers.
    [Fact]
    public async Task TheEnvironmentVariablePopulatesTheList()
    {
        Environment.SetEnvironmentVariable(HostAllowlist.EnvironmentVariable, "from-env.example,*.env.example");
        try
        {
            using var factory = new WebApplicationFactory<Program>();
            using var app = factory.WithWebHostBuilder(builder => builder.UseEnvironment("Production"));
            using var client = app.CreateClient();

            using var exact = await HostAllowlistTests.Get(client, "from-env.example", "/api/hello");
            using var wildcard = await HostAllowlistTests.Get(client, "a.env.example", "/api/hello");
            using var other = await HostAllowlistTests.Get(client, "www.example.com", "/api/hello");

            Assert.Equal(HttpStatusCode.OK, exact.StatusCode);
            Assert.Equal(HttpStatusCode.OK, wildcard.StatusCode);
            Assert.Equal(HttpStatusCode.BadRequest, other.StatusCode);
        }
        finally
        {
            Environment.SetEnvironmentVariable(HostAllowlist.EnvironmentVariable, null);
        }
    }
}
