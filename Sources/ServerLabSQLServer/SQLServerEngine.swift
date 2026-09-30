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
            trustServerCertificate: true,
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
