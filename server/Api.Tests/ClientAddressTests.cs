using System.Net;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc.Testing;
using Xunit;

namespace Api.Tests;

// Who a request came from, tested where it matters: the rate limiter's
// buckets. Every host below allows ONE request per client, so "second request
// refused" means "same client" and "second request served" means "different
// client". An audit of two production apps found every visitor sharing one
// bucket (keyed on the ingress) — and the naive fix, trusting X-Forwarded-For,
// lets any client pick its own bucket. CF-Connecting-IP is the same header
// under Cloudflare's name, and gets the same proof: forged, it moves nothing.
public sealed class ClientAddressTests : IDisposable
{
    private const string Ingress = "10.0.0.7";
    private const string Cdn = "172.64.0.9";
    private readonly WebApplicationFactory<Program> factory = new();

    public void Dispose() => factory.Dispose();

    private async Task<HttpStatusCode> Hello(HttpClient client, string peer, string? forwardedFor = null, string? cfConnectingIp = null)
    {
        using var request = TestPeer.Get("/api/hello", peer, forwardedFor, cfConnectingIp);
        using var response = await client.SendAsync(request, TestContext.Current.CancellationToken);
        return response.StatusCode;
    }

    [Fact]
    public async Task ByDefaultASpoofedForwardedForDoesNotMoveTheKey()
    {
        using var host = TestPeer.Host(factory, ("RATE_LIMIT_PERMIT", "1"));
        using var client = host.CreateClient();

        Assert.Equal(HttpStatusCode.OK, await Hello(client, "203.0.113.5", "1.1.1.1"));
        // Same socket peer, a different claimed address: still the same bucket.
        Assert.Equal(HttpStatusCode.TooManyRequests, await Hello(client, "203.0.113.5", "2.2.2.2"));
        // A different socket peer is a different client.
        Assert.Equal(HttpStatusCode.OK, await Hello(client, "203.0.113.6", "1.1.1.1"));
    }

    [Fact]
    public async Task ByDefaultAForgedCfConnectingIpDoesNotMoveTheKeyEither()
    {
        // Cloudflare writes CF-Connecting-IP for the origin; a client that is
        // not behind Cloudflare can write it just as easily. Nothing here
        // reads it, and this is the test that keeps it that way.
        using var host = TestPeer.Host(factory, ("RATE_LIMIT_PERMIT", "1"));
        using var client = host.CreateClient();

        Assert.Equal(HttpStatusCode.OK, await Hello(client, "203.0.113.5", cfConnectingIp: "1.1.1.1"));
        // Same socket peer, a different claimed address: still the same bucket.
        Assert.Equal(HttpStatusCode.TooManyRequests, await Hello(client, "203.0.113.5", cfConnectingIp: "2.2.2.2"));
        // A different socket peer is a different client.
        Assert.Equal(HttpStatusCode.OK, await Hello(client, "203.0.113.6", cfConnectingIp: "1.1.1.1"));
    }

    [Fact]
    public async Task WithTrustedHopsCfConnectingIpIsStillNotConsulted()
    {
        // Behind the real chain the visitor comes from X-Forwarded-For by hop
        // count. A CF-Connecting-IP that disagrees with the chain buys no new
        // bucket, and on its own, with no chain, neither does it.
        using var host = TestPeer.Host(factory, ("RATE_LIMIT_PERMIT", "1"), ("ForwardedHeaders:TrustedHops", "2"));
        using var client = host.CreateClient();

        Assert.Equal(HttpStatusCode.OK, await Hello(client, Ingress, $"198.51.100.1, {Cdn}", cfConnectingIp: "198.51.100.2"));
        Assert.Equal(HttpStatusCode.TooManyRequests, await Hello(client, Ingress, $"198.51.100.1, {Cdn}", cfConnectingIp: "198.51.100.3"));
        // No X-Forwarded-For at all: the peer is the client, whatever the header claims.
        Assert.Equal(HttpStatusCode.OK, await Hello(client, "10.0.0.8", cfConnectingIp: "198.51.100.4"));
        Assert.Equal(HttpStatusCode.TooManyRequests, await Hello(client, "10.0.0.8", cfConnectingIp: "198.51.100.5"));
    }

    [Fact]
    public async Task WithTwoTrustedHopsTheSecondEntryFromTheRightIsTheClient()
    {
        using var host = TestPeer.Host(factory, ("RATE_LIMIT_PERMIT", "1"), ("ForwardedHeaders:TrustedHops", "2"));
        using var client = host.CreateClient();

        // CDN wrote the client; the ingress appended the CDN; the peer is the ingress.
        Assert.Equal(HttpStatusCode.OK, await Hello(client, Ingress, $"198.51.100.1, {Cdn}"));
        // Every visitor shares the ingress and the CDN, and is still their own client.
        Assert.Equal(HttpStatusCode.OK, await Hello(client, Ingress, $"198.51.100.2, {Cdn}"));
        Assert.Equal(HttpStatusCode.TooManyRequests, await Hello(client, Ingress, $"198.51.100.1, {Cdn}"));
    }

    [Fact]
    public async Task EntriesTheClientAddedOnTheLeftAreIgnored()
    {
        using var host = TestPeer.Host(factory, ("RATE_LIMIT_PERMIT", "1"), ("ForwardedHeaders:TrustedHops", "2"));
        using var client = host.CreateClient();

        Assert.Equal(HttpStatusCode.OK, await Hello(client, Ingress, $"9.9.9.9, 198.51.100.1, {Cdn}"));
        // A new invented prefix each time buys no new bucket.
        Assert.Equal(HttpStatusCode.TooManyRequests, await Hello(client, Ingress, $"8.8.8.8, 7.7.7.7, 198.51.100.1, {Cdn}"));
    }

    [Fact]
    public async Task WithKnownNetworksAHopReportedByAnUnlistedPeerIsNotHonoured()
    {
        using var host = TestPeer.Host(
            factory,
            ("RATE_LIMIT_PERMIT", "1"),
            ("ForwardedHeaders:TrustedHops", "2"),
            ("ForwardedHeaders:KnownProxies:0", Ingress),
            ("ForwardedHeaders:KnownNetworks:0", "172.64.0.0/13"));
        using var client = host.CreateClient();

        // Someone reached the origin directly and claims to be two different visitors.
        Assert.Equal(HttpStatusCode.OK, await Hello(client, "203.0.113.5", $"198.51.100.1, {Cdn}"));
        Assert.Equal(HttpStatusCode.TooManyRequests, await Hello(client, "203.0.113.5", $"198.51.100.2, {Cdn}"));
        // The real chain still resolves.
        Assert.Equal(HttpStatusCode.OK, await Hello(client, Ingress, $"198.51.100.1, {Cdn}"));
        Assert.Equal(HttpStatusCode.TooManyRequests, await Hello(client, Ingress, $"198.51.100.1, {Cdn}"));
    }

    [Fact]
    public async Task IPv6ClientsResolveAndShareABucketPerSlash64()
    {
        using var host = TestPeer.Host(factory, ("RATE_LIMIT_PERMIT", "1"), ("ForwardedHeaders:TrustedHops", "2"));
        using var client = host.CreateClient();

        Assert.Equal(HttpStatusCode.OK, await Hello(client, "fd00::7", "2001:db8:1:2::10, 2606:4700::1"));
        // Bracketed with a port, and another address in the same /64: same subscriber.
        Assert.Equal(HttpStatusCode.TooManyRequests, await Hello(client, "fd00::7", "[2001:db8:1:2:ffff::1]:4711, 2606:4700::1"));
        Assert.Equal(HttpStatusCode.OK, await Hello(client, "fd00::7", "2001:db8:1:3::10, 2606:4700::1"));
    }

    [Theory]
    [InlineData("203.0.113.5", "203.0.113.5")]
    [InlineData("::ffff:203.0.113.5", "203.0.113.5")]
    [InlineData("2001:db8:1:2:3:4:5:6", "2001:db8:1:2::/64")]
    [InlineData(null, "unknown")]
    public void ThePartitionKeyIsTheResolvedAddress(string? remote, string expected)
    {
        var context = new DefaultHttpContext();
        context.Connection.RemoteIpAddress = remote is null ? null : IPAddress.Parse(remote);

        Assert.Equal(expected, ClientAddress.PartitionKey(context));
    }

    [Fact]
    public void ANegativeHopCountRefusesToStart()
    {
        using var host = TestPeer.Host(factory, ("ForwardedHeaders:TrustedHops", "-1"));

        Assert.ThrowsAny<Exception>(() => host.CreateClient());
    }
}
