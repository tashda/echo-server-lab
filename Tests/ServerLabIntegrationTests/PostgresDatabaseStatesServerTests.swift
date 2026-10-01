import Foundation
import PostgresKit
import ServerLabKit
import ServerLabTesting
import Testing

/// The seeded image keeps the database states, tablespaces and odd objects across commit and restart.
@Suite(.enabled(if: integrationEnabled), .server("pg-17-database-states"))
struct PostgresDatabaseStatesServerTests {
    func client(_ database: String) async throws -> PostgresClient {
        let server = try #require(LabServer.current)
        return try await PostgresClient.connect(configuration: PostgresConfiguration(
            host: server.host, port: server.port, database: database,
            username: server.username, password: server.password, sslMode: .disable
        ))
    }

    @Test func databaseStatesSurviveTheImage() async throws {
        let client = try await client("postgres")
        defer { client.close() }
        let noConnections = try await client.metadata.fetchDatabaseProperties(name: "states_no_connections")
        let latin1 = try await client.metadata.fetchDatabaseProperties(name: "enc_latin1")
        let onTablespace = try await client.metadata.fetchDatabaseProperties(name: "states_on_tablespace")
        #expect(!noConnections.allowConnections)
        #expect(latin1.encoding == "LATIN1")
        #expect(onTablespace.tablespace == "ts_fast")
        let tablespaces: [PostgresTablespaceInfo] = try await client.metadata.listTablespaces()
        #expect(tablespaces.contains { $0.name == "ts_archive" && $0.location == "/labdata/tablespaces/archive" })
    }

    /// ALLOW_CONNECTIONS false refuses everyone; a connection limit of 0 does not apply to
    /// superusers (the lab's login), so that one is only checked in the catalog.
    @Test func noConnectionsDatabaseRefusesEvenSuperusers() async throws {
        await #expect(throws: (any Error).self) {
            let client = try await client("states_no_connections")
            defer { client.close() }
            _ = try await client.metadata.listDatabases()
        }
        let catalog = try await client("postgres")
        defer { catalog.close() }
        #expect(try await catalog.metadata.fetchDatabaseProperties(name: "states_limit_zero").connectionLimit == 0)
    }

    @Test func oddObjectsStayOdd() async throws {
        let client = try await client("labdata")
        defer { client.close() }
        #expect(try await client.metadata.materializedViewDetails(schema: "public", view: "pending_report")?.isPopulated == false)
        let trigger = try await client.metadata.listTriggers(schema: "public", table: "state_readings").first { $0.name == "paused_trigger" }
        #expect(trigger?.isEnabled == false)
        // The sequence is at its maximum and has no CYCLE.
        await #expect(throws: (any Error).self) { _ = try await client.sequences.nextval("public.exhausted_ids") }
    }
}
