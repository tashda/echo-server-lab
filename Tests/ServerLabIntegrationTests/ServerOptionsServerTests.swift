import Foundation
import MySQLKit
import MySQLWire
import PostgresKit
import ServerLabKit
import ServerLabTesting
import Testing

/// `serverOptions` are on the server's command line, so they hold in a server started from the
/// seeded image, not only in the builder.
func mysqlGlobal(_ client: MySQLClient, _ name: String) async throws -> String? {
    try await client.serverConfig.globalVariables(named: name).first?.value
}

@Suite(.enabled(if: integrationEnabled), .server("mysql-8.4-logs-to-tables"))
struct MySQLLogsToTablesServerTests {
    @Test func generalAndSlowLogsHaveEntries() async throws {
        let client = mysqlClient(try #require(LabServer.current), .required)
        defer { Task { await client.close() } }
        _ = try await client.metadata.listDatabases()
        #expect(try await mysqlGlobal(client, "log_output") == "TABLE")
        #expect(try await !client.errorLog.readTableLog(named: "general_log", limit: 5).isEmpty)
        #expect(try await !client.errorLog.readTableLog(named: "slow_log", limit: 5).isEmpty)
    }
}

@Suite(.enabled(if: integrationEnabled), .server("mariadb-11.4-logs-to-tables"))
struct MariaDBLogsToTablesServerTests {
    @Test func generalAndSlowLogsHaveEntries() async throws {
        let client = mysqlClient(try #require(LabServer.current), .required)
        defer { Task { await client.close() } }
        _ = try await client.metadata.listDatabases()
        #expect(try await !client.errorLog.readTableLog(named: "general_log", limit: 5).isEmpty)
        #expect(try await !client.errorLog.readTableLog(named: "slow_log", limit: 5).isEmpty)
    }
}

@Suite(.enabled(if: integrationEnabled), .server("mysql-8.4-sql-mode-loose"))
struct MySQLLooseSQLModeServerTests {
    @Test func modeAndTimeZoneHoldAndTypesRead() async throws {
        let server = try #require(LabServer.current)
        let client = mysqlClient(server, .required)
        defer { Task { await client.close() } }
        #expect(try await mysqlGlobal(client, "sql_mode") == "")
        #expect(try await mysqlGlobal(client, "time_zone") == "+05:45")
        #expect(try await mysqlTypes(server).rows == 203)
    }
}

@Suite(.enabled(if: integrationEnabled), .server("mysql-8.4-sql-mode-ansi"))
struct MySQLAnsiSQLModeServerTests {
    /// ANSI_QUOTES makes "x" a name, not a string: the driver's metadata must not depend on that.
    @Test func metadataWorksInAnsiMode() async throws {
        let server = try #require(LabServer.current)
        let client = mysqlClient(server, .required)
        defer { Task { await client.close() } }
        #expect(try await mysqlGlobal(client, "sql_mode")?.contains("ANSI_QUOTES") == true)
        let (columns, rows) = try await mysqlTypes(server)
        #expect(rows == 203)
        #expect(columns.count == 46)
    }
}

@Suite(.enabled(if: integrationEnabled), .server("pg-17-odd-defaults"))
struct PostgresOddDefaultsServerTests {
    func client() async throws -> PostgresClient {
        let server = try #require(LabServer.current)
        return try await PostgresClient.connect(configuration: PostgresConfiguration(
            host: server.host, port: server.port, database: "labdata",
            username: server.username, password: server.password, sslMode: .disable
        ))
    }

    @Test func settingsHold() async throws {
        let client = try await client()
        defer { client.close() }
        let names: Set = ["DateStyle", "IntervalStyle", "TimeZone", "bytea_output"]
        let settings = Dictionary(uniqueKeysWithValues: try await client.metadata.listServerSettings()
            .filter { names.contains($0.name) }.map { ($0.name, $0.setting) })
        #expect(settings == ["DateStyle": "SQL, DMY", "IntervalStyle": "sql_standard", "TimeZone": "Pacific/Chatham", "bytea_output": "escape"])
    }

    /// Typed reads come back in binary, so the output styles must not change them.
    @Test func typedReadsIgnoreOutputStyles() async throws {
        let client = try await client()
        defer { client.close() }
        #expect(try await client.metadata.exactRowCount(schema: "public", table: "all_types") > 0)
        let columns = try await client.metadata.listColumns(schema: "public", table: "all_types")
        #expect(columns.contains { $0.dataType == "interval" })
    }
}
