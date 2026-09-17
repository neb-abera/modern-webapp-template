// Which Host headers the app answers to. Anything else is a 400 with no body:
// a Host nobody configured is how password-reset links, absolute redirects and
// cache keys get pointed at someone else's domain.
//
// This replaces the framework's AllowedHosts filtering (appsettings.json sets
// that to "*" and says why) for one reason: that filter sits at the front of
// the pipeline and cannot exempt a path. Platform health probes — Azure
// Container Apps, Kubernetes — address the container by pod IP, a name nobody
// can list in advance, so a filter that cannot let them through risks a
// revision that never turns ready. Here the health route is answered whatever
// the Host; it says "Healthy" and nothing else, so there is nothing to poison.
//
// One setting, one string: HostAllowlist:Hosts (env HostAllowlist__Hosts),
// comma-separated. A single value rather than an indexed array because every
// place that sets it — a compose file, a deploy command, a repository
// variable — can express one string, and none of them can loop.
//
//   www.example.com   exactly that name
//   *.example.io      any subdomain. The dot belongs to the suffix, so
//                     notexample.io does not match; nor does example.io
//                     itself — list it too if it is served.
//
// Names are compared without regard to case; the port is not part of the name.
//
// An empty list means "no filtering" in Development only, so local work and
// the test host need no configuration. Anywhere else it refuses to start: an
// unset variable interpolated into a deploy command must stop the deploy, not
// open the app to every Host.
namespace Api;

internal sealed class HostAllowlist
{
    public const string Setting = "HostAllowlist:Hosts";
    public const string EnvironmentVariable = "HostAllowlist__Hosts";

    private readonly HashSet<string> exact = new(StringComparer.OrdinalIgnoreCase);
    private readonly List<string> suffixes = [];

    public HostAllowlist(string? hosts)
    {
        foreach (var entry in (hosts ?? string.Empty).Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries))
        {
            var wildcard = entry.StartsWith("*.", StringComparison.Ordinal);
            var name = wildcard ? entry[2..] : entry;
            if (Uri.CheckHostName(name) == UriHostNameType.Unknown || name.Contains('*', StringComparison.Ordinal))
            {
                throw new InvalidOperationException(
                    $"{Setting} entry '{entry}' is neither a host name nor '*.' followed by one.");
            }

            if (wildcard)
            {
                suffixes.Add(entry[1..]); // ".example.io": the dot is part of the suffix
            }
            else
            {
                exact.Add(entry);
            }
        }
    }

    public bool IsEmpty => exact.Count == 0 && suffixes.Count == 0;

    public bool Allows(string host) =>
        exact.Contains(host)
        || suffixes.Exists(suffix => host.Length > suffix.Length && host.EndsWith(suffix, StringComparison.OrdinalIgnoreCase));
}

internal static class HostAllowlistExtensions
{
    public static IApplicationBuilder UseHostAllowlist(this WebApplication app, params string[] exemptPaths)
    {
        var allowlist = new HostAllowlist(app.Configuration[HostAllowlist.Setting]);
        if (allowlist.IsEmpty)
        {
            // The build runs this program once to emit openapi.json
            // (Microsoft.Extensions.ApiDescription.Server), with a server that
            // never listens and no environment of its own. Nothing can be
            // asked of it, so there is nothing to filter — and failing here
            // would fail every build.
            var emittingOpenApi = System.Reflection.Assembly.GetEntryAssembly()?.GetName().Name == "GetDocument.Insider";
            if (!app.Environment.IsDevelopment() && !emittingOpenApi)
            {
                throw new InvalidOperationException(
                    $"{HostAllowlist.Setting} is empty, and outside Development that would answer every Host header. "
                    + $"Set the {HostAllowlist.EnvironmentVariable} environment variable to the host names this app serves, "
                    + "comma-separated (www.example.com,*.example.io); see docs/deploying.md.");
            }

            return app;
        }

        return app.Use((context, next) =>
        {
            var path = context.Request.Path;
            if (allowlist.Allows(context.Request.Host.Host)
                || Array.Exists(exemptPaths, exempt => path.Equals(exempt, StringComparison.OrdinalIgnoreCase)))
            {
                return next(context);
            }

            // Not the offending Host itself: it is attacker-chosen text, and
            // the log is not the place to let a stranger write.
            SecurityEvents.HostRejected(
                SecurityEvents.Logger(context),
                context.Request.Method,
                path.StartsWithSegments("/api", StringComparison.OrdinalIgnoreCase) ? "api" : "page",
                SecurityEvents.Client(context));
            context.Response.StatusCode = StatusCodes.Status400BadRequest;
            return Task.CompletedTask;
        });
    }
}
