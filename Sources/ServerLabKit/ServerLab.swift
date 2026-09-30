import Foundation

/// The lab: engines, recipes and one Docker host. Tests, the CLI and Echo Labs all go through this.
public struct ServerLab: Sendable {
    public let host: LabHost
    public let recipes: RecipeCatalog
    let engines: [EngineKind: any LabEngine]
    let docker: DockerCommand

    public init(host: LabHost, engines: [any LabEngine], recipes: RecipeCatalog) throws {
        self.host = host
        self.recipes = recipes
        self.engines = Dictionary(uniqueKeysWithValues: engines.map { ($0.kind, $0) })
        self.docker = try DockerCommand(host: host)
    }

    public func engine(for kind: EngineKind) throws -> any LabEngine {
        guard let engine = engines[kind] else { throw ServerLabError.unknownEngine(kind) }
        return engine
    }

    public var allEngines: [any LabEngine] {
        EngineKind.allCases.compactMap { engines[$0] }
    }

    /// Checks that a recipe's engine, version and packs exist before any container starts.
    public func validate(_ recipe: Recipe) throws {
        let engine = try engine(for: recipe.engine)
        guard engine.supportedVersions.contains(recipe.version) else {
            throw ServerLabError.unsupportedVersion(recipe.engine, recipe.version, supported: engine.supportedVersions)
        }
        for use in recipe.packs where engine.pack(named: use.pack) == nil {
            throw ServerLabError.unknownPack(use.pack, engine: recipe.engine)
        }
    }
}

/// A server started for a suite. Stop it with `ServerLab.stop(_:)`.
public struct LabServer: Sendable, Hashable, Codable {
    public var recipe: String
    public var engine: EngineKind
    public var version: String
    public var host: String
    public var port: Int
    public var username: String
    public var password: String
    public var containerID: String
    public var containerName: String
    public var expires: Date

    public init(recipe: String, engine: EngineKind, version: String, host: String, port: Int, username: String,
                password: String, containerID: String, containerName: String, expires: Date) {
        self.recipe = recipe
        self.engine = engine
        self.version = version
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.containerID = containerID
        self.containerName = containerName
        self.expires = expires
    }

    public var endpoint: ServerEndpoint {
        ServerEndpoint(host: host, port: port, username: username, password: password)
    }

    /// `SERVERLAB_*` variables for scripts, plus the variables the engine's driver test suite reads
    /// (`TDS_*` for sqlserver-nio, `POSTGRES_*` for postgres-wire).
    public var environment: [String: String] {
        var variables = [
            "SERVERLAB_RECIPE": recipe,
            "SERVERLAB_ENGINE": engine.rawValue,
            "SERVERLAB_VERSION": version,
            "SERVERLAB_HOST": host,
            "SERVERLAB_PORT": String(port),
            "SERVERLAB_USER": username,
            "SERVERLAB_PASSWORD": password,
            "SERVERLAB_CONTAINER": containerName,
        ]
        switch engine {
        case .sqlServer:
            variables.merge(["TDS_HOSTNAME": host, "TDS_PORT": String(port), "TDS_USERNAME": username,
                             "TDS_PASSWORD": password, "TDS_DATABASE": "master"]) { current, _ in current }
        case .postgres:
            variables.merge(["POSTGRES_HOST": host, "POSTGRES_PORT": String(port), "POSTGRES_USERNAME": username,
                             "POSTGRES_PASSWORD": password, "POSTGRES_DATABASE": "postgres"]) { current, _ in current }
        }
        return variables
    }
}
