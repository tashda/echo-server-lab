import Foundation
import ServerLabKit

/// Activity on a running server for testing what a client shows about sessions: who blocks
/// whom, who sits in an open transaction. Workloads play a user typing SQL, so unlike packs they
/// send statements through the drivers' query calls. They live until `stop()`.
public enum LabWorkloadKind: String, Sendable, CaseIterable, Codable {
    /// One session holds a row lock in an open transaction; `waiters` more sessions wait for it.
    case blockingChain = "blocking-chain"
    /// One session with an open transaction that does nothing.
    case idleInTransaction = "idle-in-transaction"
}

/// A running workload. Stopping rolls back its transactions and closes its sessions.
public final class LabWorkload: Sendable {
    public let kind: LabWorkloadKind
    /// The application name its sessions report, for finding them in activity views.
    public let applicationName: String
    let signal: StopSignal
    let sessions: [Task<Void, any Error>]

    init(kind: LabWorkloadKind, applicationName: String, signal: StopSignal, sessions: [Task<Void, any Error>]) {
        self.kind = kind
        self.applicationName = applicationName
        self.signal = signal
        self.sessions = sessions
    }

    public func stop() async {
        await signal.fire()
        for session in sessions { _ = try? await session.value }
    }
}

/// Lets sessions wait until the workload stops.
actor StopSignal {
    private var fired = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if fired { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func fire() {
        fired = true
        waiting.forEach { $0.resume() }
        waiting = []
    }
}

/// The table every workload locks a row of: `labworkload.workload_rows` (id, value), row 1.
enum WorkloadTable {
    static let database = "labworkload"
    static let table = "workload_rows"
    static let application = "serverlab-workload"
}

extension LabServer {
    /// Starts a workload on this server and returns once its sessions are in place (the
    /// waiters are waiting).
    public func startWorkload(_ kind: LabWorkloadKind, waiters: Int = 2) async throws -> LabWorkload {
        switch engine {
        case .sqlServer: try await SQLServerWorkload.start(kind, waiters: waiters, on: endpoint)
        case .postgres: try await PostgresWorkload.start(kind, waiters: waiters, on: endpoint)
        case .mysql, .mariadb: try await MySQLWorkload.start(kind, waiters: waiters, on: endpoint)
        }
    }
}
