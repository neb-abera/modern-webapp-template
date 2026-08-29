// Maps a route URL to its prerendered HTML file, when one exists. The client
// build writes the static routes to wwwroot as <route>/index.html, but a
// visitor asks for the route; an extensionless GET/HEAD whose prerendered
// file exists is rewritten to that file, and everything else — assets, API
// routes, pages that are not prerendered — is left for the middleware behind
// it. The existence check is a parameter so the decision is testable without
// a filesystem.
namespace Api;

#pragma warning disable CA1515 // public for the test project, which CA1515 cannot know
public static class PrerenderedPages
#pragma warning restore CA1515
{
    public static string? RewriteFor(string requestPath, Func<string, bool> fileExists)
    {
        ArgumentNullException.ThrowIfNull(requestPath);
        ArgumentNullException.ThrowIfNull(fileExists);

        if (requestPath is "/" or "")
        {
            // The default-files middleware already serves index.html here.
            return null;
        }

        if (requestPath.Contains('.', StringComparison.Ordinal))
        {
            // A file request. Prerendered pages live at extensionless routes.
            return null;
        }

        var candidate = requestPath.TrimEnd('/') + "/index.html";
        return fileExists(candidate) ? candidate : null;
    }
}
