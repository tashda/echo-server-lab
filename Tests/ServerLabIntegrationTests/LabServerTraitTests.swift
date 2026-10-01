import Foundation
import Logging
import MySQLKit
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

// MARK: - TLS

func postgres(_ server: LabServer, sslMode: PostgresSSLMode, rootCertificate: String? = nil,
              clientCertificate: String? = nil, clientKey: String? = nil, password: String? = nil) async throws -> PostgresClient {
    try await PostgresClient.connect(configuration: PostgresConfiguration(
        host: server.host, port: server.port, database: "postgres", username: server.username,
        password: password ?? server.password, sslMode: sslMode, sslRootCertPath: rootCertificate,
        sslCertPath: clientCertificate, sslKeyPath: clientKey
    ))
}

func sqlServer(_ server: LabServer, trust: Bool, caPath: String? = nil,
               mode: SQLServerEncryptionMode = .mandatory) async throws -> SQLServerClient {
    try await SQLServerClient.connect(
        hostname: server.host, port: server.port,
        authentication: .sqlPassword(username: server.username, password: server.password),
        tlsEnabled: true, trustServerCertificate: trust, caCertificatePath: caPath, encryptionMode: mode
    )
}

@Suite(.enabled(if: integrationEnabled), .server("pg-17-tls-required", capture: true))
struct PostgresTLSRequiredTests {
    @Test func verifiesAgainstTheLabCAAndRefusesPlaintext() async throws {
        let server = try #require(LabServer.current)
        let tls = try #require(server.tls)
        #expect(tls.mode == .required)
        await #expect(throws: (any Error).self) { try await postgres(server, sslMode: .disable).close() }

        let client = try await postgres(server, sslMode: .verifyFull, rootCertificate: tls.caPath)
        let rows = try await client.simpleQuery("SELECT 'lab_tls_marker'")
        for try await _ in rows {}
        client.close()
        #expect(try await LabWire.current?.containsPlaintext("lab_tls_marker") == false)
    }
}

@Suite(.enabled(if: integrationEnabled), .server("pg-17-tls-client-certificate"))
struct PostgresClientCertificateTests {
    @Test func logsInWithTheHandedBackCertificateOnly() async throws {
        let server = try #require(LabServer.current)
        let tls = try #require(server.tls)
        let certificate = try #require(tls.clientCertificatePath), key = try #require(tls.clientKeyPath)
        let client = try await postgres(server, sslMode: .verifyFull, rootCertificate: tls.caPath,
                                        clientCertificate: certificate, clientKey: key, password: "not-the-password")
        #expect(try await client.metadata.listDatabases().contains("labdata"))
        client.close()
        await #expect(throws: (any Error).self) { try await postgres(server, sslMode: .require).close() }
    }
}

@Suite(.enabled(if: integrationEnabled), .server("pg-17-tls-wrong-host"))
struct PostgresWrongHostCertificateTests {
    @Test func fullVerificationFailsButEncryptionAlonePasses() async throws {
        let server = try #require(LabServer.current)
        let tls = try #require(server.tls)
        await #expect(throws: (any Error).self) {
            try await postgres(server, sslMode: .verifyFull, rootCertificate: tls.caPath).close()
        }
        try await postgres(server, sslMode: .verifyCA, rootCertificate: tls.caPath).close()
    }
}

@Suite(.enabled(if: integrationEnabled), .server("mssql-2022-tls-required"))
struct SQLServerTLSRequiredTests {
    @Test func verifiesAgainstTheLabCA() async throws {
        let server = try #require(LabServer.current)
        let tls = try #require(server.tls)
        let client = try await sqlServer(server, trust: false, caPath: tls.caPath)
        #expect(try await client.metadata.listDatabases().contains { $0.name == "LabData" })
        try await client.shutdownGracefully()
    }
}

@Suite(.enabled(if: integrationEnabled), .server("mssql-2022-tls-wrong-host"))
struct SQLServerWrongHostCertificateTests {
    @Test func verificationFailsButTrustingPasses() async throws {
        let server = try #require(LabServer.current)
        let tls = try #require(server.tls)
        await #expect(throws: (any Error).self) {
            try await sqlServer(server, trust: false, caPath: tls.caPath).shutdownGracefully()
        }
        try await sqlServer(server, trust: true).shutdownGracefully()
    }
}

@Suite(.enabled(if: integrationEnabled), .server("mssql-2025-tls-strict"))
struct SQLServerStrictEncryptionTests {
    @Test func acceptsTDS8AndRefusesTheOldHandshake() async throws {
        let server = try #require(LabServer.current)
        let tls = try #require(server.tls)
        let client = try await sqlServer(server, trust: false, caPath: tls.caPath, mode: .strict)
        #expect(try await client.metadata.listDatabases().contains { $0.name == "LabData" })
        try await client.shutdownGracefully()
        await #expect(throws: (any Error).self) { try await sqlServer(server, trust: true).shutdownGracefully() }
    }
}

// MARK: - Faults

@Suite(.enabled(if: integrationEnabled), .server("pg-17-empty", faults: true))
struct PostgresFaultTests {
    func connectThroughProxy(_ server: LabServer) async throws -> PostgresClient {
        let proxy = try server.endpoint(of: "proxy")
        return try await PostgresClient.connect(configuration: PostgresConfiguration(
            host: proxy.host, port: proxy.port, database: "postgres",
            username: proxy.username, password: proxy.password, sslMode: .disable, connectTimeout: 3
        ))
    }

    @Test func latencySlowsQueriesAndACutDropsConnections() async throws {
        let server = try #require(LabServer.current)
        let client = try await connectThroughProxy(server)
        let clock = ContinuousClock()
        let fast = try await clock.measure { _ = try await client.metadata.listDatabases() }

        let latency = try await server.addFault(.latency(milliseconds: 400))
        let slow = try await clock.measure { _ = try await client.metadata.listDatabases() }
        #expect(slow >= .milliseconds(400))
        #expect(slow > fast)
        try await server.clearFaults(latency)

        try await server.cutConnections()
        await #expect(throws: (any Error).self) { _ = try await client.metadata.listDatabases() }
        client.close()
        await #expect(throws: (any Error).self) { try await connectThroughProxy(server).close() }
        try await server.restoreConnections()
        let again = try await connectThroughProxy(server)
        #expect(try await again.metadata.listDatabases().contains("postgres"))
        again.close()
    }
}

@Suite(.enabled(if: integrationEnabled), .server("mssql-2022-empty", faults: true))
struct SQLServerFaultTests {
    @Test func resetPeerBreaksTheConnection() async throws {
        let server = try #require(LabServer.current)
        let proxy = try server.endpoint(of: "proxy")
        let client = try await SQLServerClient.connect(
            hostname: proxy.host, port: proxy.port,
            authentication: .sqlPassword(username: proxy.username, password: proxy.password),
            tlsEnabled: true, trustServerCertificate: true
        )
        _ = try await client.metadata.listDatabases()
        try await server.addFault(.resetPeer(afterMilliseconds: 0))
        await #expect(throws: (any Error).self) { _ = try await client.metadata.listDatabases() }
        try? await client.shutdownGracefully()
        try await server.clearFaults()
    }
}

// MARK: - Kerberos (needs *.lab.test to resolve to the lab host: Pi-hole wildcard)

@Suite(.enabled(if: integrationEnabled), .server("pg-17-kerberos"), .serialized)
struct PostgresKerberosTests {
    @Test func domainUserLogsInWithATicket() async throws {
        let server = try #require(LabServer.current)
        let kerberos = try #require(server.kerberos)
        let databases = try await kerberos.withTicket(password: server.password) {
            let client = try await PostgresClient.connect(configuration: PostgresConfiguration(
                host: kerberos.serviceHost, port: server.port, database: "postgres",
                username: "labuser", password: nil, sslMode: .disable
            ))
            defer { client.close() }
            return try await client.metadata.listDatabases()
        }
        #expect(databases.contains("labdata"))
    }
}

@Suite(.enabled(if: integrationEnabled), .server("mssql-2022-kerberos"), .serialized)
struct SQLServerKerberosTests {
    @Test(arguments: [true, false])
    func domainUserLogsInWithKerberos(withTicketFromCache: Bool) async throws {
        let server = try #require(LabServer.current)
        let kerberos = try #require(server.kerberos)
        try await kerberos.withTicket(password: server.password, credentials: withTicketFromCache ? .ticketCache : .password) {
            try await logIn(server, kerberos, password: withTicketFromCache ? "" : server.password)
        }
    }

    func logIn(_ server: LabServer, _ kerberos: LabKerberosInfo, password: String) async throws {
        let client = try await SQLServerClient.connect(
            hostname: kerberos.serviceHost, port: server.port,
            authentication: .windowsIntegrated(username: "labuser", password: password,
                                               domain: kerberos.realm),
            tlsEnabled: true, trustServerCertificate: true,
            logger: { var logger = Logger(label: "kerberos-test"); logger.logLevel = ProcessInfo.processInfo.environment["SERVERLAB_DEBUG"] == "1" ? .trace : .warning; return logger }()
        )
        #expect(try await client.metadata.listDatabases().contains { $0.name == "master" })
        try await client.shutdownGracefully()
    }
}

// MARK: - Availability groups

@Suite(.enabled(if: integrationEnabled), .server("mssql-2022-availability-group"))
struct SQLServerAvailabilityGroupTests {
    func connect(_ server: LabServer, _ role: String) async throws -> SQLServerClient {
        let endpoint = try server.endpoint(of: role)
        return try await SQLServerClient.connect(
            hostname: endpoint.host, port: endpoint.port, database: "LabData",
            authentication: .sqlPassword(username: endpoint.username, password: endpoint.password),
            tlsEnabled: true, trustServerCertificate: true
        )
    }

    func rows(_ server: LabServer, _ role: String) async throws -> Int64 {
        let client = try await connect(server, role)
        defer { Task { try? await client.shutdownGracefully() } }
        return try await client.metadata.tableProperties(database: "LabData", schema: "dbo", table: "Replicated").rowCount
    }

    @Test func secondaryFollowsAndTakesOverOnFailover() async throws {
        let server = try #require(LabServer.current)
        #expect(server.parts.map(\.role) == ["primary", "secondary"])

        let primary = try await connect(server, "primary")
        let admin = primary.admin.scoped(to: "LabData")
        try await admin.createTable(name: "Replicated", columns: [
            SQLServerColumnDefinition(name: "Id", definition: .standard(.init(dataType: .int))),
            SQLServerColumnDefinition(name: "Label", definition: .standard(.init(dataType: .nvarchar(length: .length(50)), isNullable: true))),
        ])
        try await admin.insertRows(into: "Replicated", columns: ["Id", "Label"],
                                   values: (1...3).map { [.int($0), .nString("row \($0)")] })
        #expect(try await primary.availabilityGroups.listGroups().map(\.name) == ["LabAG"])
        try await primary.shutdownGracefully()

        try await retryUntilReady("rows on the secondary", timeout: .seconds(60), every: .milliseconds(500)) {
            guard try await rows(server, "secondary") == 3 else { throw CancellationError() }
        }

        try await server.promote(part: "secondary")
        let promoted = try await connect(server, "secondary")
        try await promoted.admin.scoped(to: "LabData").insertRows(into: "Replicated", columns: ["Id", "Label"],
                                                                  values: [[.int(4), .nString("after failover")]])
        try await promoted.shutdownGracefully()
        #expect(try await rows(server, "secondary") == 4)
    }
}

// MARK: - TDS spec against real traffic

/// Every message of a session that reads every column type (login encrypted, the rest plain), SQL Server 2025's
/// json and vector included, must decode against MS-TDS with nothing unexplained.
@Suite(.enabled(if: integrationEnabled), .server("mssql-2025-column-types", capture: true))
struct SQLServerTrafficMatchesTheSpecTests {
    @Test func everyMessageDecodes() async throws {
        let server = try #require(LabServer.current)
        let wire = try #require(LabWire.current)
        // sqlserver-nio always encrypts the whole session, so Microsoft's sqlcmd sends the queries:
        // with optional encryption only its login is encrypted.
        let lab = try ServerLab.standard()
        try await lab.runMicrosoftClient(server, sql: "SELECT * FROM dbo.AllTypes; SELECT * FROM dbo.LargeValues;", database: "LabData")

        let messages = try await wire.explainedMessages()
        #expect(messages.specProblems.isEmpty, "\(messages.specProblems.prefix(10))")
        #expect(messages.contains { $0.kind == "PRELOGIN" })
        #expect(messages.contains { $0.kind == "SQL batch" && $0.explanation.text.contains("AllTypes") })
        let results = messages.filter { $0.kind == "Tabular result" }.map(\.explanation.text).joined()
        // sqlcmd does not ask for JSONSUPPORT or VECTORSUPPORT, so the server sends json and vector
        // columns as nvarchar(max); their own wire types need sqlserver-nio's traffic (TLS key log).
        #expect(results.contains("NBCROW (0xD2)") || results.contains("ROW (0xD1)"))
        #expect(results.contains("0x6A decimal") && results.contains("0x2B datetimeoffset") && results.contains("0x24 uniqueidentifier"))
        #expect(results.contains("MAX (PLP)"))
    }
}

/// postgres-wire's own traffic (plain text) reading every column type and the JSON documents must
/// decode against the protocol with nothing unexplained.
@Suite(.enabled(if: integrationEnabled), .server("pg-17-column-types", capture: true))
struct PostgresTrafficMatchesTheProtocolTests {
    @Test func everyMessageDecodes() async throws {
        let server = try #require(LabServer.current)
        let wire = try #require(LabWire.current)
        let client = try await PostgresClient.connect(configuration: PostgresConfiguration(
            host: server.host, port: server.port, database: "labdata",
            username: server.username, password: server.password, sslMode: .disable
        ))
        // What a user types in Echo's editor, and what Echo's explorer asks for.
        for sql in ["SELECT * FROM all_types", "SELECT * FROM json_documents"] {
            let rows = try await client.simpleQuery(sql)
            for try await _ in rows {}
        }
        _ = try await client.metadata.listColumns(schema: "public", table: "all_types")
        client.close()

        let messages = try await wire.explainedMessages()
        #expect(messages.specProblems.isEmpty, "\(messages.specProblems.prefix(10))")
        #expect(messages.contains { $0.kind == "StartupMessage" })
        #expect(messages.contains { $0.kind == "AuthenticationSASL" })
        #expect(messages.contains { $0.kind == "DataRow" })
        let text = messages.map(\.explanation.text).joined()
        #expect(text.contains("all_types"))
        #expect(!text.contains(server.password))
    }
}

// MARK: - MySQL and MariaDB

func mysqlTypes(_ server: LabServer) async throws -> (columns: [String], rows: Int) {
    let client = MySQLClient(configuration: MySQLConfiguration(
        host: server.host, port: server.port, username: server.username, password: server.password,
        database: "labdata", tlsMode: .required
    ))
    defer { Task { await client.close() } }
    let columns = try await client.metadata.listColumns(in: "all_types", schema: "labdata").map(\.name)
    return (columns, try await client.metadata.exactRowCount(schema: "labdata", table: "all_types"))
}

@Suite(.enabled(if: integrationEnabled), .server("mysql-8.4-column-types"))
struct MySQL84ColumnTypesServerTests {
    /// MySQL 8+ labels information_schema columns in upper case; mysql-wire must still read them.
    @Test func metadataReadsUpperCaseLabels() async throws {
        let (columns, rows) = try await mysqlTypes(try #require(LabServer.current))
        #expect(rows == 203)
        #expect(columns.count == 46)
    }
}

@Suite(.enabled(if: integrationEnabled), .server("mysql-9-column-types"))
struct MySQLColumnTypesServerTests {
    @Test func serverHoldsEveryTypeIncludingVector() async throws {
        let (columns, rows) = try await mysqlTypes(try #require(LabServer.current))
        #expect(rows == 203)
        for column in ["bigint_unsigned_col", "geometrycollection_col", "vector_col"] { #expect(columns.contains(column), "\(column) missing from \(columns)") }
    }
}

@Suite(.enabled(if: integrationEnabled), .server("mariadb-11.8-column-types"))
struct MariaDBColumnTypesServerTests {
    @Test func serverHoldsEveryTypeIncludingMariaDBOnes() async throws {
        let (columns, rows) = try await mysqlTypes(try #require(LabServer.current))
        #expect(rows == 203)
        #expect(columns.contains("inet6_col") && columns.contains("uuid_col") && columns.contains("vector_col"))
    }
}
