// /.well-known/security.txt (RFC 9116): where to report a vulnerability, the
// same two channels SECURITY.md names. scripts/setup.sh points the advisory
// URL at the generated repository.
//
// Served by the app rather than shipped as a file because the RFC requires
// an Expires line no more than a year out, and a file's date is whatever it
// was on the day of the build. Expires is a year from the request, to the
// day, so the text changes once a day and caches for a day.
using System.Globalization;

namespace Api;

internal static class SecurityTxt
{
    public const string Path = "/.well-known/security.txt";

    public const string Contact = "mailto:support@alias.abera.tech";
    public const string Advisories = "https://github.com/neb-abera/modern-webapp-template/security/advisories/new";
    public const string Policy = "https://github.com/neb-abera/modern-webapp-template/blob/main/SECURITY.md";

    public static string Render(DateTimeOffset now)
    {
        var expires = new DateTimeOffset(now.UtcDateTime.Date, TimeSpan.Zero).AddYears(1);
        return $"""
            Contact: {Advisories}
            Contact: {Contact}
            Expires: {expires.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture)}
            Preferred-Languages: en
            Policy: {Policy}

            """;
    }

    // Unlimited like the static files it stands beside: it is a file that
    // happens to be rendered, and a scanner fetching it is not a spike.
    public static IEndpointRouteBuilder MapSecurityTxt(this IEndpointRouteBuilder routes)
    {
        routes.MapGet(Path, (TimeProvider clock, HttpContext context) =>
        {
            context.Response.Headers.CacheControl = "public, max-age=86400";
            return Results.Text(Render(clock.GetUtcNow()), "text/plain; charset=utf-8");
        }).DisableRateLimiting().AllowAnonymous().ExcludeFromDescription();

        return routes;
    }
}
