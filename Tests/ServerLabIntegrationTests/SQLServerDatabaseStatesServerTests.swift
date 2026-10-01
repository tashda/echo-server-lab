import ServerLabKit
import ServerLabTesting
import SQLServerKit
import Testing

/// The seeded image keeps every database state across the commit and the restart.
@Suite(.enabled(if: integrationEnabled), .server("mssql-2022-database-states"))
struct SQLServerDatabaseStatesServerTests {
    @Test func everyStateSurvivesTheImage() async throws {
        let client = try await sqlServer(try #require(LabServer.current), trust: true, mode: .optional)
        defer { Task { try? await client.shutdownGracefully() } }
        var states: [String: String] = [:]
        for database in ["StateOffline", "StateEmergency", "StateRestoring", "StateSingleUser", "StateRestrictedUser", "StateStandby", "StateReadOnly"] {
            let properties = try await client.admin.getDatabaseProperties(name: database)
            states[database] = "\(properties.stateDescription) \(properties.userAccessDescription) \(properties.isReadOnly ? "read-only" : "read-write")"
        }
        #expect(states == [
            "StateOffline": "OFFLINE MULTI_USER read-write",
            "StateEmergency": "EMERGENCY MULTI_USER read-write",
            "StateRestoring": "RESTORING MULTI_USER read-write",
            "StateSingleUser": "ONLINE SINGLE_USER read-write",
            "StateRestrictedUser": "ONLINE RESTRICTED_USER read-write",
            "StateStandby": "ONLINE MULTI_USER read-only",
            "StateReadOnly": "ONLINE MULTI_USER read-only",
        ])
        #expect(try await client.admin.getDatabaseProperties(name: "StateDisabledOwner").owner == "lab_disabled_owner")
    }

    @Test func offlineDatabaseRefusesConnections() async throws {
        let server = try #require(LabServer.current)
        await #expect(throws: (any Error).self) {
            let client = try await SQLServerClient.connect(
                hostname: server.host, port: server.port, database: "StateOffline",
                authentication: .sqlPassword(username: server.username, password: server.password),
                tlsEnabled: true, trustServerCertificate: true, encryptionMode: .optional
            )
            try await client.shutdownGracefully()
        }
    }
}
