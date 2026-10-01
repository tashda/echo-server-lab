import Foundation
import MySQLKit
import ServerLabKit

/// MySQL and MariaDB from their official images. One engine type, two kinds: the packs ask
/// `recipe.engine` where the products differ.
public struct MySQLEngine: LabEngine {
    public let kind: EngineKind
    public let supportedVersions: [String]
    public let adminUsername = "root"
    public let packs: [any ContentPack] = [
        MySQLDatabasePack(),
        MySQLColumnTypesPack(),
        MySQLProgrammabilityPack(),
        MySQLIndexesPack(),
        MySQLSecurityPack(),
        MySQLSamplePack(),
        MySQLPartitioningPack(),
        MariaDBTemporalPack(),
        MySQLAuthenticationPack(),
    ]

    public init(_ kind: EngineKind) {
        precondition(kind == .mysql || kind == .mariadb, "MySQLEngine runs MySQL or MariaDB")
        self.kind = kind
        supportedVersions = kind == .mysql ? ["8.0", "8.4", "9"] : ["10.6", "10.11", "11.4", "11.8"]
    }

    public func containerSpec(for recipe: Recipe, password: String) throws -> ContainerSpec {
        guard supportedVersions.contains(recipe.version) else {
            throw ServerLabError.unsupportedVersion(kind, recipe.version, supported: supportedVersions)
        }
        let server = kind == .mysql ? "mysqld" : "mariadbd"
        var command = [server,
                       // The images declare /var/lib/mysql as a volume, which `docker commit` skips.
                       "--datadir=/labdata/mysql",
                       "--innodb-buffer-pool-size=256M", "--max-connections=200"]
        if recipe.settings.topology == Self.sourceReplica {
            // Binary log and GTIDs from the first build on, so a replica can follow from the start.
            command += Self.replicationArguments(kind: kind, serverID: 1)
        }
        if let collation = recipe.settings.collation {
            command += ["--collation-server=\(collation)", "--character-set-server=\(collation.prefix { $0 != "_" })"]
        }
        command += (recipe.settings.serverOptions ?? [:]).sorted { $0.key < $1.key }.map { "--\($0.key)=\($0.value)" }
        return ContainerSpec(
            image: "\(kind == .mysql ? "mysql" : "mariadb"):\(recipe.version)",
            internalPort: 3306,
            environment: kind == .mysql ? ["MYSQL_ROOT_PASSWORD": password] : ["MARIADB_ROOT_PASSWORD": password],
            command: command,
            memoryMB: recipe.settings.memoryMB ?? 1_024
        )
    }

    public func waitUntilReady(_ server: ServerEndpoint, timeout: Duration) async throws {
        try await retryUntilReady("\(kind.displayName) at \(server.host):\(server.port)", timeout: timeout) {
            _ = try await MySQLSession.with(server) { try await $0.metadata.listDatabases() }
        }
    }
}

/// Opens a driver client for a lab server and always closes it.
enum MySQLSession {
    static func with<T: Sendable>(_ server: ServerEndpoint, database: String? = nil,
                                  _ body: (MySQLClient) async throws -> T) async throws -> T {
        let client = MySQLClient(configuration: MySQLConfiguration(
            host: server.host, port: server.port, username: server.username, password: server.password,
            database: database, tlsMode: .required, connectTimeoutSeconds: 10
        ), logger: driverLogger("serverlab.mysql"))
        do {
            let result = try await body(client)
            await client.close()
            return result
        } catch {
            await client.close()
            throw error
        }
    }
}

/// Creates a database. Parameters: `name` (default `labdata`), `characterSet`, `collation`.
struct MySQLDatabasePack: ContentPack {
    let name = "database"
    let version = 1
    let summary = "A database (schema) with a chosen character set and collation."
    static let defaultName = "labdata"

    func apply(to server: ServerEndpoint, recipe: Recipe, parameters: PackParameters, context: PackContext) async throws {
        let database = try parameters.string("name", default: Self.defaultName)
        let characterSet = try parameters.string("characterSet", default: "utf8mb4")
        let collation = try parameters.string("collation", default: "")
        try await MySQLSession.with(server) { client in
            try await client.admin.createDatabase(name: database, characterSet: characterSet,
                                                  collation: collation.isEmpty ? nil : collation, ifNotExists: true)
        }
    }

    func verify(on server: ServerEndpoint, recipe: Recipe, parameters: PackParameters) async throws {
        let database = try parameters.string("name", default: Self.defaultName)
        guard try await MySQLSession.with(server, { try await $0.metadata.listDatabases() }).contains(database) else {
            throw ServerLabError.packCheckFailed(pack: name, reason: "database \(database) is missing")
        }
    }
}
