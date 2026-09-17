// The security event log: the handful of things an operator needs to be able
// to count, alert on and investigate, each with an EventId that never changes
// (alerts and saved queries are written against the number). SECURITY.md has
// the table.
//
// What an event may carry: the HTTP method, the ROUTE PATTERN (/api/notes/{id},
// never the path that matched it, which holds identifiers, and never the query
// string), the resolved client address (ClientAddress — the same one the rate
// limiter used), and an opaque user id where there is one. Never a header, a
// cookie, a body, a token, an email address or a name: the log is read by more
// people than the database is. The parameters are typed so that the wrong
// thing is awkward to pass.
//
// 1001-1003 are raised by this template today (the limiter, and
// AuthorizationRefusals). The rest are here so the code that first needs them
// finds a name and a number waiting: the first sign-in
// endpoint calls SignInRefused, the first webhook calls
// WebhookSignatureRejected, the first form post wires AntiforgeryRejected.
// docs/manual-setup.md says where.
using Microsoft.AspNetCore.Routing;

namespace Api;

internal static partial class SecurityEvents
{
    public const string Category = "Api.SecurityEvents";

    public static ILogger Logger(HttpContext context) =>
        context.RequestServices.GetRequiredService<ILoggerFactory>().CreateLogger(Category);

    public static string Route(HttpContext context) =>
        (context.GetEndpoint() as RouteEndpoint)?.RoutePattern.RawText ?? "(no endpoint)";

    public static string Client(HttpContext context) =>
        ClientAddress.Resolve(context)?.ToString() ?? "unknown";

    [LoggerMessage(EventId = 1001, EventName = nameof(RateLimitRejected), Level = LogLevel.Warning,
        Message = "Rate limit rejected {Method} {Route} from {ClientAddress}")]
    public static partial void RateLimitRejected(ILogger logger, string method, string route, string clientAddress);

    [LoggerMessage(EventId = 1002, EventName = nameof(AuthenticationRequired), Level = LogLevel.Warning,
        Message = "401 for {Method} {Route} from {ClientAddress}")]
    public static partial void AuthenticationRequired(ILogger logger, string method, string route, string clientAddress);

    [LoggerMessage(EventId = 1003, EventName = nameof(AccessDenied), Level = LogLevel.Warning,
        Message = "403 for {Method} {Route} from {ClientAddress}, user {UserId}")]
    public static partial void AccessDenied(ILogger logger, string method, string route, string clientAddress, string userId);

    [LoggerMessage(EventId = 1004, EventName = nameof(AntiforgeryRejected), Level = LogLevel.Warning,
        Message = "Antiforgery validation failed for {Method} {Route} from {ClientAddress}")]
    public static partial void AntiforgeryRejected(ILogger logger, string method, string route, string clientAddress);

    [LoggerMessage(EventId = 1005, EventName = nameof(SignInRefused), Level = LogLevel.Warning,
        Message = "Sign-in refused ({Reason}) from {ClientAddress}")]
    public static partial void SignInRefused(ILogger logger, SignInRefusal reason, string clientAddress);

    [LoggerMessage(EventId = 1006, EventName = nameof(WebhookSignatureRejected), Level = LogLevel.Warning,
        Message = "Webhook signature rejected for {Route} from {ClientAddress}")]
    public static partial void WebhookSignatureRejected(ILogger logger, string route, string clientAddress);
}

// An enum, not a string: a free-text reason is where the attempted user name
// ends up.
internal enum SignInRefusal
{
    BadCredentials,
    LockedOut,
    NotAllowed,
}
