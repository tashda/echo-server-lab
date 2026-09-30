import Foundation
import ServerLabKit
import SQLServerKit

/// SQL Server on Linux containers (amd64 images from mcr.microsoft.com).
public struct SQLServerEngine: LabEngine {
    public let kind = EngineKind.sqlServer
    public let supportedVersions = ["2017", "2019", "2022", "2025"]
    public let adminUsername = "sa"
    public let packs: [any ContentPack] = [
        SQLServerDatabasePack(),
        SQLServerColumnTypesPack(),
        SQLServerAgentJobsPack(),
        SQLServerProgrammabilityPack(),
        SQLServerIndexesPack(),
        SQLServerSecurityPack(),
        SQLServerPartitioningPack(),
        SQLServerTemporalPack(),
        SQLServerLinkedServersPack(),
        SQLServerSamplePack(),
    ]

    public init() {}

    public func containerSpec(for recipe: Recipe, password: String) throws -> ContainerSpec {
        guard supportedVersions.contains(recipe.version) else {
            throw ServerLabError.unsupportedVersion(kind, recipe.version, supported: supportedVersions)
        }
        let memoryMB = recipe.settings.memoryMB ?? 3_072
        var environment = [
            "ACCEPT_EULA": "Y",
            "MSSQL_PID": "Developer",
            "MSSQL_SA_PASSWORD": password,
            "MSSQL_AGENT_ENABLED": (recipe.settings.agent ?? false) ? "true" : "false",
            // Leave room inside the container limit for the process itself.
            "MSSQL_MEMORY_LIMIT_MB": String(max(2_048, memoryMB - 512)),
        ]
        if let collation = recipe.settings.collation { environment["MSSQL_COLLATION"] = collation }
        // The image declares no volumes, so /var/opt/mssql is kept by `docker commit`.
        return ContainerSpec(
            image: "mcr.microsoft.com/mssql/server:\(recipe.version)-latest",
            internalPort: 1433,
            environment: environment,
            memoryMB: memoryMB
        )
    }

    /// TLS through mssql.conf: the lab's certificate, `forceencryption`, and `forcestrict` (2025+).
    public func topology(for recipe: Recipe, password: String, tls: ServerTLS?) throws -> ServerTopology {
        guard recipe.settings.topology == nil else {
            throw ServerLabError.unsupported("Topology '\(recipe.settings.topology ?? "")' on SQL Server")
        }
        guard let tls else { return .single }
        switch tls.mode {
        case .clientCertificate:
            throw ServerLabError.unsupported("Client-certificate login on SQL Server")
        case .strict where recipe.version < "2025":
            throw ServerLabError.unsupported("Strict encryption (TDS 8) on SQL Server \(recipe.version); it needs 2025")
        case .strict where tls.certificateKind != .valid:
            throw ServerLabError.unsupported("Strict encryption with a \(tls.certificateKind.rawValue) certificate (the lab could not log in)")
        default:
            break
        }
        var configuration = """
            [network]
            tlscert = /var/opt/mssql/tls/server.pem
            tlskey = /var/opt/mssql/tls/server.key
            forceencryption = \(tls.mode == .optional ? 0 : 1)

            """
        if tls.mode == .strict { configuration += "forcestrict = 1\n" }
        // The images run SQL Server as uid 10001 (mssql); the seeded images have no mssql.conf of their own.
        return ServerTopology(mainRole: "server", mainFiles: [
            "/var/opt/mssql/mssql.conf": ContainerFile(configuration, owner: 10001),
            "/var/opt/mssql/tls/server.pem": ContainerFile(tls.server.certificatePEM, mode: 0o400, owner: 10001),
            "/var/opt/mssql/tls/server.key": ContainerFile(tls.server.keyPEM, mode: 0o400, owner: 10001),
        ])
    }

    public func waitUntilReady(_ server: ServerEndpoint, timeout: Duration) async throws {
        try await retryUntilReady("SQL Server at \(server.host):\(server.port)", timeout: timeout) {
            try await SQLServerSession.with(server) { client in
                _ = try await client.metadata.listDatabases()
            }
        }
    }
}

/// Opens a driver client for a lab server and always closes it.
enum SQLServerSession {
    static func with<T: Sendable>(
        _ server: ServerEndpoint,
        database: String = "master",
        _ body: (SQLServerClient) async throws -> T
    ) async throws -> T {
        let client = try await SQLServerClient.connect(
            hostname: server.host,
            port: server.port,
            database: database,
            authentication: .sqlPassword(username: server.username, password: server.password),
            tlsEnabled: true,
            // Strict (TDS 8) always checks the certificate; otherwise the lab trusts any, since some
            // servers present bad ones on purpose.
            trustServerCertificate: server.tls?.mode != .strict,
            caCertificatePath: server.tls?.mode == .strict ? server.tls?.caPath : nil,
            encryptionMode: server.tls?.mode == .strict ? .strict : .mandatory,
            logger: driverLogger("serverlab.sqlserver")
        )
        do {
            let result = try await body(client)
            try await client.shutdownGracefully()
            return result
        } catch {
            try? await client.shutdownGracefully()
            throw error
        }
    }
}
