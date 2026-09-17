using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Xunit;

namespace Api.Tests;

// The entry points (`--migrate` exits 0 without serving) are proven against
// the production image by verify.sh's smoke check; these pin the defaults.
public sealed class MigrationTests
{
    private static IConfiguration Settings(params (string Key, string? Value)[] values) =>
        new ConfigurationBuilder()
            .AddInMemoryCollection(values.Select(pair => KeyValuePair.Create(pair.Key, pair.Value)))
            .Build();

    [Fact]
    public void TheAppDoesNotMigrateOnBootUnlessTold()
    {
        Assert.False(Migrations.OnBoot(Settings()));
        Assert.False(Migrations.OnBoot(Settings(("MIGRATE_ON_BOOT", "false"))));
        Assert.True(Migrations.OnBoot(Settings(("MIGRATE_ON_BOOT", "true"))));
    }

    [Fact]
    public async Task UntilThereIsADataLayerApplyingSaysSo()
    {
        using var output = new StringWriter();
        using var services = new ServiceCollection().BuildServiceProvider();

        await Migrations.ApplyAsync(services, output);

        Assert.Contains("nothing to apply", output.ToString(), StringComparison.Ordinal);
    }
}
