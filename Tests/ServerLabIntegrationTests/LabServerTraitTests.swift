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
