using System.Net;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.AspNetCore.TestHost;
using Microsoft.Extensions.DependencyInjection;

namespace Api.Tests;

// TestServer has no socket, so a request has no peer address. This filter
// gives it one — from the X-Test-Peer header — at the very front of the
// pipeline, where a real connection's address would already be set. It stands
// in for the network, which is the one thing a client cannot forge.
internal sealed class TestPeer : IStartupFilter
{
    public const string Header = "X-Test-Peer";

    public Action<IApplicationBuilder> Configure(Action<IApplicationBuilder> next) => app =>
    {
        app.Use((context, following) =>
        {
            if (context.Request.Headers.TryGetValue(Header, out var peer))
            {
                context.Connection.RemoteIpAddress = IPAddress.Parse(peer.ToString());
            }

            return following(context);
        });
        next(app);
    };

    // The app as deployed, with a settable peer and the given settings
    // (the same keys an environment variable or appsettings.json would set).
    public static WebApplicationFactory<Program> Host(
        WebApplicationFactory<Program> factory, params (string Key, string Value)[] settings) =>
        factory.WithWebHostBuilder(builder =>
        {
            foreach (var (key, value) in settings)
            {
                builder.UseSetting(key, value);
            }

            builder.ConfigureTestServices(services => services.AddTransient<IStartupFilter, TestPeer>());
        });

    public static HttpRequestMessage Get(string path, string peer, string? forwardedFor = null)
    {
        var request = new HttpRequestMessage(HttpMethod.Get, path);
        request.Headers.Add(Header, peer);
        if (forwardedFor is not null)
        {
            request.Headers.Add("X-Forwarded-For", forwardedFor);
        }

        return request;
    }
}
