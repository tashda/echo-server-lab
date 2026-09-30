import Foundation

/// A server a test can ask for: an engine and version, start-time settings, and the
/// content packs that fill it. Recipes are JSON files; the name is the handle tests use.
public struct Recipe: Codable, Sendable, Hashable {
    public var name: String
    public var summary: String
    public var engine: EngineKind
    public var version: String
    public var settings: ServerSettings
    public var packs: [PackUse]

    public init(
        name: String,
        summary: String = "",
        engine: EngineKind,
        version: String,
        settings: ServerSettings = .init(),
        packs: [PackUse] = []
    ) {
        self.name = name
        self.summary = summary
        self.engine = engine
        self.version = version
        self.settings = settings
        self.packs = packs
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        engine = try container.decode(EngineKind.self, forKey: .engine)
        version = try container.decode(String.self, forKey: .version)
        settings = try container.decodeIfPresent(ServerSettings.self, forKey: .settings) ?? .init()
        packs = try container.decodeIfPresent([PackUse].self, forKey: .packs) ?? []
    }
}

public enum EngineKind: String, Codable, Sendable, Hashable, CaseIterable {
    case sqlServer = "sqlserver"
    case postgres = "postgresql"
}

/// Settings chosen when the server starts, not created with a pack.
public struct ServerSettings: Codable, Sendable, Hashable {
    /// SQL Server Agent on or off.
    public var agent: Bool?
    /// Server collation (SQL Server) or default locale (PostgreSQL).
    public var collation: String?
    /// Hard memory limit of the container, in MB. The engine picks a default when nil.
    public var memoryMB: Int?
    /// An image built on the engine's official one with extras, e.g. `pgvector` or `postgis` for
    /// PostgreSQL. Nil uses the official image.
    public var imageVariant: String?
    /// Several containers instead of one, e.g. `primary-standby` for PostgreSQL. Nil is one server.
    public var topology: String?

    public init(agent: Bool? = nil, collation: String? = nil, memoryMB: Int? = nil, imageVariant: String? = nil, topology: String? = nil) {
        self.agent = agent
        self.collation = collation
        self.memoryMB = memoryMB
        self.imageVariant = imageVariant
        self.topology = topology
    }
}

/// One pack in a recipe, with its parameters.
public struct PackUse: Codable, Sendable, Hashable {
    public var pack: String
    public var params: PackParameters

    public init(_ pack: String, params: PackParameters = .init()) {
        self.pack = pack
        self.params = params
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pack = try container.decode(String.self, forKey: .pack)
        params = try container.decodeIfPresent(PackParameters.self, forKey: .params) ?? .init()
    }
}
