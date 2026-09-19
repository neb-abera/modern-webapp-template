using System.Net;
using System.Security.Claims;
using System.Text.Encodings.Web;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.AspNetCore.Routing;
using Microsoft.AspNetCore.TestHost;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using Xunit;
using static Api.Tests.TestIdentity;

namespace Api.Tests;

// The checker: an endpoint must SAY who may call it — AllowAnonymous, or an
// authorization requirement. One that says nothing is reported by its name.
internal static class EndpointAuthorization
{
    public static IReadOnlyList<string> Undeclared(IEnumerable<Endpoint> endpoints) =>
        [.. endpoints
            .Where(endpoint => endpoint.Metadata.GetMetadata<IAllowAnonymous>() is null
                && endpoint.Metadata.GetMetadata<IAuthorizeData>() is null)
            .Select(endpoint => endpoint.DisplayName ?? "(unnamed)")];
}

// A signed-in user for tests, with no sign-in: the X-Test-User header IS the
// user id. Registered only by the test host below. This is the helper the
// first real authorization tests reuse (docs/manual-setup.md, "user B is
// refused user A's object"):
//
//     using var host = TestIdentity.Host(factory);
//     using var alice = TestIdentity.As(host, "alice");
//     using var bob = TestIdentity.As(host, "bob");
internal sealed class TestIdentity(IOptionsMonitor<AuthenticationSchemeOptions> options, ILoggerFactory logger, UrlEncoder encoder)
    : AuthenticationHandler<AuthenticationSchemeOptions>(options, logger, encoder)
{
    public const string Header = "X-Test-User";

    protected override Task<AuthenticateResult> HandleAuthenticateAsync()
    {
        if (!Request.Headers.TryGetValue(Header, out var user))
        {
            return Task.FromResult(AuthenticateResult.NoResult());
        }

        var identity = new ClaimsIdentity([new Claim(ClaimTypes.NameIdentifier, user.ToString())], Scheme.Name);
        return Task.FromResult(AuthenticateResult.Success(new AuthenticationTicket(new ClaimsPrincipal(identity), Scheme.Name)));
    }

    // The deployed app, plus this scheme, plus any endpoints a test needs that
    // the template does not have yet.
    public static WebApplicationFactory<Program> Host(WebApplicationFactory<Program> factory, params Endpoint[] extraEndpoints) =>
        factory.WithWebHostBuilder(builder => builder.ConfigureTestServices(services =>
        {
            services.AddAuthentication("Test").AddScheme<AuthenticationSchemeOptions, TestIdentity>("Test", null);
            services.AddSingleton<IStartupFilter>(new ExtraEndpoints(extraEndpoints));
        }));

    public static HttpClient As(WebApplicationFactory<Program> host, string userId)
    {
        var client = host.CreateClient();
        client.DefaultRequestHeaders.Add(Header, userId);
        return client;
    }

    // The pattern: an object is served to its owner, and to nobody else. 404
    // for another user rather than 403 — a 403 confirms the object exists.
    public static async Task AssertOnlyTheOwnerCanRead(WebApplicationFactory<Program> host, string path, string owner, string someoneElse)
    {
        using var ownerClient = As(host, owner);
        using var otherClient = As(host, someoneElse);
        using var anonymous = host.CreateClient();
        var cancel = TestContext.Current.CancellationToken;

        using var toOwner = await ownerClient.GetAsync(path, cancel);
        using var toOther = await otherClient.GetAsync(path, cancel);
        using var toAnonymous = await anonymous.GetAsync(path, cancel);

        Assert.Equal(HttpStatusCode.OK, toOwner.StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, toOther.StatusCode);
        Assert.Equal(HttpStatusCode.Unauthorized, toAnonymous.StatusCode);
    }

    // An endpoint for Host(): a path, a handler and its metadata (an
    // AuthorizeAttribute, an AllowAnonymousAttribute, or nothing at all).
    public static RouteEndpoint Endpoint(string path, RequestDelegate handler, params object[] metadata) =>
        new(handler, Microsoft.AspNetCore.Routing.Patterns.RoutePatternFactory.Parse(path), 0, new EndpointMetadataCollection(metadata), path);

    // Program maps the real endpoints; a test cannot add to them. Selecting an
    // endpoint before routing runs has the same effect — routing stands down
    // when one is already chosen — so these pass through the app's own
    // limiter, authorization and handlers exactly as a mapped endpoint would.
    internal sealed class ExtraEndpoints(params Endpoint[] endpoints) : IStartupFilter
    {
        public Action<IApplicationBuilder> Configure(Action<IApplicationBuilder> next) => app =>
        {
            app.Use((context, following) =>
            {
                var match = endpoints.OfType<RouteEndpoint>()
                    .FirstOrDefault(endpoint => endpoint.RoutePattern.RawText == context.Request.Path);
                if (match is not null)
                {
                    context.SetEndpoint(match);
                }

                return following(context);
            });
            next(app);
        };
    }
}

public sealed class AuthorizationTests : IDisposable
{
    private readonly WebApplicationFactory<Program> factory = new();
    private readonly CapturedLogs logs = new();

    public void Dispose()
    {
        factory.Dispose();
        logs.Dispose();
    }

    private static readonly RequestDelegate Ok = context =>
    {
        context.Response.StatusCode = StatusCodes.Status200OK;
        return Task.CompletedTask;
    };

    [Fact]
    public void EveryEndpointDeclaresWhoMayCallIt()
    {
        var endpoints = factory.Services.GetRequiredService<EndpointDataSource>().Endpoints;

        Assert.NotEmpty(endpoints);
        Assert.Empty(EndpointAuthorization.Undeclared(endpoints));
    }

    // The checker's own negative test: an endpoint mapped the way one is
    // mapped when nobody thinks about authorization must be reported.
    [Fact]
    public async Task TheCheckReportsAnEndpointThatDeclaresNothing()
    {
        await using var app = WebApplication.CreateSlimBuilder().Build();
        app.MapGet("/forgotten", () => "anyone?");
        app.MapGet("/public", () => "hello").AllowAnonymous();
        app.MapGet("/private", () => "secret").RequireAuthorization();

        var endpoints = ((IEndpointRouteBuilder)app).DataSources.SelectMany(source => source.Endpoints);

        Assert.Equal(["HTTP: GET /forgotten"], EndpointAuthorization.Undeclared(endpoints));
    }

    [Fact]
    public async Task AnEndpointThatDeclaresNothingIsClosedAtRuntimeToo()
    {
        using var host = CapturedLogs.Attach(TestIdentity.Host(factory, Endpoint("/_test/forgotten", Ok)), logs);
        using var anonymous = host.CreateClient();
        using var alice = TestIdentity.As(host, "alice");

        using var refused = await anonymous.GetAsync("/_test/forgotten", TestContext.Current.CancellationToken);
        using var served = await alice.GetAsync("/_test/forgotten", TestContext.Current.CancellationToken);

        Assert.Equal(HttpStatusCode.Unauthorized, refused.StatusCode);
        Assert.Equal(HttpStatusCode.OK, served.StatusCode);
        var logged = Assert.Single(logs.Security);
        Assert.Equal(1002, logged.Id.Id);
        Assert.Equal("/_test/forgotten", logged.Values["Route"]);
    }

    [Fact]
    public async Task ItIsClosedBeforeAnyAuthenticationSchemeExists()
    {
        // The template as shipped: no scheme to challenge, and still a 401
        // rather than the framework's exception.
        using var host = factory.WithWebHostBuilder(builder => builder.ConfigureTestServices(services =>
            services.AddSingleton<IStartupFilter>(new TestIdentity.ExtraEndpoints(Endpoint("/_test/forgotten", Ok)))));
        using var client = host.CreateClient();

        using var refused = await client.GetAsync("/_test/forgotten", TestContext.Current.CancellationToken);

        Assert.Equal(HttpStatusCode.Unauthorized, refused.StatusCode);
    }

    [Fact]
    public async Task AForbiddenUserIs403AndLoggedByIdOnly()
    {
        var adminsOnly = Endpoint("/_test/admin", Ok, new AuthorizeAttribute { Roles = "admin" });
        using var host = CapturedLogs.Attach(TestIdentity.Host(factory, adminsOnly), logs);
        using var alice = TestIdentity.As(host, "alice");

        using var refused = await alice.GetAsync("/_test/admin", TestContext.Current.CancellationToken);

        Assert.Equal(HttpStatusCode.Forbidden, refused.StatusCode);
        var logged = Assert.Single(logs.Security);
        Assert.Equal(1003, logged.Id.Id);
        Assert.Equal("alice", logged.Values["UserId"]);
    }

    [Fact]
    public async Task AMissingFileIsStill404NotARefusal()
    {
        using var host = CapturedLogs.Attach(factory, logs);
        using var client = host.CreateClient();

        using var response = await client.GetAsync("/favicon.ico", TestContext.Current.CancellationToken);

        Assert.Equal(HttpStatusCode.NotFound, response.StatusCode);
        Assert.Empty(logs.Security);
    }

    // The IDOR pattern, run against a stand-in until the template has an
    // object to own: alice's note is served to alice and to nobody else.
    [Fact]
    public async Task UserBIsRefusedUserAsObject()
    {
        var alicesNote = Endpoint("/_test/notes/1", context =>
        {
            var isOwner = context.User.FindFirstValue(ClaimTypes.NameIdentifier) == "alice";
            context.Response.StatusCode = isOwner ? StatusCodes.Status200OK : StatusCodes.Status404NotFound;
            return Task.CompletedTask;
        });
        using var host = TestIdentity.Host(factory, alicesNote);

        await TestIdentity.AssertOnlyTheOwnerCanRead(host, "/_test/notes/1", owner: "alice", someoneElse: "bob");
    }
}
