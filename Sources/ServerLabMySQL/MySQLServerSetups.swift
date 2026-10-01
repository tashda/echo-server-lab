import Foundation
import MySQLKit
import ServerLabKit

/// TLS for MySQL and MariaDB: the lab's certificate, `require_secure_transport` for `required`,
/// `strict` and `client-certificate`, TLS 1.3 only for `strict`, and for `client-certificate` the
/// admin account altered to `REQUIRE X509` once the server runs (`configure`).
extension MySQLEngine {
    public func topology(for recipe: Recipe, setup: ServerSetup) throws -> ServerTopology {
        let withReplica: Bool
        switch recipe.settings.topology {
        case nil: withReplica = false
        case Self.sourceReplica?: withReplica = true
        case let other?: throw ServerLabError.unsupported("Topology '\(other)' on \(kind.displayName) (use \(Self.sourceReplica))")
        }
        guard setup.kerberos == nil, recipe.settings.kerberos != true else {
            throw ServerLabError.unsupported("Kerberos on \(kind.displayName)")
        }
        guard setup.tls != nil || withReplica else { return .single }
        var files: [String: ContainerFile] = [:]
        var arguments: [String] = []
        if let tls = setup.tls {
            arguments = ["--ssl-ca=/labconf/ca.pem", "--ssl-cert=/labconf/server.pem", "--ssl-key=/labconf/server.key"]
            if tls.mode != .optional { arguments.append("--require-secure-transport=ON") }
            if tls.mode == .strict { arguments.append("--tls-version=TLSv1.3") }
            // The images run the server as uid 999 (mysql).
            files = [
                "/labconf/ca.pem": ContainerFile(tls.caPEM),
                "/labconf/server.pem": ContainerFile(tls.server.certificatePEM),
                "/labconf/server.key": ContainerFile(tls.server.keyPEM, mode: 0o600, owner: 999),
            ]
        }
        guard withReplica else { return ServerTopology(mainRole: "server", mainFiles: files, mainArguments: arguments) }
        var replica = try containerSpec(for: recipe, password: setup.password)
        replica.command = Array(replica.command.prefix { !$0.hasPrefix("--server-id") }) + Self.replicationArguments(kind: kind, serverID: 2)
            + ["--relay-log=relay"] + arguments
        replica.files = files
        return ServerTopology(mainRole: "primary", mainFiles: files, mainArguments: arguments,
                              parts: [ServerPartSpec(role: Self.replicaRole, container: replica)])
    }
}

/// `source-replica`: the seeded server as primary (binary log and GTIDs on) and an empty replica
/// that follows it from its first transaction through mysql-wire's replication API.
extension MySQLEngine {
    static let sourceReplica = "source-replica"
    static let replicaRole = "replica"
    static let replicationUser = "lab_replication"

    static func replicationArguments(kind: EngineKind, serverID: Int) -> [String] {
        kind == .mysql
            ? ["--server-id=\(serverID)", "--log-bin=binlog", "--gtid-mode=ON", "--enforce-gtid-consistency=ON"]
            : ["--server-id=\(serverID)", "--log-bin=binlog", "--log-slave-updates=ON"]
    }

    /// `client-certificate`: root may only log in with a certificate the lab CA signed.
    public func configure(_ server: LabServer) async throws {
        guard server.tls?.mode == .clientCertificate else { return }
        try await MySQLSession.with(server.endpoint) { client in
            try await client.security.alterUserTLS(username: adminUsername, host: "%", tls: .x509)
        }
    }

    public func waitUntilTopologyReady(_ server: LabServer, files: any ServerPartFiles) async throws {
        guard server.parts.contains(where: { $0.role == Self.replicaRole }) else { return }
        let databases = try await MySQLSession.with(server.endpoint) { client in
            _ = try await client.security.createUser(username: Self.replicationUser, host: "%", password: server.password)
            _ = try await client.security.grant("REPLICATION SLAVE, REPLICATION CLIENT", on: "*.*", to: Self.replicationUser, host: "%")
            return try await client.metadata.listDatabases()
        }
        try await MySQLSession.with(try server.endpoint(of: Self.replicaRole)) { client in
            try await client.replication.configureSource(host: "primary", user: Self.replicationUser, password: server.password,
                                                         useTLS: server.tls != nil)
            try await client.replication.startReplica()
            try await client.replication.setReadOnly(true)
        }
        try await retryUntilReady("replica of \(server.containerName)", timeout: .seconds(120), every: .seconds(1)) {
            let (state, present) = try await MySQLSession.with(try server.endpoint(of: Self.replicaRole)) { client in
                (try await client.replication.replicaState(), try await client.metadata.listDatabases())
            }
            guard let state, state.ioRunning, state.sqlRunning, Set(databases).isSubset(of: Set(present)) else {
                throw ServerLabError.notReady("replication", lastError: state?.lastError ?? "has \(present)")
            }
        }
    }

    /// The replica stops following, forgets its source and takes writes.
    public func promote(_ role: String, of server: LabServer) async throws {
        try await MySQLSession.with(try server.endpoint(of: role)) { client in
            try await client.replication.stopReplica()
            try await client.replication.resetReplica()
            try await client.replication.setReadOnly(false)
        }
    }
}
