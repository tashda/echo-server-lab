import ServerLabKit
import ServerLabTesting
import SQLServerKit
import Testing

/// Backup history, waiting broker messages and a forced Query Store plan survive the seeded image.
@Suite(.enabled(if: integrationEnabled), .server("mssql-2022-operations"))
struct SQLServerOperationsServerTests {
    @Test func backupHistoryHasEveryKind() async throws {
        let client = try await sqlServer(try #require(LabServer.current), trust: true, mode: .optional)
        defer { Task { try? await client.shutdownGracefully() } }
        let history = try await client.backupRestore.getBackupHistory(database: "BackedUp")
        #expect(Set(history.map(\.type)).count >= 3, "types \(history.map(\.type))")
        #expect(history.contains { $0.name == "Lab full" && ($0.compressedSize ?? $0.size) < $0.size })
    }

    @Test func brokerMessagesWait() async throws {
        let client = try await sqlServer(try #require(LabServer.current), trust: true, mode: .optional)
        defer { Task { try? await client.shutdownGracefully() } }
        #expect(try await client.serviceBroker.messageCount(database: "BrokerLab", queue: "OrderQueue") == 3)
        let queues = try await client.serviceBroker.listQueues(database: "BrokerLab")
        #expect(queues.contains { $0.name == "PausedQueue" })
    }

    @Test func forcedPlanIsStillForced() async throws {
        let client = try await sqlServer(try #require(LabServer.current), trust: true, mode: .optional)
        defer { Task { try? await client.shutdownGracefully() } }
        var forced = 0
        for query in try await client.queryStore.topQueries(database: "QueryStoreLab", limit: 20) {
            forced += try await client.queryStore.queryPlans(database: "QueryStoreLab", queryId: query.queryId).filter(\.isForcedPlan).count
        }
        #expect(forced >= 1)
    }
}
