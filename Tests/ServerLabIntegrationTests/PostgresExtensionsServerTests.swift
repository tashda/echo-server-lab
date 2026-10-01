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

    /// The scheduler runs in the server from the image: the every-minute job has runs (or gets one).
    @Test func cronJobsSurviveAndRun() async throws {
        let server = try #require(LabServer.current)
        let client = try await PostgresClient.connect(configuration: PostgresConfiguration(
            host: server.host, port: server.port, database: "labdata",
            username: server.username, password: server.password, sslMode: .disable
        ))
        defer { client.close() }
        let jobs = try await client.cron.listJobs()
        #expect(Set(jobs.compactMap(\.name)) == ["nightly_vacuum", "minute_heartbeat", "postgres_cleanup", "paused_report"])
        let probe = try await client.cron.schedule(name: "test_probe", schedule: "1 seconds", command: "SELECT 1")
        var ran = false
        for _ in 1...20 where !ran {
            try await Task.sleep(for: .milliseconds(500))
            ran = try await client.cron.listRuns(limit: 20).contains { $0.jobID == probe && $0.status == "succeeded" }
        }
        try await client.cron.unschedule(name: "test_probe")
        #expect(ran)
    }
}
