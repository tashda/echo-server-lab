import Foundation
import PostgresKit
import ServerLabKit

/// Sessions on PostgreSQL, each on its own connection: the head updates row 1 in an open
/// transaction (`idle in transaction` once it waits); waiters update the same row and block.
enum PostgresWorkload {
    static func client(_ server: ServerEndpoint, database: String = WorkloadTable.database) async throws -> PostgresClient {
        try await PostgresClient.connect(configuration: PostgresConfiguration(
            host: server.host, port: server.port, database: database,
            username: server.username, password: server.password,
            sslMode: server.tls == nil ? .disable : .require,
            sslCertPath: server.tls?.clientCertificatePath, sslKeyPath: server.tls?.clientKeyPath,
            applicationName: WorkloadTable.application
        ))
    }

    static func prepare(_ server: ServerEndpoint) async throws {
        let admin = try await client(server, database: "postgres")
        defer { admin.close() }
        try await admin.admin.createDatabase(name: WorkloadTable.database, ifNotExists: true)
        let client = try await client(server)
        defer { client.close() }
        if try await !client.metadata.listTablesAndViews(schema: "public").contains(where: { $0.name == WorkloadTable.table }) {
            _ = try await client.admin.createTable(name: WorkloadTable.table, schema: "public", columns: [
                PostgresColumnDefinition(name: "id", dataType: "integer", nullable: false, primaryKey: true),
                PostgresColumnDefinition(name: "value", dataType: "integer"),
            ])
            _ = try await client.bulk.insert(into: WorkloadTable.table, schema: "public", columns: ["id", "value"], values: [[.bind(1), .bind(0)]])
        }
    }

    static func start(_ kind: LabWorkloadKind, waiters: Int, on server: ServerEndpoint) async throws -> LabWorkload {
        try await prepare(server)
        let signal = StopSignal()
        let update = "UPDATE public.\(WorkloadTable.table) SET value = value + 1 WHERE id = 1"
        let holding = AsyncStream<Void>.makeStream()
        let head = Task {
            let client = try await client(server)
            defer { client.close() }
            try await client.withConnection { connection in
                for try await _ in try await connection.query("BEGIN") {}
                if kind == .blockingChain { for try await _ in try await connection.query(update) {} }
                holding.continuation.yield()
                await signal.wait()
                for try await _ in try await connection.query("ROLLBACK") {}
            }
        }
        for await _ in holding.stream { break }
        var sessions = [head]
        if kind == .blockingChain {
            for _ in 0..<waiters {
                sessions.append(Task {
                    let client = try await client(server)
                    defer { client.close() }
                    try await client.withConnection { connection in
                        for try await _ in try await connection.query(update) {}
                    }
                })
            }
            try await Task.sleep(for: .seconds(1))
        }
        return LabWorkload(kind: kind, applicationName: WorkloadTable.application, signal: signal, sessions: sessions)
    }
}
