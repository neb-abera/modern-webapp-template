// Which external URLs the app will store, fetch or show. The first feature
// that accepts a URL from a user (an avatar, a webhook target, a link
// preview) otherwise hand-rolls this check, and the hand-rolled one accepts
// http://, or javascript:, or https://trusted.example@evil.example/.
//
// One list, UrlAllowlist:Hosts, used twice: Allows() decides what may be
// stored, and ImgSrcDirective is what Program.cs appends to the
// Content-Security-Policy — so a host cannot be storable but blocked by the
// browser, or the other way round. Empty by default: no external URL is
// allowed, and the CSP stays default-src 'self'.
namespace Api;

internal sealed class UrlAllowlist
{
    private readonly HashSet<string> hosts;

    public UrlAllowlist(IEnumerable<string> hosts)
    {
        this.hosts = new HashSet<string>(hosts, StringComparer.OrdinalIgnoreCase);
        foreach (var host in this.hosts)
        {
            // Exact DNS names only. This value is written into a response
            // header, so "cdn.example; script-src *" must not get that far.
            if (Uri.CheckHostName(host) != UriHostNameType.Dns)
            {
                throw new ArgumentException($"UrlAllowlist:Hosts entry '{host}' is not a plain host name.", nameof(hosts));
            }
        }
    }

    public static UrlAllowlist From(IConfiguration configuration) =>
        new(configuration.GetSection("UrlAllowlist:Hosts").Get<string[]>() ?? []);

    // https, an allowlisted host, the default port, and no user:password@ —
    // the part of a URL that exists to make one host look like another.
    public bool Allows(string? url) =>
        Uri.TryCreate(url, UriKind.Absolute, out var uri)
        && uri.Scheme == Uri.UriSchemeHttps
        && uri.UserInfo.Length == 0
        && uri.IsDefaultPort
        && hosts.Contains(uri.IdnHost);

    public string ImgSrcDirective =>
        hosts.Count == 0 ? string.Empty : "; img-src 'self' " + string.Join(' ', hosts.Order(StringComparer.Ordinal).Select(host => $"https://{host}"));
}
