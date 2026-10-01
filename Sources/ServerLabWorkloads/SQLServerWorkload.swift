import Foundation
import ServerLabKit
import SQLServerKit

/// Sessions on SQL Server, each on its own connection: the head updates row 1 in an open
/// transaction; waiters update the same row and block on its lock.
enum SQLServerWorkload {
    static func client(_ server: ServerEndpoint, database: String = WorkloadTable.database) async throws -> SQLServerClient {
        var configuration = SQLServerClient.Configuration(
            hostname: server.host, port: server.port, database: database,
            authentication: .sqlPassword(username: server.username, password: server.password),
            tlsEnabled: true, trustServerCertificate: server.tls?.mode != .strict,
            caCertificatePath: server.tls?.mode == .strict ? server.tls?.caPath : nil,
            encryptionMode: server.tls?.mode == .strict ? .strict : .mandatory,
            poolConfiguration: .init(maximumConcurrentConnections: 1, minimumIdleConnections: 0)
        )
        configuration.connection.applicationName = WorkloadTable.application
        return try await SQLServerClient.connect(configuration: configuration, numberOfThreads: 1)
    }

    static func prepare(_ server: ServerEndpoint) async throws {
        let client = try await client(server, database: "master")
        defer { Task { try? await client.shutdownGracefully() } }
        if try await !client.admin.listDatabases().contains(WorkloadTable.database) {
            try await client.admin.createDatabase(name: WorkloadTable.database)
            let admin = client.admin.scoped(to: WorkloadTable.database)
            try await admin.createTable(name: WorkloadTable.table, columns: [
                SQLServerColumnDefinition(name: "id", definition: .standard(.init(dataType: .int, isPrimaryKey: true))),
                SQLServerColumnDefinition(name: "value", definition: .standard(.init(dataType: .int))),
            ])
            try await admin.insertRows(into: WorkloadTable.table, columns: ["id", "value"], values: [[.int(1), .int(0)]])
        }
    }

    static func start(_ kind: LabWorkloadKind, waiters: Int, on server: ServerEndpoint) async throws -> LabWorkload {
        try await prepare(server)
        let signal = StopSignal()
        let update = "UPDATE dbo.\(WorkloadTable.table) SET value = value + 1 WHERE id = 1"
        let holding = AsyncStream<Void>.makeStream()
        let head = Task {
            let client = try await client(server)
            defer { Task { try? await client.shutdownGracefully() } }
            try await client.withConnection { connection in
                _ = try await connection.execute("BEGIN TRANSACTION")
                if kind == .blockingChain { _ = try await connection.execute(update) }
                holding.continuation.yield()
                await signal.wait()
                _ = try await connection.execute("ROLLBACK TRANSACTION")
            }
        }
        for await _ in holding.stream { break }
        var sessions = [head]
        if kind == .blockingChain {
            for _ in 0..<waiters {
                sessions.append(Task {
                    let client = try await client(server)
                    defer { Task { try? await client.shutdownGracefully() } }
                    _ = try await client.withConnection { connection in try await connection.execute(update) }
                })
            }
            // Give the waiters time to reach the lock.
            try await Task.sleep(for: .seconds(1))
        }
        return LabWorkload(kind: kind, applicationName: WorkloadTable.application, signal: signal, sessions: sessions)
    }
}
