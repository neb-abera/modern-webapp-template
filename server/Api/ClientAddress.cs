// The one place the visitor's address is decided. The rate limiter's partition
// key and the security event log both read it from here, so they cannot
// disagree about who a request came from.
//
// Behind a proxy chain the socket peer is the last proxy, and every visitor
// shares it: keyed on that, one visitor's burst spends everyone's permits. The
// real address is in X-Forwarded-For — a header any client can also write. What
// makes it trustworthy is counting hops from the right: each proxy appends the
// peer it saw, so with N trusted proxies the Nth entry from the right was
// written by infrastructure, and everything left of it is whatever the client
// cared to send. ForwardedHeaders:TrustedHops is that N.
//
//   0 (the default)  nothing is trusted; the socket peer is the client.
//                    Correct for local runs, and safe anywhere.
//   2                CDN -> cloud ingress -> app (docs/deploying.md).
//
// Hop counting alone is sound only while the origin is unreachable except
// through those proxies. ForwardedHeaders:KnownProxies / KnownNetworks add the
// second lock: once either is set, a hop is honoured only when the address
// that reported it is listed.
using System.Net;
using Microsoft.AspNetCore.HttpOverrides;

namespace Api;

internal static class ClientAddress
{
    public static void Configure(ForwardedHeadersOptions options, IConfiguration configuration)
    {
        var section = configuration.GetSection("ForwardedHeaders");
        var trustedHops = section.GetValue<int?>("TrustedHops") ?? 0;
        ArgumentOutOfRangeException.ThrowIfNegative(trustedHops);

        // The framework defaults trust loopback; this list is explicit or empty.
        options.KnownProxies.Clear();
        options.KnownIPNetworks.Clear();

        if (trustedHops == 0)
        {
            options.ForwardedHeaders = ForwardedHeaders.None;
            return;
        }

        options.ForwardedHeaders = ForwardedHeaders.XForwardedFor | ForwardedHeaders.XForwardedProto;
        options.ForwardLimit = trustedHops;
        foreach (var proxy in section.GetSection("KnownProxies").Get<string[]>() ?? [])
        {
            options.KnownProxies.Add(IPAddress.Parse(proxy));
        }

        foreach (var network in section.GetSection("KnownNetworks").Get<string[]>() ?? [])
        {
            options.KnownIPNetworks.Add(System.Net.IPNetwork.Parse(network));
        }
    }

    // After UseForwardedHeaders has run, Connection.RemoteIpAddress is the
    // resolved client. An IPv4 peer on a dual-stack socket arrives as
    // ::ffff:a.b.c.d; it is the same visitor as a.b.c.d.
    public static IPAddress? Resolve(HttpContext context)
    {
        var address = context.Connection.RemoteIpAddress;
        return address is { IsIPv4MappedToIPv6: true } ? address.MapToIPv4() : address;
    }

    // One bucket per IPv4 address, one per IPv6 /64: a single IPv6 subscriber
    // is routinely handed a whole /64, so keying on the full address gives one
    // visitor 2^64 buckets.
    public static string PartitionKey(HttpContext context)
    {
        var address = Resolve(context);
        if (address is null)
        {
            return "unknown";
        }

        if (address.AddressFamily != System.Net.Sockets.AddressFamily.InterNetworkV6)
        {
            return address.ToString();
        }

        var bytes = address.GetAddressBytes();
        Array.Clear(bytes, 8, 8);
        return new IPAddress(bytes) + "/64";
    }
}
