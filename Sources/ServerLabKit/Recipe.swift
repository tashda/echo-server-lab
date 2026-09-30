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
    /// Encrypted connections: the mode and which certificate the server presents. Nil is no TLS setup
    /// (SQL Server still encrypts the login with its own self-signed certificate).
    public var tls: TLSSettings?
    /// Kerberos (and NTLM on SQL Server) logins through an Active Directory domain: a Samba DC part,
    /// a service account with SPNs, and the domain user `labuser`.
    public var kerberos: Bool?
    /// Replicas of an `availability-group` topology, the primary included (default 2).
    public var replicas: Int?

    public init(agent: Bool? = nil, collation: String? = nil, memoryMB: Int? = nil, imageVariant: String? = nil,
                topology: String? = nil, tls: TLSSettings? = nil, kerberos: Bool? = nil, replicas: Int? = nil) {
        self.agent = agent
        self.collation = collation
        self.memoryMB = memoryMB
        self.imageVariant = imageVariant
        self.topology = topology
        self.tls = tls
        self.kerberos = kerberos
        self.replicas = replicas
    }
}

public struct TLSSettings: Codable, Sendable, Hashable {
    public var mode: TLSMode
    public var certificate: LabCertificateKind

    public init(mode: TLSMode, certificate: LabCertificateKind = .valid) {
        self.mode = mode
        self.certificate = certificate
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decode(TLSMode.self, forKey: .mode)
        certificate = try container.decodeIfPresent(LabCertificateKind.self, forKey: .certificate) ?? .valid
    }
}

public enum TLSMode: String, Codable, Sendable, Hashable, CaseIterable {
    /// TLS offered; the client chooses (SQL Server: `forceencryption 0`; PostgreSQL: `ssl=on`, `host` rules).
    case optional
    /// Every connection must use TLS (SQL Server: `forceencryption 1`; PostgreSQL: `hostssl` only).
    case required
    /// TLS before anything else: TDS 8 strict (SQL Server 2025, `forcestrict 1`); PostgreSQL: TLS 1.3 only.
    case strict
    /// PostgreSQL `cert` login: TLS plus a client certificate whose common name is the user.
    case clientCertificate = "client-certificate"
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
