import Foundation
import PostgresKit
import ServerLabKit
import ServerLabTesting
import Testing

/// The `extensions` image variant: third-party extensions exist in the seeded image and the
/// preloaded ones (pg_cron, pgaudit, TimescaleDB, …) are loaded.
@Suite(.enabled(if: integrationEnabled), .server("pg-17-third-party-extensions"))
struct PostgresExtensionsServerTests {
    @Test func extensionsAndPreloadsArePresent() async throws {
        let server = try #require(LabServer.current)
        let client = try await PostgresClient.connect(configuration: PostgresConfiguration(
            host: server.host, port: server.port, database: "labdata",
            username: server.username, password: server.password, sslMode: .disable
        ))
        defer { client.close() }
        let installed = Set(try await client.metadata.listExtensions().map(\.name))
        for name in ["pg_cron", "timescaledb", "postgis", "pgrouting", "age", "pg_partman", "vector"] {
            #expect(installed.contains(name), "\(name) missing")
        }
        let preload = try await client.metadata.listServerSettings().first { $0.name == "shared_preload_libraries" }?.setting ?? ""
        #expect(preload.contains("pg_cron") && preload.contains("timescaledb") && preload.contains("pgaudit"))
    }
}
