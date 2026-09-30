import Foundation
import PostgresKit
import ServerLabKit

/// PostgreSQL from the official `postgres` images.
public struct PostgresEngine: LabEngine {
    public let kind = EngineKind.postgres
    public let supportedVersions = ["13", "14", "15", "16", "17", "18"]
    public let adminUsername = "postgres"
    public let packs: [any ContentPack] = [
        PostgresDatabasePack(),
        PostgresColumnTypesPack(),
    ]

    public init() {}

    public func containerSpec(for recipe: Recipe, password: String) throws -> ContainerSpec {
        guard supportedVersions.contains(recipe.version) else {
            throw ServerLabError.unsupportedVersion(kind, recipe.version, supported: supportedVersions)
        }
        var environment = [
            "POSTGRES_PASSWORD": password,
            // The images declare /var/lib/postgresql(/data) as a volume, which `docker commit` skips.
            "PGDATA": "/labdata/pgdata",
        ]
        if let collation = recipe.settings.collation {
            environment["POSTGRES_INITDB_ARGS"] = "--lc-collate=\(collation) --lc-ctype=\(collation)"
        }
        return ContainerSpec(
            image: "postgres:\(recipe.version)",
            internalPort: 5432,
            environment: environment,
            command: ["postgres", "-c", "shared_buffers=256MB", "-c", "max_connections=200"],
            memoryMB: recipe.settings.memoryMB ?? 1_024
        )
    }

    public func waitUntilReady(_ server: ServerEndpoint, timeout: Duration) async throws {
        try await retryUntilReady("PostgreSQL at \(server.host):\(server.port)", timeout: timeout) {
            try await PostgresSession.with(server) { client in
                _ = try await client.metadata.listDatabases()
            }
        }
    }
}

/// Opens a driver client for a lab server and always closes it.
enum PostgresSession {
    static func with<T: Sendable>(
        _ server: ServerEndpoint,
        database: String = "postgres",
        _ body: (PostgresClient) async throws -> T
    ) async throws -> T {
        let client = try await PostgresClient.connect(configuration: PostgresConfiguration(
            host: server.host,
            port: server.port,
            database: database,
            username: server.username,
            password: server.password,
            sslMode: .disable,
            applicationName: "serverlab"
        ), logger: driverLogger("serverlab.postgres"))
        defer { client.close() }
        return try await body(client)
    }
}

/// Creates a database. Parameters: `name` (default `labdata`).
struct PostgresDatabasePack: ContentPack {
    let name = "database"
    let version = 1
    let summary = "A database next to the default one."

    func apply(to server: ServerEndpoint, recipe: Recipe, parameters: PackParameters, log: LabLog) async throws {
        let database = try parameters.string("name", default: Self.defaultName)
        try await PostgresSession.with(server) { client in
            guard try await !client.metadata.listDatabases().contains(database) else { return }
            try await client.admin.createDatabase(name: database)
        }
    }

    func verify(on server: ServerEndpoint, recipe: Recipe, parameters: PackParameters) async throws {
        let database = try parameters.string("name", default: Self.defaultName)
        guard try await PostgresSession.with(server, { try await $0.metadata.listDatabases() }).contains(database) else {
            throw ServerLabError.packCheckFailed(pack: name, reason: "database \(database) is missing")
        }
    }

    static let defaultName = "labdata"
}
