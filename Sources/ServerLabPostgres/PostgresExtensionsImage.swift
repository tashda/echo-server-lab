import Foundation
import ServerLabKit

/// The `extensions` image variant: the official image plus third-party extensions from the
/// PostgreSQL apt repository (which the official image already uses), with the ones that must be
/// preloaded loaded at start.
extension PostgresEngine {
    static let extensionsVariant = "extensions"

    /// Debian packages `postgresql-<version>-<name>`.
    static let extensionPackages = [
        "cron", "pgaudit", "partman", "repack", "hypopg", "pg-hint-plan", "plpgsql-check", "orafce", "ip4r", "postgis-3",
        "pgrouting", "pldebugger", "age", "h3", "semver", "prefix", "rum", "tdigest", "timescaledb", "unit", "periods",
        "pg-qualstats", "pg-stat-kcache", "pgvector", "http", "jsquery", "pllua", "plsh", "toastinfo",
    ]

    /// Extensions the `third-party-extensions` pack creates (names as CREATE EXTENSION knows them).
    static let thirdPartyExtensions = [
        "pg_cron", "pgaudit", "pg_partman", "pg_repack", "hypopg", "pg_hint_plan", "plpgsql_check", "orafce", "ip4r", "postgis",
        "pgrouting", "pldbgapi", "age", "h3", "semver", "prefix", "rum", "tdigest", "timescaledb", "unit", "periods",
        "pg_qualstats", "pg_stat_kcache", "vector", "http", "jsquery", "pllua", "plsh", "toastinfo", "pg_stat_statements",
    ]

    /// Libraries that only work preloaded, and their settings.
    static let extensionsSettings = [
        "-c", "shared_preload_libraries=pg_stat_statements,pg_cron,pgaudit,timescaledb,pg_qualstats,pg_stat_kcache,pg_hint_plan",
        "-c", "cron.database_name=\(PostgresDatabasePack.defaultName)",
        "-c", "timescaledb.telemetry_level=off",
        "-c", "pgaudit.log=ddl",
    ]

    static func extensionsDockerfile(version: String) -> String {
        """
        FROM postgres:\(version)
        RUN apt-get update \\
         && apt-get install -y --no-install-recommends \(extensionPackages.map { "postgresql-$PG_MAJOR-\($0)" }.joined(separator: " ")) pgagent \\
         && rm -rf /var/lib/apt/lists/*
        """
    }
}
