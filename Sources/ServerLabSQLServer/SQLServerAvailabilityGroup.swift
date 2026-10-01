import Foundation
import ServerLabKit
import SQLServerKit

/// `availability-group`: the seeded server as primary and fresh secondaries from the base image, in
/// an Always On availability group without a cluster manager (CLUSTER_TYPE = NONE), joined by a
/// certificate-authenticated endpoint; the user databases seed to the secondaries automatically.
extension SQLServerEngine {
    static let availabilityGroup = "availability-group"
    static let primaryRole = "primary"
    static let groupName = "LabAG"
    static let endpointCertificate = "lab_ag_certificate"
    static let certificateDirectory = "/var/opt/mssql/data"

    /// Secondaries are `secondary`, `secondary2`, ….
    static func secondaryRoles(_ recipe: Recipe) -> [String] {
        let count = max(2, recipe.settings.replicas ?? 2) - 1
        return (1...count).map { $0 == 1 ? "secondary" : "secondary\($0)" }
    }

    func availabilityGroupTopology(for recipe: Recipe, password: String, files: [String: ContainerFile]) throws -> ServerTopology {
        let base = try containerSpec(for: recipe, password: password)
        let parts = Self.secondaryRoles(recipe).map { role in
            var spec = base
            spec.hostname = role
            spec.files = files
            return ServerPartSpec(role: role, container: spec)
        }
        return ServerTopology(mainRole: Self.primaryRole, mainFiles: files, parts: parts)
    }

    public func waitUntilTopologyReady(_ server: LabServer, files: any ServerPartFiles) async throws {
        try await deliverMail(server)
        let secondaries = server.parts.map(\.role).filter { $0.hasPrefix("secondary") }
        guard !secondaries.isEmpty else { return }
        let certificate = "\(Self.certificateDirectory)/\(Self.endpointCertificate).cer"
        let privateKey = "\(Self.certificateDirectory)/\(Self.endpointCertificate).pvk"

        // One certificate for every endpoint: made on the primary, copied to the secondaries.
        let databases = try await SQLServerSession.with(try server.endpoint(of: Self.primaryRole)) { client in
            try await client.security.createMasterKey(password: server.password)
            try await client.security.createCertificate(name: Self.endpointCertificate, subject: "Echo server lab availability group")
            try await client.security.backupCertificate(name: Self.endpointCertificate, toFile: certificate,
                                                        privateKeyFile: privateKey, privateKeyPassword: server.password)
            try await client.availabilityGroups.createEndpoint(certificate: Self.endpointCertificate)
            return try await client.metadata.listDatabases().map(\.name)
                .filter { !["master", "tempdb", "model", "msdb"].contains($0) }
        }
        try await files.copy(certificate, from: Self.primaryRole, to: secondaries)
        try await files.copy(privateKey, from: Self.primaryRole, to: secondaries)
        for role in secondaries {
            try await SQLServerSession.with(try server.endpoint(of: role)) { client in
                try await client.security.createMasterKey(password: server.password)
                try await client.security.createCertificate(name: Self.endpointCertificate, fromFile: certificate,
                                                            privateKeyFile: privateKey, privateKeyPassword: server.password)
                try await client.availabilityGroups.createEndpoint(certificate: Self.endpointCertificate)
            }
        }

        // Databases in an AG need the full recovery model and a full backup.
        try await SQLServerSession.with(try server.endpoint(of: Self.primaryRole)) { client in
            for database in databases {
                try await client.admin.alterDatabaseOption(name: database, option: .recoveryModel(.full))
                _ = try await client.backupRestore.backup(options: SQLServerBackupOptions(
                    database: database, destinations: [.disk(path: "\(Self.certificateDirectory)/\(database)-ag.bak")], initMedia: true
                ))
            }
            try await client.availabilityGroups.createGroup(
                name: Self.groupName,
                replicas: ([Self.primaryRole] + secondaries).map { SQLServerAGReplicaSpec(serverName: $0, endpointURL: "TCP://\($0):5022") },
                databases: databases,
                options: SQLServerAGOptions(clusterType: .none)
            )
        }
        for role in secondaries {
            try await SQLServerSession.with(try server.endpoint(of: role)) { client in
                try await client.availabilityGroups.join(groupName: Self.groupName, clusterType: .none)
                try await client.availabilityGroups.grantCreateAnyDatabase(groupName: Self.groupName)
            }
        }
        for role in secondaries {
            let endpoint = try server.endpoint(of: role)
            try await retryUntilReady("\(databases.joined(separator: ", ")) seeded to \(role)", timeout: .seconds(300)) {
                let present = try await SQLServerSession.with(endpoint) { try await $0.metadata.listDatabases().map(\.name) }
                guard Set(databases).isSubset(of: present) else {
                    throw ServerLabError.notReady("seeding", lastError: "\(role) has \(present)")
                }
            }
        }
    }

    /// Manual failover of a CLUSTER_TYPE = NONE group: the other replicas step down, the target
    /// forces the failover.
    public func promote(_ role: String, of server: LabServer) async throws {
        let others = server.parts.map(\.role).filter { ($0 == Self.primaryRole || $0.hasPrefix("secondary")) && $0 != role }
        for other in others {
            try? await SQLServerSession.with(try server.endpoint(of: other)) { client in
                try await client.availabilityGroups.demoteToSecondary(groupName: Self.groupName)
            }
        }
        let endpoint = try server.endpoint(of: role)
        let databases = try await SQLServerSession.with(endpoint) { client in
            try await client.availabilityGroups.forceFailover(groupName: Self.groupName)
            return try await client.metadata.listDatabases().map(\.name).filter { !["master", "tempdb", "model", "msdb"].contains($0) }
        }
        // The databases recover in their new role before they take connections.
        for database in databases {
            try await retryUntilReady("\(database) on the new primary \(role)", timeout: .seconds(120), every: .milliseconds(500)) {
                _ = try await SQLServerSession.with(endpoint, database: database) { try await $0.metadata.listDatabases() }
            }
        }
    }
}
