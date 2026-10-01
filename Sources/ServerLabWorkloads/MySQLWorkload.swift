import Foundation
import Logging
import MySQLKit
import ServerLabKit

/// Sessions on MySQL and MariaDB, each on its own connection: the head updates row 1 in an open
/// transaction; waiters update the same row and wait on InnoDB's row lock (their lock-wait
/// timeout raised to an hour so they keep waiting).
enum MySQLWorkload {
    static func configuration(_ server: ServerEndpoint, database: String? = WorkloadTable.database) -> MySQLWireConfiguration {
        MySQLWireConfiguration(host: server.host, port: server.port, username: server.username, password: server.password,
                               database: database, tlsMode: .required,
                               clientCertificatePath: server.tls?.clientCertificatePath, clientKeyPath: server.tls?.clientKeyPath)
    }

    static func prepare(_ server: ServerEndpoint) async throws {
        let client = MySQLClient(configuration: configuration(server, database: nil))
        defer { Task { await client.close() } }
        try await client.admin.createDatabase(name: WorkloadTable.database, ifNotExists: true)
        if try await !client.metadata.listTables(in: WorkloadTable.database).contains(where: { $0.name == WorkloadTable.table }) {
            try await client.admin.createTable(schema: WorkloadTable.database, name: WorkloadTable.table, columns: [
                MySQLColumnDefinition(name: "id", dataType: "INT", isNullable: false),
                MySQLColumnDefinition(name: "value", dataType: "INT", isNullable: false),
            ], primaryKey: ["id"], options: MySQLTableOptions(engine: "InnoDB"))
            try await client.bulk.insertValues(into: WorkloadTable.table, schema: WorkloadTable.database, columns: ["id", "value"],
                                               rows: [[.data(MySQLData(int: 1)), .data(MySQLData(int: 0))]])
        }
    }

    static func start(_ kind: LabWorkloadKind, waiters: Int, on server: ServerEndpoint) async throws -> LabWorkload {
        try await prepare(server)
        let signal = StopSignal()
        let update = "UPDATE \(WorkloadTable.table) SET value = value + 1 WHERE id = 1"
        let holding = AsyncStream<Void>.makeStream()
        let head = Task {
            let connection = try await MySQLWireConnection.connect(configuration: configuration(server))
            do {
                _ = try await connection.simpleQuery("START TRANSACTION")
                if kind == .blockingChain { _ = try await connection.simpleQuery(update) }
                holding.continuation.yield()
                await signal.wait()
                _ = try await connection.simpleQuery("ROLLBACK")
            } catch {
                holding.continuation.yield()
                try? await connection.close()
                throw error
            }
            try await connection.close()
        }
        for await _ in holding.stream { break }
        var sessions = [head]
        if kind == .blockingChain {
            for _ in 0..<waiters {
                sessions.append(Task {
                    let connection = try await MySQLWireConnection.connect(configuration: configuration(server))
                    _ = try? await connection.simpleQuery("SET SESSION innodb_lock_wait_timeout = 3600")
                    _ = try? await connection.simpleQuery(update)
                    try await connection.close()
                })
            }
            try await Task.sleep(for: .seconds(1))
        }
        return LabWorkload(kind: kind, applicationName: WorkloadTable.application, signal: signal, sessions: sessions)
    }
}
