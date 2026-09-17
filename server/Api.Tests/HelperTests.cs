using System.Security.Cryptography;
using System.Text;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Xunit;

namespace Api.Tests;

public sealed class UrlAllowlistTests
{
    private static readonly UrlAllowlist Allowlist = new(["images.example.com", "cdn.example.net"]);

    [Theory]
    [InlineData("https://images.example.com/a.png")]
    [InlineData("https://IMAGES.example.com/a.png?size=2")]
    [InlineData("https://cdn.example.net/")]
    public void AnHttpsUrlOnAnAllowedHostIsAllowed(string url) => Assert.True(Allowlist.Allows(url));

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("/relative/path.png")]
    [InlineData("http://images.example.com/a.png")] // not https
    [InlineData("javascript:alert(1)")]
    [InlineData("data:image/png;base64,AAAA")]
    [InlineData("https://evil.example/a.png")]
    [InlineData("https://images.example.com.evil.example/a.png")] // allowed host as a prefix
    [InlineData("https://evil.example/images.example.com")] // allowed host in the path
    [InlineData("https://images.example.com@evil.example/a.png")] // allowed host as userinfo
    [InlineData("https://user:pw@images.example.com/a.png")]
    [InlineData("https://images.example.com:8443/a.png")]
    [InlineData("//images.example.com/a.png")]
    public void EverythingElseIsRefused(string? url) => Assert.False(Allowlist.Allows(url));

    [Fact]
    public void AnEmptyAllowlistAllowsNothing() => Assert.False(new UrlAllowlist([]).Allows("https://images.example.com/a.png"));

    [Theory]
    [InlineData("cdn.example; script-src *")]
    [InlineData("https://cdn.example")]
    [InlineData("*.example.com")]
    public void AHostThatIsNotAPlainNameIsRefusedAtStartup(string host) =>
        Assert.Throws<ArgumentException>(() => new UrlAllowlist([host]));

    [Fact]
    public async Task TheSameListBuildsTheImgSrcDirective()
    {
        using var factory = new WebApplicationFactory<Program>().WithWebHostBuilder(builder => builder
            .UseSetting("UrlAllowlist:Hosts:0", "images.example.com")
            .UseSetting("UrlAllowlist:Hosts:1", "cdn.example.net"));
        using var client = factory.CreateClient();

        using var response = await client.GetAsync("/api/hello", TestContext.Current.CancellationToken);

        Assert.Equal(
            "default-src 'self'; base-uri 'self'; form-action 'self'; frame-ancestors 'none'; img-src 'self' https://cdn.example.net https://images.example.com",
            Assert.Single(response.Headers.GetValues("Content-Security-Policy")));
    }
}

public sealed class WebhookSignatureTests
{
    private static readonly byte[] Secret = Encoding.UTF8.GetBytes("whsec_test");
    private static readonly byte[] Body = Encoding.UTF8.GetBytes("""{"event":"paid","amount":100}""");
    private static readonly string Good = Convert.ToHexString(HMACSHA256.HashData(Secret, Body));

    [Fact]
    public void TheRightSignatureVerifies()
    {
        Assert.True(WebhookSignature.IsValid(Secret, Body, Good));
        Assert.True(WebhookSignature.IsValid(Secret, Body, Good.ToLowerInvariant()));
        Assert.True(WebhookSignature.IsValid(Secret, Body, "sha256=" + Good.ToLowerInvariant()));
    }

    [Fact]
    public void ATamperedBodyDoesNot() =>
        Assert.False(WebhookSignature.IsValid(Secret, Encoding.UTF8.GetBytes("""{"event":"paid","amount":999}"""), Good));

    [Fact]
    public void AnotherSecretDoesNot() =>
        Assert.False(WebhookSignature.IsValid(Encoding.UTF8.GetBytes("whsec_other"), Body, Good));

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("sha256=")]
    [InlineData("not hex at all")]
    [InlineData("abcd")] // too short
    [InlineData("zz00000000000000000000000000000000000000000000000000000000000000")] // right length, not hex
    public void AMalformedSignatureIsSimplyInvalid(string? signature) =>
        Assert.False(WebhookSignature.IsValid(Secret, Body, signature));

    [Fact]
    public void ASingleFlippedBitDoesNot()
    {
        var flipped = (Good[0] == '0' ? '1' : '0') + Good[1..];

        Assert.False(WebhookSignature.IsValid(Secret, Body, flipped));
    }

    [Fact]
    public void AnEmptySecretVerifiesNothing() =>
        Assert.False(WebhookSignature.IsValid([], Body, Convert.ToHexString(HMACSHA256.HashData(Array.Empty<byte>(), Body))));
}
