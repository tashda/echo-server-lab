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
    /// Every container of the server, the main one first. One part for most recipes.
    public var parts: [LabServerPart]
    /// Set when the recipe asked for TLS: the mode, the certificate kind and the files a client needs.
    public var tls: EndpointTLS?

    public init(recipe: String, engine: EngineKind, version: String, host: String, port: Int, username: String,
                password: String, containerID: String, containerName: String, expires: Date, parts: [LabServerPart] = [],
                tls: EndpointTLS? = nil) {
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
        self.parts = parts.isEmpty
            ? [LabServerPart(role: "server", containerID: containerID, containerName: containerName, port: port)]
            : parts
        self.tls = tls
    }

    public var endpoint: ServerEndpoint {
        ServerEndpoint(host: host, port: port, username: username, password: password, tls: tls)
    }

    public func part(_ role: String) throws -> LabServerPart {
        guard let part = parts.first(where: { $0.role == role }) else {
            throw ServerLabError.unknownPart(role, server: containerName, parts: parts.map(\.role))
        }
        return part
    }

    /// Where one part answers, e.g. `endpoint(of: "standby")`.
    public func endpoint(of role: String) throws -> ServerEndpoint {
        ServerEndpoint(host: host, port: try part(role).port, username: username, password: password, tls: tls)
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
            "SERVERLAB_PARTS": parts.map(\.role).joined(separator: ","),
        ]
        // SERVERLAB_STANDBY_PORT and SERVERLAB_STANDBY_CONTAINER for every part after the main one.
        for part in parts.dropFirst() {
            let key = part.role.uppercased().map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined()
            variables["SERVERLAB_\(key)_PORT"] = String(part.port)
            variables["SERVERLAB_\(key)_CONTAINER"] = part.containerName
        }
        if let tls {
            variables["SERVERLAB_TLS_MODE"] = tls.mode.rawValue
            variables["SERVERLAB_TLS_CERTIFICATE"] = tls.certificate.rawValue
            variables["SERVERLAB_TLS_CA"] = tls.caPath
            variables["SERVERLAB_TLS_CLIENT_CERT"] = tls.clientCertificatePath
            variables["SERVERLAB_TLS_CLIENT_KEY"] = tls.clientKeyPath
        }
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
