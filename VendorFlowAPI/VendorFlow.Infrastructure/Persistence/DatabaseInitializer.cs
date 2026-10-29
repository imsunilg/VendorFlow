using System.Security.Cryptography;
using System.Text;
using Microsoft.Extensions.Logging;
using Npgsql;

namespace VendorFlow.Infrastructure.Persistence;

/// <summary>
/// Creates the database (if missing) and applies the embedded VendorFlowDB scripts.
/// 01_Schemas always run; 02_Tables run once (checksum tracked); 03..08 are idempotent and re-applied.
/// This is the only place raw SQL text is executed (DDL cannot live in a function before the database exists).
/// </summary>
public sealed class DatabaseInitializer(ILogger<DatabaseInitializer> log)
{
    private const string Prefix = "VendorFlowDB/";
    private static readonly string[] Folders =
        ["01_Schemas", "02_Tables", "03_Indexes", "04_Sequences", "05_Functions", "06_Views", "07_Triggers", "08_SeedData"];

    public async Task InitializeAsync(string connectionString, bool resetIfTestDb = false, CancellationToken ct = default)
    {
        var target = new NpgsqlConnectionStringBuilder(connectionString);
        var dbName = target.Database ?? throw new InvalidOperationException("Database name missing in connection string.");

        await EnsureDatabaseAsync(target, dbName, resetIfTestDb, ct);

        await using var conn = new NpgsqlConnection(connectionString);
        await conn.OpenAsync(ct);
        // One instance at a time may migrate.
        await ExecAsync(conn, "select pg_advisory_lock(727274)", ct);
        try
        {
            foreach (var folder in Folders)
                foreach (var (name, sql) in ReadScripts(folder))
                    await ApplyAsync(conn, folder, name, sql, ct);
        }
        finally
        {
            await ExecAsync(conn, "select pg_advisory_unlock(727274)", ct);
        }
    }

    private async Task EnsureDatabaseAsync(NpgsqlConnectionStringBuilder target, string dbName, bool reset, CancellationToken ct)
    {
        var admin = new NpgsqlConnectionStringBuilder(target.ConnectionString) { Database = "postgres", Pooling = false };
        NpgsqlConnection? conn = null;
        for (var attempt = 1; ; attempt++)
        {
            try
            {
                conn = new NpgsqlConnection(admin.ConnectionString);
                await conn.OpenAsync(ct);
                break;
            }
            catch (Exception ex) when (attempt < 5)
            {
                log.LogWarning("PostgreSQL not reachable (attempt {Attempt}): {Message}", attempt, ex.Message);
                await Task.Delay(TimeSpan.FromSeconds(2), ct);
            }
        }

        await using (conn)
        {
            var quoted = "\"" + dbName.Replace("\"", "\"\"") + "\"";
            if (reset)
            {
                if (!dbName.EndsWith("_test", StringComparison.OrdinalIgnoreCase))
                    throw new InvalidOperationException("Reset is only allowed for databases ending with _test.");
                await ExecAsync(conn, $"drop database if exists {quoted} with (force)", ct);
            }

            await using var check = new NpgsqlCommand("select 1 from pg_database where datname = @n", conn);
            check.Parameters.AddWithValue("n", dbName);
            if (await check.ExecuteScalarAsync(ct) is null)
            {
                log.LogInformation("Creating database {Database}", dbName);
                await ExecAsync(conn, $"create database {quoted}", ct);
            }
        }
    }

    private async Task ApplyAsync(NpgsqlConnection conn, string folder, string name, string sql, CancellationToken ct)
    {
        var key = $"{folder}/{name}";
        var runOnce = folder == "02_Tables";
        var checksum = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(sql)));

        if (runOnce)
        {
            await using var q = new NpgsqlCommand("select vendorflow.fn_migration_checksum(@s)", conn);
            q.Parameters.AddWithValue("s", key);
            var existing = await q.ExecuteScalarAsync(ct);
            if (existing is string old)
            {
                if (old != checksum)
                    throw new InvalidOperationException($"Table script {key} changed after it was applied. Add a new numbered script instead of editing it.");
                return;
            }
        }

        log.LogInformation("Applying database script {Script}", key);
        await ExecAsync(conn, sql, ct);

        if (runOnce)
        {
            await using var rec = new NpgsqlCommand("call vendorflow.sp_record_migration(@s, @c)", conn);
            rec.Parameters.AddWithValue("s", key);
            rec.Parameters.AddWithValue("c", checksum);
            await rec.ExecuteNonQueryAsync(ct);
        }
    }

    private static IEnumerable<(string Name, string Sql)> ReadScripts(string folder)
    {
        var asm = typeof(DatabaseInitializer).Assembly;
        var wanted = $"{Prefix}{folder}/";
        var resources = asm.GetManifestResourceNames()
            .Select(r => (Actual: r, Normal: r.Replace('\\', '/')))
            .Where(r => r.Normal.StartsWith(wanted))
            .OrderBy(r => r.Normal, StringComparer.Ordinal);
        foreach (var r in resources)
        {
            using var reader = new StreamReader(asm.GetManifestResourceStream(r.Actual)!, Encoding.UTF8);
            yield return (r.Normal[wanted.Length..], reader.ReadToEnd());
        }
    }

    private static async Task ExecAsync(NpgsqlConnection conn, string sql, CancellationToken ct)
    {
        await using var cmd = new NpgsqlCommand(sql, conn) { CommandTimeout = 120 };
        await cmd.ExecuteNonQueryAsync(ct);
    }
}
