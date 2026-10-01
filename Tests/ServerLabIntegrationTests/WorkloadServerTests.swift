import Foundation
import MySQLKit
import MySQLWire
import PostgresKit
import ServerLabKit
import ServerLabTesting
import ServerLabWorkloads
import SQLServerKit
import Testing

/// Workloads show up in each driver's activity view as Echo's Activity Monitor would see them.
@Suite(.enabled(if: integrationEnabled), .server("mssql-2022-empty"))
struct SQLServerWorkloadTests {
    @Test func blockingChainShowsTheHeadBlocker() async throws {
        let server = try #require(LabServer.current)
        let workload = try await server.startWorkload(.blockingChain, waiters: 2)
        let client = try await sqlServer(server, trust: true, mode: .optional)
        let processes = try await client.activity.snapshot().processes
        await workload.stop()
        try? await client.shutdownGracefully()
        // SQL Server reports a lock queue: the second waiter waits on the first, the first on the head.
        let blockedBy = Dictionary(uniqueKeysWithValues: processes.compactMap { process in
            process.request?.blockingSessionId.flatMap { $0 > 0 ? (process.sessionId, $0) : nil }
        })
        #expect(blockedBy.count == 2)
        func head(of session: Int) -> Int { blockedBy[session].map(head(of:)) ?? session }
        #expect(Set(blockedBy.keys.map(head(of:))).count == 1, "\(blockedBy)")
        #expect(processes.contains { $0.programName == workload.applicationName })
    }
}

@Suite(.enabled(if: integrationEnabled), .server("pg-17-empty"))
struct PostgresWorkloadTests {
    @Test func blockingChainAndIdleTransaction() async throws {
        let server = try #require(LabServer.current)
        let client = try await PostgresClient.connect(configuration: PostgresConfiguration(
            host: server.host, port: server.port, database: "postgres",
            username: server.username, password: server.password, sslMode: .disable
        ))
        defer { client.close() }
        let chain = try await server.startWorkload(.blockingChain, waiters: 2)
        let processes = try await client.activity.snapshot().processes.filter { $0.applicationName == chain.applicationName }
        let head = processes.first { $0.state == "idle in transaction" }
        let waiting = processes.filter { $0.waitEventType == "Lock" }
        var blockers: [Int32] = []
        if let first = waiting.first { blockers = try await client.blockingSessions(of: first.pid).map(\.pid) }
        await chain.stop()
        #expect(waiting.count == 2)
        #expect(head != nil && blockers == [head!.pid])
    }
}

@Suite(.enabled(if: integrationEnabled), .server("mysql-8.4-empty"))
struct MySQLWorkloadTests {
    @Test func waitersShowInTheProcessList() async throws {
        let server = try #require(LabServer.current)
        let workload = try await server.startWorkload(.blockingChain, waiters: 2)
        let client = MySQLClient(configuration: MySQLConfiguration(host: server.host, port: server.port, username: server.username,
                                                                   password: server.password, tlsMode: .required))
        let processes = try await client.activity.processList()
        await workload.stop()
        await client.close()
        let waiting = processes.filter { $0.info?.contains("workload_rows") == true && $0.state?.contains("updating") == true }
        #expect(waiting.count == 2, "\(processes.map { "\($0.state ?? "-") \($0.info ?? "-")" })")
    }
}
