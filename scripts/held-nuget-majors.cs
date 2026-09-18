// held-nuget-majors.cs: the NuGet half of scripts/check-held-majors.sh, which
// runs it with `dotnet run` in the SDK image the server builds with. See that
// script for what it gates and why. In-box APIs only: no package references,
// so there is nothing here for Dependabot to miss.
//
//   dotnet run scripts/held-nuget-majors.cs -- <dir>...    check these
//   dotnet run scripts/held-nuget-majors.cs -- --self-test prove it can fail
//
// <dir> holds a Directory.Packages.props (central package management); the
// .csproj files under it are the projects judged.
//
// The judge is the one Dependabot uses: a package version is offered to a
// project only if it ships assets for a framework the project's target
// framework can consume. Not a restore: a package can carry a build/ folder
// that restores anywhere and then fails the build with a framework floor
// (Microsoft.AspNetCore.OpenApi 10 in a net8.0 project restores clean), and
// a restore that fails on a breaking API change is a red pull request, not
// a silent one. Frameworks come from the nupkg itself: lib/ and ref/ folders
// plus the nuspec dependency groups. Compatibility covers the frameworks
// these repositories use (netN.0, netcoreappN.N, netstandardN.N); anything
// else is treated as incompatible, which fails loud rather than quietly.

using System.IO.Compression;
using System.Net;
using System.Text.Json;
using System.Xml.Linq;

// A new major often lands before the packages around it move to the same
// framework; that lag is not a silent pin. Judged only after this long.
int graceDays = int.TryParse(Environment.GetEnvironmentVariable("HELD_MAJORS_GRACE_DAYS"), out var g) ? g : 30;
const string ExceptionsFile = ".held-majors";
var http = new HttpClient(new HttpClientHandler { AutomaticDecompression = DecompressionMethods.All });
http.DefaultRequestHeaders.UserAgent.ParseAdd("held-majors-check");

return args is ["--self-test"] ? await SelfTest() : await Check(args);

static int Major(string version) => int.Parse(version.Split('.')[0]);

static int CompareVersions(string a, string b)
{
    var pa = a.Split('.').Select(int.Parse).ToArray();
    var pb = b.Split('.').Select(int.Parse).ToArray();
    for (var i = 0; i < Math.Max(pa.Length, pb.Length); i++)
    {
        var c = (i < pa.Length ? pa[i] : 0).CompareTo(i < pb.Length ? pb[i] : 0);
        if (c != 0) return c;
    }
    return 0;
}

// Every centrally managed package, name -> version.
static Dictionary<string, string> Pinned(string dir)
{
    var props = Path.Combine(dir, "Directory.Packages.props");
    if (!File.Exists(props)) throw new Exception($"{dir}: no Directory.Packages.props (central package management is required)");
    return XDocument.Load(props).Descendants("PackageVersion")
        .ToDictionary(e => (string)e.Attribute("Include")!, e => (string)e.Attribute("Version")!, StringComparer.OrdinalIgnoreCase);
}

// Each project under dir: its target frameworks and the packages it
// references. A TargetFramework set in a Directory.Build.props above the
// project applies to it; the nearest one wins, as MSBuild's import does.
static List<(string project, List<string> frameworks, HashSet<string> packages)> Projects(string dir)
{
    var result = new List<(string, List<string>, HashSet<string>)>();
    foreach (var csproj in Directory.EnumerateFiles(dir, "*.csproj", SearchOption.AllDirectories))
    {
        if (csproj.Split(Path.DirectorySeparatorChar).Any(p => p is "bin" or "obj" or "node_modules")) continue;
        var frameworks = new List<string>();
        for (var d = new DirectoryInfo(Path.GetDirectoryName(csproj)!); d is not null && frameworks.Count == 0; d = d.Parent)
        {
            foreach (var file in new[] { csproj, Path.Combine(d.FullName, "Directory.Build.props") }.Where(File.Exists).Distinct())
            {
                var doc = XDocument.Load(file);
                frameworks.AddRange(doc.Descendants("TargetFramework").Select(e => e.Value.Trim()));
                frameworks.AddRange(doc.Descendants("TargetFrameworks").SelectMany(e => e.Value.Split(';')).Select(v => v.Trim()));
                frameworks.RemoveAll(f => f.Length == 0 || f.Contains('$'));
                if (frameworks.Count > 0) break;
            }
            if (Path.GetFullPath(d.FullName) == Path.GetFullPath(dir)) break;
        }
        if (frameworks.Count == 0) throw new Exception($"{csproj}: no literal TargetFramework found in the project or a Directory.Build.props above it");
        var packages = XDocument.Load(csproj).Descendants("PackageReference")
            .Select(e => (string?)e.Attribute("Include") ?? (string?)e.Attribute("Update")).OfType<string>()
            .ToHashSet(StringComparer.OrdinalIgnoreCase);
        result.Add((Path.GetRelativePath(dir, csproj), frameworks, packages));
    }
    return result;
}

// Latest listed stable version and its publish date, from the registration
// index (pages may be inline or one fetch away).
async Task<(string version, DateTimeOffset published)?> Latest(string id)
{
    var index = JsonDocument.Parse(await http.GetStringAsync($"https://api.nuget.org/v3/registration5-gz-semver2/{id.ToLowerInvariant()}/index.json")).RootElement;
    (string, DateTimeOffset)? best = null;
    foreach (var page in index.GetProperty("items").EnumerateArray())
    {
        var items = page.TryGetProperty("items", out var inline)
            ? inline
            : JsonDocument.Parse(await http.GetStringAsync(page.GetProperty("@id").GetString()!)).RootElement.GetProperty("items");
        foreach (var item in items.EnumerateArray())
        {
            var entry = item.GetProperty("catalogEntry");
            var version = entry.GetProperty("version").GetString()!;
            if (version.Contains('-') || version.Contains('+')) continue;
            if (entry.TryGetProperty("listed", out var listed) && !listed.GetBoolean()) continue;
            if (best is null || CompareVersions(version, best.Value.Item1) > 0)
                best = (version, entry.GetProperty("published").GetDateTimeOffset());
        }
    }
    return best;
}

// The frameworks a package version ships assets for: lib/ and ref/ folders
// in the nupkg plus the nuspec dependency groups. Empty means framework
// neutral (tools, analyzers, build-only packages): compatible with anything.
async Task<HashSet<string>> ShippedFrameworks(string id, string version)
{
    var lower = id.ToLowerInvariant();
    var bytes = await http.GetByteArrayAsync($"https://api.nuget.org/v3-flatcontainer/{lower}/{version}/{lower}.{version}.nupkg");
    using var zip = new ZipArchive(new MemoryStream(bytes));
    var frameworks = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
    foreach (var entry in zip.Entries)
    {
        var parts = entry.FullName.Split('/');
        if (parts.Length >= 3 && parts[0] is "lib" or "ref") frameworks.Add(parts[1]);
        if (parts.Length == 1 && entry.FullName.EndsWith(".nuspec", StringComparison.OrdinalIgnoreCase))
        {
            using var stream = entry.Open();
            var nuspec = XDocument.Load(stream);
            foreach (var group in nuspec.Descendants().Where(e => e.Name.LocalName == "group"))
            {
                var tfm = (string?)group.Attribute("targetFramework");
                if (!string.IsNullOrEmpty(tfm)) frameworks.Add(Normalize(tfm));
            }
        }
    }
    return frameworks;

    // nuspec groups use the long names (".NETCoreApp10.0", ".NETStandard2.0",
    // "net10.0"); folder names use the short ones. One spelling here.
    static string Normalize(string tfm)
    {
        if (tfm.StartsWith(".NETCoreApp", StringComparison.OrdinalIgnoreCase))
        {
            var v = new Version(tfm[".NETCoreApp".Length..]);
            return v.Major >= 5 ? $"net{v.Major}.{v.Minor}" : $"netcoreapp{v.Major}.{v.Minor}";
        }
        if (tfm.StartsWith(".NETStandard", StringComparison.OrdinalIgnoreCase)) return $"netstandard{tfm[".NETStandard".Length..]}";
        if (tfm.StartsWith(".NETFramework", StringComparison.OrdinalIgnoreCase)) return "net4x";
        return tfm;
    }
}

// Can a project targeting `project` consume assets built for `shipped`?
// net5.0+ consumes: net5.0+ up to its own version (platform-neutral only),
// netcoreapp1.0-3.1, netstandard1.0-2.1. Anything else is not consumed.
static bool Compatible(string project, string shipped)
{
    var p = Parse(project);
    var s = Parse(shipped);
    if (p is null || s is null) return false;
    var (pKind, pVer, pPlatform) = p.Value;
    var (sKind, sVer, sPlatform) = s.Value;
    if (pKind != "net" || pPlatform is not null) return false; // only the frameworks these repositories use
    if (sPlatform is not null) return false;                    // net8.0-windows and friends: not for a neutral project
    return sKind switch
    {
        "net" => sVer <= pVer,
        "netcoreapp" => true,
        "netstandard" => sVer <= new Version(2, 1),
        _ => false,
    };

    static (string kind, Version version, string? platform)? Parse(string tfm)
    {
        tfm = tfm.ToLowerInvariant();
        string? platform = null;
        var dash = tfm.IndexOf('-');
        if (dash > 0) { platform = tfm[(dash + 1)..]; tfm = tfm[..dash]; }
        foreach (var kind in new[] { "netcoreapp", "netstandard", "net" })
        {
            if (!tfm.StartsWith(kind) || !Version.TryParse(tfm[kind.Length..], out var version)) continue;
            if (kind == "net" && version.Major < 5) return null; // .NET Framework: not consumed by net5.0+
            return (kind, version, platform);
        }
        return null;
    }
}

// The projects that reference the package and could not consume the
// version: the exact reason Dependabot would not offer it to them.
async Task<List<string>> CannotTake(List<(string project, List<string> frameworks, HashSet<string> packages)> projects, string id, string version)
{
    var shipped = await ShippedFrameworks(id, version);
    if (shipped.Count == 0) return [];
    return projects.Where(p => p.packages.Contains(id) && !p.frameworks.Any(f => shipped.Any(s => Compatible(f, s))))
        .Select(p => $"{p.project} ({string.Join(";", p.frameworks)}) cannot consume {id} {version}, which ships {string.Join(", ", shipped.Order())}")
        .ToList();
}

// `<dir> <package> <reason...>` per line, shared with the npm check. Only
// entries naming a package this dir pins are this check's business; a typo
// here is caught by the real package failing the check.
static List<(string dir, string name)> Exceptions()
{
    if (!File.Exists(ExceptionsFile)) return [];
    return File.ReadLines(ExceptionsFile).Select(l => l.Trim()).Where(l => l.Length > 0 && !l.StartsWith('#')).Select(l =>
    {
        var parts = l.Split((char[])null!, StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length < 3) throw new Exception($"{ExceptionsFile}: \"{l}\" needs <dir> <package> <reason>");
        var dir = parts[0].Trim('/');
        return (dir.Length == 0 ? "." : dir, parts[1]);
    }).ToList();
}

async Task<int> Check(string[] dirs)
{
    var failed = false;
    foreach (var dir in dirs)
    {
        var pinned = Pinned(dir);
        var projects = Projects(dir);
        var excepted = Exceptions().Where(e => e.dir == dir && pinned.ContainsKey(e.name)).Select(e => e.name)
            .ToHashSet(StringComparer.OrdinalIgnoreCase);
        var all = new List<(string name, string current, string latest, int ageDays)>();
        foreach (var (name, current) in pinned)
        {
            var latest = await Latest(name);
            if (latest is null || Major(latest.Value.version) <= Major(current)) continue;
            all.Add((name, current, latest.Value.version, (int)(DateTimeOffset.UtcNow - latest.Value.published).TotalDays));
        }
        foreach (var c in all)
        {
            var note = excepted.Contains(c.name) ? $"excepted in {ExceptionsFile}"
                : c.ageDays < graceDays ? $"out {c.ageDays}d, judged after {graceDays}d" : "judged";
            Console.WriteLine($"{dir} (nuget): {c.name} {c.current} -> {c.latest} ({note})");
        }

        var dirFailed = false;
        foreach (var c in all.Where(c => !excepted.Contains(c.name) && c.ageDays >= graceDays))
        {
            var reasons = await CannotTake(projects, c.name, c.latest);
            if (reasons.Count == 0) continue;
            dirFailed = true;
            Console.Error.WriteLine($"\nerror: {dir} (nuget): {c.name} {c.latest} cannot be taken by every project that references it.");
            Console.Error.WriteLine("Dependabot does not offer a version a project cannot consume, so this pin would age");
            Console.Error.WriteLine($"in silence. Move the project's target framework, or record it in {ExceptionsFile} with the reason.");
            foreach (var r in reasons) Console.Error.WriteLine($"  {r}");
        }

        // An exception is a debt with an exit condition: once every project
        // can take the bump, or there is no newer major, the entry must go.
        foreach (var name in excepted)
        {
            var c = all.FirstOrDefault(x => string.Equals(x.name, name, StringComparison.OrdinalIgnoreCase));
            if (c.name is null)
            {
                dirFailed = true;
                Console.Error.WriteLine($"error: {ExceptionsFile}: {dir} {name} has no newer major; drop the entry.");
            }
            else if ((await CannotTake(projects, c.name, c.latest)).Count == 0)
            {
                dirFailed = true;
                Console.Error.WriteLine($"error: {ExceptionsFile}: {dir} {name} {c.latest} can be taken now; drop the entry and take the bump.");
            }
        }
        if (!dirFailed) Console.WriteLine($"{dir} (nuget): ok");
        failed |= dirFailed;
    }
    return failed ? 1 : 0;
}

// The failure this check exists for, replayed from published (immutable)
// versions against a net8.0 project: Microsoft.AspNetCore.OpenApi 10.0.12
// ships net10.0 only and must be refused; Microsoft.Extensions.Logging.
// Abstractions 10.0.0 still ships netstandard2.0 and must be accepted.
// Fixture data, not toolchain versions: they never move.
async Task<int> SelfTest()
{
    var project = new List<(string, List<string>, HashSet<string>)>
    {
        ("Fixture.csproj", ["net8.0"], new HashSet<string>(["Microsoft.AspNetCore.OpenApi", "Microsoft.Extensions.Logging.Abstractions"], StringComparer.OrdinalIgnoreCase)),
    };
    var refused = await CannotTake(project, "Microsoft.AspNetCore.OpenApi", "10.0.12");
    var accepted = await CannotTake(project, "Microsoft.Extensions.Logging.Abstractions", "10.0.0");
    if (refused.Count == 0)
    {
        Console.Error.WriteLine("self-test: a version that ships no framework the project can consume was NOT refused");
        return 1;
    }
    if (accepted.Count > 0)
    {
        Console.Error.WriteLine("self-test: a consumable version was refused:");
        foreach (var r in accepted) Console.Error.WriteLine($"  {r}");
        return 1;
    }
    Console.WriteLine($"self-test (nuget): refused the net10.0-only bump for a net8.0 project ({refused[0]}), accepted the netstandard2.0 one");
    return 0;
}
