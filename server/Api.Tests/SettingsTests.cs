using System.Net;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.AspNetCore.Server.Kestrel.Core;
using Microsoft.AspNetCore.TestHost;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using Xunit;

namespace Api.Tests;

// server/Api/appsettings.json, as behaviour. Without that file the framework's
// defaults apply silently: a request body may be 28.6 MB on every endpoint,
// and the log level hides authorization failures. (Which Host headers are
// answered is HostAllowlistTests.)
public sealed class SettingsTests : IDisposable
{
    private readonly WebApplicationFactory<Program> factory = new();

    public void Dispose() => factory.Dispose();

    // The body limit is Kestrel's, and TestServer is not Kestrel: this one test
    // starts the real server on a free port. The probe endpoint only reads the
    // body, which is when the limit is enforced.
    [Fact]
    public async Task ARequestBodyOverOneMegabyteIs413()
    {
        using var host = factory.WithWebHostBuilder(builder =>
            builder.ConfigureTestServices(services => services.AddTransient<IStartupFilter, ReadsTheBody>()));
        // An explicit endpoint: the SDK image's ASPNETCORE_HTTP_PORTS would
        // otherwise put every such test on the same fixed port.
        host.UseKestrel(kestrel => kestrel.Listen(IPAddress.Loopback, 0));
        host.StartServer();
        using var client = host.CreateClient();

        async Task<HttpStatusCode> Post(int bytes)
        {
            using var request = new HttpRequestMessage(HttpMethod.Post, "/_test/read-body")
            {
                Content = new ByteArrayContent(new byte[bytes]),
            };
            // The server answers before the upload starts, instead of
            // resetting the connection halfway through it.
            request.Headers.ExpectContinue = true;
            using var response = await client.SendAsync(request, TestContext.Current.CancellationToken);
            return response.StatusCode;
        }

        Assert.Equal(HttpStatusCode.OK, await Post(1024 * 1024));
        Assert.Equal(HttpStatusCode.RequestEntityTooLarge, await Post((1024 * 1024) + 1));
    }

    [Fact]
    public void TheBodyLimitIsTheConfiguredOne()
    {
        var limits = factory.Services.GetRequiredService<IOptions<KestrelServerOptions>>().Value.Limits;

        Assert.Equal(1024 * 1024, limits.MaxRequestBodySize);
    }

    [Theory]
    // Refused sign-ins and authorization failures are logged at Information by
    // the framework; the usual "Microsoft.AspNetCore": "Warning" hides them.
    [InlineData("Microsoft.AspNetCore.Authorization.DefaultAuthorizationService", LogLevel.Information, true)]
    [InlineData("Microsoft.AspNetCore.Authentication.Cookies.CookieAuthenticationHandler", LogLevel.Information, true)]
    // Per-request framework chatter stays off.
    [InlineData("Microsoft.AspNetCore.Routing.EndpointMiddleware", LogLevel.Information, false)]
    [InlineData("Microsoft.AspNetCore.Routing.EndpointMiddleware", LogLevel.Warning, true)]
    [InlineData("Api.Anything", LogLevel.Information, true)]
    [InlineData("Api.Anything", LogLevel.Debug, false)]
    public void LogLevelsAreDeliberate(string category, LogLevel level, bool enabled)
    {
        var logger = factory.Services.GetRequiredService<ILoggerFactory>().CreateLogger(category);

        Assert.Equal(enabled, logger.IsEnabled(level));
    }

    private sealed class ReadsTheBody : IStartupFilter
    {
        public Action<IApplicationBuilder> Configure(Action<IApplicationBuilder> next) => app =>
        {
            app.Map("/_test/read-body", branch => branch.Run(context => context.Request.Body.CopyToAsync(Stream.Null)));
            next(app);
        };
    }
}
