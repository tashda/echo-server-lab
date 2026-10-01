import Foundation
import ServerLabKit
import ServerLabTesting
import SQLServerKit
import Testing

/// Replication from the seeded image still works in a server started later: a new customer at
/// the publisher reaches the subscriber when the agents run again.
@Suite(.enabled(if: integrationEnabled), .server("mssql-2022-replication"))
struct SQLServerReplicationServerTests {
    func client(_ database: String) async throws -> SQLServerClient {
        let server = try #require(LabServer.current)
        return try await SQLServerClient.connect(
            hostname: server.host, port: server.port, database: database,
            authentication: .sqlPassword(username: server.username, password: server.password),
            tlsEnabled: true, trustServerCertificate: true, encryptionMode: .optional)
    }

    @Test func publicationSubscriptionAndAgentsWork() async throws {
        let publisher = try await client("SalesHub")
        defer { Task { try? await publisher.shutdownGracefully() } }
        #expect(try await publisher.replication.listPublications().map(\.name) == ["LabSnapshot"])
        #expect(try await publisher.replication.listSubscriptions().map(\.subscriberDB) == ["SalesReplica"])
        let agents = try await publisher.replication.agentStatus()
        #expect(Set(agents.map(\.agentType)) == ["Snapshot", "Distribution"])

        try await publisher.admin.scoped(to: "SalesHub").insertRows(into: "Customers", columns: ["Id", "Name"], values: [[.int(26), .nString("Late customer")]])
        for type in ["Snapshot", "Distribution"] {
            let job = try #require(agents.first { $0.agentType == type }?.name)
            let before = try await publisher.replication.agentStatus().first { $0.name == job }?.lastRunTime
            try await publisher.agent.startJob(named: job)
            var finished = false
            for _ in 0..<80 where !finished {
                try await Task.sleep(for: .seconds(3))
                let status = try await publisher.replication.agentStatus().first { $0.name == job }
                finished = status?.lastRunTime != before && (status?.status == "Succeeded" || status?.status == "Idle")
            }
            #expect(finished, "\(type) agent did not finish")
        }
        let replica = try await client("SalesReplica")
        defer { Task { try? await replica.shutdownGracefully() } }
        #expect(try await replica.metadata.tableProperties(database: "SalesReplica", schema: "dbo", table: "Customers").rowCount == 26)
    }
}
