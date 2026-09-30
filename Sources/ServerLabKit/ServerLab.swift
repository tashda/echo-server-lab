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

    public var endpoint: ServerEndpoint {
        ServerEndpoint(host: host, port: port, username: username, password: password)
    }

    /// `SERVERLAB_*` variables for scripts and other test runners.
    public var environment: [String: String] {
        [
            "SERVERLAB_RECIPE": recipe,
            "SERVERLAB_ENGINE": engine.rawValue,
            "SERVERLAB_VERSION": version,
            "SERVERLAB_HOST": host,
            "SERVERLAB_PORT": String(port),
            "SERVERLAB_USER": username,
            "SERVERLAB_PASSWORD": password,
            "SERVERLAB_CONTAINER": containerName,
        ]
    }
}
