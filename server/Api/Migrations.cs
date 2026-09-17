// The one place schema changes are applied, and the two ways of getting here.
//
//   dotnet Api.dll --migrate     apply and exit. This is the deploy step: it
//                                runs from the production image, as the
//                                migrator role, BEFORE the new revision takes
//                                traffic (docs/deploying.md).
//   MIGRATE_ON_BOOT=true         apply, then serve. Off by default, and meant
//                                for local development only: migrating on boot
//                                means the serving process holds a connection
//                                string that can ALTER and DROP (see
//                                scripts/db/runtime-role.sql), and every
//                                replica races to migrate on a scale-out.
//
// There is no data layer yet, so applying says so and succeeds. The day a
// DbContext exists the body becomes
//
//     await services.GetRequiredService<AppDbContext>().Database.MigrateAsync();
//
// and the argument, the variable, the deploy step and their tests are
// already in place around it.
namespace Api;

internal static class Migrations
{
    public const string Argument = "--migrate";

    public static bool OnBoot(IConfiguration configuration) =>
        configuration.GetValue("MIGRATE_ON_BOOT", defaultValue: false);

    public static Task ApplyAsync(IServiceProvider services, TextWriter output)
    {
        ArgumentNullException.ThrowIfNull(services);
        return output.WriteLineAsync("migrate: no data layer is configured, so there is nothing to apply.");
    }
}
