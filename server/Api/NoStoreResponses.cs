// Cache-Control: no-store on every response that is an answer rather than a
// file: the health route and the API.
//
// Found on abera.tech, 2026-09-21: /healthz was served from the CDN edge with
// an age of 83,725 seconds. Nothing on the origin wrote a Cache-Control
// header for it, the edge's cache rule filled the gap, and for the length of
// that TTL an outage would have answered 200 to every probe. The static
// middleware decides the header for files (Program.cs); this is the same
// decision for endpoints, made once so a new route cannot forget it.
//
// The edge honours it only where its own rule does not override the origin,
// so the cache rule excludes these paths as well (docs/manual-setup.md).
namespace Api;

internal static class NoStoreResponses
{
    public const string Header = "no-store";

    private static readonly PathString[] Paths = [HealthRoute.Path, "/api"];

    public static bool Applies(PathString path) =>
        Array.Exists(Paths, prefix => path.StartsWithSegments(prefix));

    public static IApplicationBuilder UseNoStoreResponses(this IApplicationBuilder app) =>
        app.Use((context, next) =>
        {
            if (Applies(context.Request.Path))
            {
                context.Response.Headers.CacheControl = Header;
            }

            return next();
        });
}
