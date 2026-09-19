using System.Net;
using System.Net.Mime;
using System.Security.Claims;
using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.AspNetCore.Routing;
using Microsoft.Extensions.DependencyInjection;
using Xunit;

namespace Api.Tests;

// The runtime half of response-DTO discipline. scripts/check-response-pii.sh
// reads the committed OpenAPI document, and that document only describes
// what the code declares: an endpoint that returns an entity through an
// untyped Results.Ok, or writes JSON by hand, has no schema there and passes
// it unseen. This half calls the endpoints and reads what actually comes
// back. Same denylist file, same allowlist file. The static gate keeps the
// per-schema precision (Profile.email); this one matches the field name
// wherever it appears, because a hand-written response has no schema name
// to match — and a name allowlisted for one schema turning up on another is
// already the static gate's failure.
internal static class ResponsePii
{
    public static string Normalize(string name) =>
        string.Concat(name.ToLowerInvariant().Where(char.IsAsciiLetterOrDigit));

    // The tokens in server/Api/response-pii-denylist.txt (one per line,
    // comments and blanks ignored), as the same regex check-response-pii.mjs
    // builds from the same file. A name is matched lowercased with
    // punctuation removed, so emailAddress, email_address and EMail all
    // match "email".
    public static Regex Denylist(IEnumerable<string> lines)
    {
        var tokens = lines.Select(line => line.Trim())
            .Where(line => line.Length > 0 && !line.StartsWith('#'))
            .Select(Normalize)
            .ToList();
        return tokens.Count > 0
            ? new Regex(string.Join('|', tokens), RegexOptions.CultureInvariant)
            : throw new InvalidDataException("the response PII denylist lists no tokens: nothing would be caught");
    }

    // The property names server/Api/openapi-pii-allowlist.txt allows:
    // "<Schema>.<property>  <reason>" per line, comments and blanks ignored.
    public static IReadOnlySet<string> AllowedNames(IEnumerable<string> lines) =>
        lines.Select(line => line.Trim())
            .Where(line => line.Length > 0 && !line.StartsWith('#'))
            .Select(line => line.Split((char[]?)null, 2, StringSplitOptions.RemoveEmptyEntries)[0])
            .Select(key => Normalize(key[(key.LastIndexOf('.') + 1)..]))
            .ToHashSet();

    // Every property in a JSON document named like personal or secret data
    // and not allowlisted, as a path: contact.emailAddress, devices[0].phone.
    public static IReadOnlyList<string> Findings(JsonElement element, Regex denylist, IReadOnlySet<string> allowed)
    {
        var findings = new List<string>();
        Walk(element, "", denylist, allowed, findings);
        return findings;
    }

    private static void Walk(JsonElement element, string path, Regex denylist, IReadOnlySet<string> allowed, List<string> findings)
    {
        switch (element.ValueKind)
        {
            case JsonValueKind.Object:
                foreach (var property in element.EnumerateObject())
                {
                    var here = path.Length == 0 ? property.Name : $"{path}.{property.Name}";
                    var normalized = Normalize(property.Name);
                    if (denylist.IsMatch(normalized) && !allowed.Contains(normalized))
                    {
                        findings.Add(here);
                    }

                    Walk(property.Value, here, denylist, allowed, findings);
                }

                break;
            case JsonValueKind.Array:
                var index = 0;
                foreach (var item in element.EnumerateArray())
                {
                    Walk(item, $"{path}[{index++}]", denylist, allowed, findings);
                }

                break;
            default:
                break;
        }
    }
}

public sealed class ResponsePiiTests : IDisposable
{
    // The same two files the static gate reads, copied beside the tests by
    // Api.Tests.csproj.
    private static readonly Regex Denied =
        ResponsePii.Denylist(File.ReadLines(Path.Combine(AppContext.BaseDirectory, "response-pii-denylist.txt")));

    private static readonly IReadOnlySet<string> Allowed =
        ResponsePii.AllowedNames(File.ReadLines(Path.Combine(AppContext.BaseDirectory, "openapi-pii-allowlist.txt")));

    private readonly WebApplicationFactory<Program> factory = new();

    public void Dispose() => factory.Dispose();

    private static bool IsJson(HttpResponseMessage response) =>
        response.Content.Headers.ContentType?.MediaType == MediaTypeNames.Application.Json;

    private static async Task<IReadOnlyList<string>> FindingsIn(HttpResponseMessage response)
    {
        using var document = JsonDocument.Parse(await response.Content.ReadAsStreamAsync(TestContext.Current.CancellationToken));
        return ResponsePii.Findings(document.RootElement, Denied, Allowed);
    }

    // Every route a stranger can GET, from the route table itself, so a new
    // endpoint is covered the day it is mapped. Routes with parameters are
    // left out (there is nothing to fill them with); the owner route below
    // stands in for those.
    private IEnumerable<string> AnonymousGetRoutes() =>
        factory.Services.GetRequiredService<EndpointDataSource>().Endpoints
            .OfType<RouteEndpoint>()
            .Where(endpoint => endpoint.Metadata.GetMetadata<IAllowAnonymous>() is not null)
            .Where(endpoint =>
            {
                var methods = endpoint.Metadata.GetMetadata<IHttpMethodMetadata>()?.HttpMethods;
                return methods is null || methods.Contains(HttpMethods.Get, StringComparer.OrdinalIgnoreCase);
            })
            .Where(endpoint => endpoint.RoutePattern.Parameters.Count == 0)
            .Select(endpoint => "/" + (endpoint.RoutePattern.RawText ?? "").TrimStart('/'));

    [Fact]
    public async Task NoAnonymousGetReturnsAnUnlistedPiiField()
    {
        using var client = factory.CreateClient();
        var inspected = new List<string>();
        var findings = new List<string>();

        foreach (var path in AnonymousGetRoutes())
        {
            using var response = await client.GetAsync(path, TestContext.Current.CancellationToken);
            if (!IsJson(response))
            {
                continue;
            }

            inspected.Add(path);
            findings.AddRange((await FindingsIn(response)).Select(finding => $"GET {path}: {finding}"));
        }

        // Not vacuous: the one JSON endpoint the template ships was among them.
        Assert.Contains("/api/hello", inspected);
        Assert.Empty(findings);
    }

    [Fact]
    public async Task TheOwnerRouteReturnsNoUnlistedPiiField()
    {
        // The IDOR stand-in from AuthorizationTests, with a body this time:
        // what the owner gets back is a DTO too.
        var alicesNote = TestIdentity.Endpoint("/_test/notes/1", context =>
        {
            if (context.User.FindFirstValue(ClaimTypes.NameIdentifier) != "alice")
            {
                context.Response.StatusCode = StatusCodes.Status404NotFound;
                return Task.CompletedTask;
            }

            return context.Response.WriteAsJsonAsync(new { id = 1, title = "groceries", ownerId = "alice" });
        });
        using var host = TestIdentity.Host(factory, alicesNote);
        using var alice = TestIdentity.As(host, "alice");

        using var response = await alice.GetAsync("/_test/notes/1", TestContext.Current.CancellationToken);

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.True(IsJson(response), "the owner route answered something other than JSON");
        Assert.Empty(await FindingsIn(response));
    }

    // The checker's own negative test, through the app: an anonymous endpoint
    // that hands out an entity is reported field by field, nested or in an
    // array, and the field that is not PII is not.
    [Fact]
    public async Task TheCheckReportsAPlantedPiiField()
    {
        var leaky = TestIdentity.Endpoint(
            "/_test/leaky",
            context => context.Response.WriteAsJsonAsync(new
            {
                id = 7,
                contact = new { emailAddress = "a@example.com" },
                devices = new[] { new { phone_number = "+1 555 0100" } },
                message = "fine",
            }),
            new AllowAnonymousAttribute());
        using var host = TestIdentity.Host(factory, leaky);
        using var client = host.CreateClient();

        using var response = await client.GetAsync("/_test/leaky", TestContext.Current.CancellationToken);

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Equal(["contact.emailAddress", "devices[0].phone_number"], await FindingsIn(response));
    }

    [Fact]
    public void AnAllowlistedNameIsAcceptedAndTheAllowlistIsReadAsNameThenReason()
    {
        var allowed = ResponsePii.AllowedNames(["# a comment", "", "Profile.email  the signed-in user's own address"]);
        using var document = JsonDocument.Parse("""{"email":"a@example.com","emailAddress":"b@example.com"}""");

        Assert.Equal(["emailAddress"], ResponsePii.Findings(document.RootElement, Denied, allowed));
        Assert.Equal(["email", "emailAddress"], ResponsePii.Findings(document.RootElement, Denied, new HashSet<string>()));
    }

    [Fact]
    public void TheDenylistIsReadAsOneTokenPerLineAndMustNotBeEmpty()
    {
        var denylist = ResponsePii.Denylist(["# comment", "", "  Email ", "date_of_birth"]);

        Assert.Matches(denylist, ResponsePii.Normalize("contactEmail"));
        Assert.Matches(denylist, ResponsePii.Normalize("DateOfBirth"));
        Assert.DoesNotMatch(denylist, ResponsePii.Normalize("message"));
        Assert.Throws<InvalidDataException>(() => ResponsePii.Denylist(["# only comments"]));
    }
}
