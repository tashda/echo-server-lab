import Foundation
import PostgresKit
import ServerLabKit
import ServerLabTesting
import SQLServerKit
import Testing

/// Starts real servers on the lab host. Run with SERVERLAB_INTEGRATION=1.
private let integrationEnabled = ProcessInfo.processInfo.environment["SERVERLAB_INTEGRATION"] == "1"

@Suite(.enabled(if: integrationEnabled), .server("mssql-2022-column-types"))
struct SQLServerColumnTypesServerTests {
    @Test func serverHoldsEveryColumnType() async throws {
        let server = try #require(LabServer.current)
        let client = try await SQLServerClient.connect(
            hostname: server.host, port: server.port, database: "LabData",
            authentication: .sqlPassword(username: server.username, password: server.password),
            tlsEnabled: true, trustServerCertificate: true
        )
        let tables = try await client.metadata.listTables(database: "LabData", schema: "dbo").map(\.name)
        let rows = try await client.metadata.tableProperties(database: "LabData", schema: "dbo", table: "AllTypes").rowCount
        try await client.shutdownGracefully()
        #expect(tables.contains("AllTypes"))
        #expect(tables.contains("LargeValues"))
        #expect(rows == 203)
    }
}

@Suite(.enabled(if: integrationEnabled), .server("mssql-2022-agent-jobs"))
struct SQLServerAgentJobsServerTests {
    @Test func agentRunsTwentyJobs() async throws {
        let server = try #require(LabServer.current)
        let client = try await SQLServerClient.connect(
            hostname: server.host, port: server.port, database: "master",
            authentication: .sqlPassword(username: server.username, password: server.password),
            tlsEnabled: true, trustServerCertificate: true
        )
        let jobs = try await client.agent.listJobs().filter { $0.name.hasPrefix("Lab Job ") }
        let status = try await client.metadata.fetchAgentStatus()
        try await client.shutdownGracefully()
        #expect(jobs.count == 20)
        #expect(jobs.filter { !$0.enabled }.count == 2)
        #expect(status.isSqlAgentRunning)
    }
}

@Suite(.enabled(if: integrationEnabled), .server("pg-17-column-types"))
struct PostgresColumnTypesServerTests {
    @Test func serverHoldsJsonAndEveryType() async throws {
        let server = try #require(LabServer.current)
        let client = try await PostgresClient.connect(configuration: PostgresConfiguration(
            host: server.host, port: server.port, database: "labdata",
            username: server.username, password: server.password, sslMode: .disable
        ))
        defer { client.close() }
        let columns = try await client.metadata.listColumns(schema: "public", table: "all_types")
        let types = Set(columns.map(\.dataType))
        #expect(columns.count > 50)
        #expect(types.contains("jsonb"))
        #expect(types.contains("json"))
    }
}

@Suite(.enabled(if: integrationEnabled), .server("mssql-2022-programmability"))
struct SQLServerProgrammabilityServerTests {
    @Test func serverHoldsEveryProgrammableObject() async throws {
        let server = try #require(LabServer.current)
        let client = try await SQLServerClient.connect(
            hostname: server.host, port: server.port, database: "LabData",
            authentication: .sqlPassword(username: server.username, password: server.password),
            tlsEnabled: true, trustServerCertificate: true
        )
        let synonyms = try await client.metadata.listSynonyms(database: "LabData")
        let sequences = try await client.metadata.listSequences(database: "LabData")
        let procedures = try await client.metadata.listProcedures(database: "LabData", schema: "sales")
        try await client.shutdownGracefully()
        #expect(synonyms.count == 1)
        #expect(sequences.count == 2)
        #expect(procedures.count == 2)
    }
}

@Suite(.enabled(if: integrationEnabled), .server("pg-17-programmability"))
struct PostgresProgrammabilityServerTests {
    @Test func auditTriggerRecordedEveryOrder() async throws {
        let server = try #require(LabServer.current)
        let client = try await PostgresClient.connect(configuration: PostgresConfiguration(
            host: server.host, port: server.port, database: "labdata",
            username: server.username, password: server.password, sslMode: .disable
        ))
        defer { client.close() }
        let orders = try await client.metadata.exactRowCount(schema: "sales", table: "orders")
        let audit = try await client.metadata.exactRowCount(schema: "sales", table: "order_audit")
        #expect(orders == 150)
        #expect(audit == orders)
    }
}

@Suite(.enabled(if: integrationEnabled), .server("mssql-2022-adventureworks"))
struct AdventureWorksServerTests {
    @Test func restoredDatabasesHaveTheirData() async throws {
        let server = try #require(LabServer.current)
        let client = try await SQLServerClient.connect(
            hostname: server.host, port: server.port, database: "master",
            authentication: .sqlPassword(username: server.username, password: server.password),
            tlsEnabled: true, trustServerCertificate: true
        )
        let databases = Set(try await client.metadata.listDatabases().map(\.name))
        let orders = try await client.metadata.tableProperties(database: "AdventureWorks", schema: "Sales", table: "SalesOrderHeader").rowCount
        try await client.shutdownGracefully()
        #expect(databases.isSuperset(of: ["AdventureWorks", "AdventureWorksLT", "AdventureWorksDW"]))
        #expect(orders == 31_465)
    }
}

@Suite(.enabled(if: integrationEnabled), .server("pg-18-pagila"))
struct PagilaServerTests {
    @Test func pagilaHasItsFilmsAndRentals() async throws {
        let server = try #require(LabServer.current)
        let client = try await PostgresClient.connect(configuration: PostgresConfiguration(
            host: server.host, port: server.port, database: "pagila",
            username: server.username, password: server.password, sslMode: .disable
        ))
        defer { client.close() }
        #expect(try await client.metadata.exactRowCount(schema: "public", table: "film") == 1_000)
        #expect(try await client.metadata.exactRowCount(schema: "public", table: "rental") > 16_000)
    }
}

@Suite(.enabled(if: integrationEnabled), .server("pg-17-empty", capture: true))
struct PostgresWireCaptureTests {
    @Test func oneQueryIsOneRoundTripAndThePasswordNeverCrossesInClear() async throws {
        let server = try #require(LabServer.current)
        let wire = try #require(LabWire.current)
        let client = try await PostgresClient.connect(configuration: PostgresConfiguration(
            host: server.host, port: server.port, database: "postgres",
            username: server.username, password: server.password, sslMode: .disable
        ))
        let rows = try await client.simpleQuery("SELECT 42 AS lab_capture_marker")
        for try await _ in rows {}
        client.close()

        let messages = try await wire.messages()
        #expect(messages.contains { $0.kind == "Startup message" || $0.kind.contains("Startup") })
        #expect(messages.roundTrips(containing: "lab_capture_marker") == 1)
        // SCRAM sends a proof, never the password itself.
        #expect(try await wire.containsPlaintext(server.password) == false)
    }
}

@Suite(.enabled(if: integrationEnabled), .server("pg-17-primary-standby"))
struct PostgresPrimaryStandbyTests {
    func connect(_ server: LabServer, part: String) async throws -> PostgresClient {
        let endpoint = try server.endpoint(of: part)
        return try await PostgresClient.connect(configuration: PostgresConfiguration(
            host: endpoint.host, port: endpoint.port, database: "labdata",
            username: endpoint.username, password: endpoint.password, sslMode: .disable
        ))
    }

    func rowCount(_ server: LabServer, part: String) async throws -> Int64 {
        let client = try await connect(server, part: part)
        defer { client.close() }
        return try await client.metadata.exactRowCount(table: "replicated")
    }

    @Test func standbyFollowsSurvivesARestartAndCanBePromoted() async throws {
        let server = try #require(LabServer.current)
        #expect(server.parts.map(\.role) == ["primary", "standby"])

        let primary = try await connect(server, part: "primary")
        try await primary.admin.createTable(name: "replicated", columns: [
            PostgresColumnDefinition(name: "id", dataType: "integer", nullable: false),
            PostgresColumnDefinition(name: "label", dataType: "text"),
        ])
        try await primary.bulk.insert(into: "replicated", columns: ["id", "label"],
                                      values: (1...3).map { [PostgresInsertValue($0), PostgresInsertValue("row \($0)")] })
        #expect(try await primary.metadata.isInRecovery() == false)
        #expect(try await primary.metadata.listStandbys().map(\.applicationName) == ["standby"])
        primary.close()

        try await retryUntilReady("rows on the standby", timeout: .seconds(30), every: .milliseconds(250)) {
            guard try await rowCount(server, part: "standby") == 3 else { throw CancellationError() }
        }

        try await server.stop(part: "standby")
        await #expect(throws: (any Error).self) { _ = try await rowCount(server, part: "standby") }
        try await server.start(part: "standby")
        #expect(try await rowCount(server, part: "standby") == 3)

        try await server.promote()
        let promoted = try await connect(server, part: "standby")
        defer { promoted.close() }
        #expect(try await promoted.metadata.isInRecovery() == false)
        try await promoted.bulk.insert(into: "replicated", columns: ["id", "label"], values: [[PostgresInsertValue(4), PostgresInsertValue("after promote")]])
        #expect(try await promoted.metadata.exactRowCount(table: "replicated") == 4)
    }
}
