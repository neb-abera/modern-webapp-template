using System.Collections.Concurrent;
using System.Net;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.AspNetCore.TestHost;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using Xunit;

namespace Api.Tests;

// Everything logged while a test host runs, as the structured values a log
// pipeline receives — not only the rendered text.
internal sealed class CapturedLogs : ILoggerProvider
{
    public ConcurrentQueue<Entry> Entries { get; } = new();

    public IEnumerable<Entry> Security => Entries.Where(entry => entry.Category == SecurityEvents.Category);

    public ILogger CreateLogger(string categoryName) => new Capture(categoryName, Entries);

    public void Dispose()
    {
    }

    public static WebApplicationFactory<Program> Attach(WebApplicationFactory<Program> factory, CapturedLogs logs) =>
        factory.WithWebHostBuilder(builder =>
            builder.ConfigureTestServices(services => services.AddSingleton<ILoggerProvider>(logs)));

    internal sealed record Entry(string Category, LogLevel Level, EventId Id, string Message, IReadOnlyDictionary<string, object?> Values)
    {
        // Every string this event hands to a log sink, rendered or structured.
        public string Everything => Message + "\n" + string.Join("\n", Values.Select(pair => $"{pair.Key}={pair.Value}"));
    }

    private sealed class Capture(string category, ConcurrentQueue<Entry> entries) : ILogger
    {
        public IDisposable? BeginScope<TState>(TState state) where TState : notnull => null;

        public bool IsEnabled(LogLevel logLevel) => true;

        public void Log<TState>(LogLevel logLevel, EventId eventId, TState state, Exception? exception, Func<TState, Exception?, string> formatter)
        {
            var values = state is IEnumerable<KeyValuePair<string, object?>> pairs
                ? pairs.ToDictionary(pair => pair.Key, pair => pair.Value)
                : [];
            entries.Enqueue(new Entry(category, logLevel, eventId, formatter(state, exception), values));
        }
    }
}

public sealed class SecurityEventTests : IDisposable
{
    private readonly WebApplicationFactory<Program> factory = new();
    private readonly CapturedLogs logs = new();

    public void Dispose()
    {
        factory.Dispose();
        logs.Dispose();
    }

    [Fact]
    public async Task ARateLimitRejectionIsLoggedWithTheRouteAndTheResolvedClient()
    {
        using var host = CapturedLogs.Attach(
            TestPeer.Host(factory, ("RATE_LIMIT_PERMIT", "1"), ("ForwardedHeaders:TrustedHops", "1")), logs);
        using var client = host.CreateClient();

        async Task<HttpResponseMessage> Hello()
        {
            using var request = TestPeer.Get("/api/hello?email=visitor@example.com&token=query-secret", "10.0.0.7", "198.51.100.1");
            request.Headers.Add("Authorization", "Bearer header-secret");
            request.Headers.Add("Cookie", "session=cookie-secret");
            return await client.SendAsync(request, TestContext.Current.CancellationToken);
        }

        using var first = await Hello();
        Assert.Empty(logs.Security);

        using var refused = await Hello();
        Assert.Equal(HttpStatusCode.TooManyRequests, refused.StatusCode);
        Assert.True(refused.Headers.RetryAfter?.Delta > TimeSpan.Zero, "a 429 says when to come back");

        var logged = Assert.Single(logs.Security);
        Assert.Equal(1001, logged.Id.Id);
        Assert.Equal(LogLevel.Warning, logged.Level);
        Assert.Equal("GET", logged.Values["Method"]);
        Assert.Equal("/api/hello", logged.Values["Route"]);
        // The visitor, not the proxy the socket belongs to.
        Assert.Equal("198.51.100.1", logged.Values["ClientAddress"]);

        // And what it leaves out: the query string, headers, cookies.
        foreach (var secret in new[] { "visitor@example.com", "query-secret", "header-secret", "cookie-secret", "?" })
        {
            Assert.DoesNotContain(secret, logged.Everything, StringComparison.Ordinal);
        }
    }

    // Alerts and saved queries are written against these numbers. Changing
    // one is a breaking change to whoever operates the app; adding a row
    // means adding it to SECURITY.md too.
    [Fact]
    public void EventIdsAreStable()
    {
        using var provider = new CapturedLogs();
        var logger = provider.CreateLogger(SecurityEvents.Category);

        SecurityEvents.RateLimitRejected(logger, "GET", "/r", "c");
        SecurityEvents.AuthenticationRequired(logger, "GET", "/r", "c");
        SecurityEvents.AccessDenied(logger, "GET", "/r", "c", "user-1");
        SecurityEvents.AntiforgeryRejected(logger, "POST", "/r", "c");
        SecurityEvents.SignInRefused(logger, SignInRefusal.BadCredentials, "c");
        SecurityEvents.WebhookSignatureRejected(logger, "/r", "c");
        SecurityEvents.HostRejected(logger, "GET", "api", "c");

        Assert.Equal(
            [
                (1001, "RateLimitRejected"),
                (1002, "AuthenticationRequired"),
                (1003, "AccessDenied"),
                (1004, "AntiforgeryRejected"),
                (1005, "SignInRefused"),
                (1006, "WebhookSignatureRejected"),
                (1007, "HostRejected"),
            ],
            provider.Entries.Select(entry => (entry.Id.Id, entry.Id.Name!)));
        Assert.All(provider.Entries, entry => Assert.Equal(LogLevel.Warning, entry.Level));
    }
}
