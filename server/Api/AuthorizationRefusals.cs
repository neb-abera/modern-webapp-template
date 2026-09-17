// Authorization is on before there is anything to sign in to. The fallback
// policy (Program.cs) requires an authenticated user on every endpoint that
// does not say otherwise, so an endpoint is public because someone wrote
// AllowAnonymous on it and never because someone forgot. This is what makes
// that work with no authentication scheme registered — the framework's own
// handler would throw trying to challenge — and it is where 401 and 403
// become security events.
//
// The day a scheme is added (AddAuthentication().AddCookie(...)), nothing here
// changes: with a scheme to challenge, the framework's handler takes over and
// produces that scheme's redirect or 401. The events keep firing.
using System.Security.Claims;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Authorization.Policy;

namespace Api;

internal sealed class AuthorizationRefusals : IAuthorizationMiddlewareResultHandler
{
    private readonly AuthorizationMiddlewareResultHandler framework = new();

    public async Task HandleAsync(
        RequestDelegate next, HttpContext context, AuthorizationPolicy policy, PolicyAuthorizationResult authorizeResult)
    {
        // No route matched, so there is nothing to protect: static files were
        // served before routing, and what follows is the 404. Without this a
        // missing favicon is a 401 and a security event per visitor.
        if (authorizeResult.Succeeded || context.GetEndpoint() is null)
        {
            await next(context).ConfigureAwait(false);
            return;
        }

        var logger = SecurityEvents.Logger(context);
        var (method, route, client) = (context.Request.Method, SecurityEvents.Route(context), SecurityEvents.Client(context));
        if (authorizeResult.Challenged)
        {
            SecurityEvents.AuthenticationRequired(logger, method, route, client);
        }
        else
        {
            var userId = context.User.FindFirstValue(ClaimTypes.NameIdentifier) ?? "unknown";
            SecurityEvents.AccessDenied(logger, method, route, client, userId);
        }

        var schemes = context.RequestServices.GetService<IAuthenticationSchemeProvider>();
        var canChallenge = policy.AuthenticationSchemes.Count > 0
            || (schemes is not null && await schemes.GetDefaultChallengeSchemeAsync().ConfigureAwait(false) is not null);
        if (canChallenge)
        {
            await framework.HandleAsync(next, context, policy, authorizeResult).ConfigureAwait(false);
            return;
        }

        context.Response.StatusCode = authorizeResult.Challenged
            ? StatusCodes.Status401Unauthorized
            : StatusCodes.Status403Forbidden;
    }
}
