import Foundation
import Logging

/// Where a running server answers and how to log in.
public struct ServerEndpoint: Sendable, Hashable {
    public var host: String
    public var port: Int
    public var username: String
    public var password: String
    /// Set when the server was started with TLS: how the lab's own connections must connect.
    public var tls: EndpointTLS?

    public init(host: String, port: Int, username: String, password: String, tls: EndpointTLS? = nil) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.tls = tls
    }
}

/// TLS for a connection to a lab server: the mode and the files a driver needs.
public struct EndpointTLS: Sendable, Hashable, Codable {
    public var mode: TLSMode
    public var certificate: LabCertificateKind
    /// The lab CA (PEM), for `caCertificatePath` / `sslRootCertPath`.
    public var caPath: String
    /// For `client-certificate` servers: the admin user's certificate and key (PEM).
    public var clientCertificatePath: String?
    public var clientKeyPath: String?

    public init(mode: TLSMode, certificate: LabCertificateKind, caPath: String, clientCertificatePath: String? = nil, clientKeyPath: String? = nil) {
        self.mode = mode
        self.certificate = certificate
        self.caPath = caPath
        self.clientCertificatePath = clientCertificatePath
        self.clientKeyPath = clientKeyPath
    }
}

/// Progress lines while the lab builds or starts a server.
public typealias LabLog = @Sendable (String) -> Void

/// One database engine: how to run it in a container and which packs can fill it.
public protocol LabEngine: Sendable {
    var kind: EngineKind { get }
    var supportedVersions: [String] { get }
    var adminUsername: String { get }
    var packs: [any ContentPack] { get }

    /// The container for a recipe. Data must live outside the image's declared volumes,
    /// so `docker commit` keeps it in the seeded image.
    func containerSpec(for recipe: Recipe, password: String) throws -> ContainerSpec

    /// Returns once the server accepts logins through the driver.
    func waitUntilReady(_ server: ServerEndpoint, timeout: Duration) async throws

    /// The containers the recipe's `topology` setting asks for, with the files and arguments its
    /// `tls` and `kerberos` settings need (`setup` holds certificates and keytab). One container
    /// unless overridden.
    func topology(for recipe: Recipe, setup: ServerSetup) throws -> ServerTopology

    /// The account and SPNs the engine's service needs in the domain, for a server published on
    /// `hostPort`. `serverID` makes host and account names unique in the shared domain.
    func kerberosService(for recipe: Recipe, serverID: String, hostPort: Int) throws -> KerberosService

    /// Runs once every part is up, through the driver: logins for the domain user, ….
    func configure(_ server: LabServer) async throws

    /// Sets the parts up to work together and returns once they do (a standby streams from its
    /// primary, an availability group's databases are synchronized, …). `files` copies files the
    /// servers wrote (certificates) from one part to others.
    func waitUntilTopologyReady(_ server: LabServer, files: any ServerPartFiles) async throws

    /// Makes the part with this role the primary (a standby, an AG secondary), through the driver.
    func promote(_ role: String, of server: LabServer) async throws
}

extension LabEngine {
    public func topology(for recipe: Recipe, setup: ServerSetup) throws -> ServerTopology {
        guard recipe.settings.topology == nil else {
            throw ServerLabError.unsupported("Topology '\(recipe.settings.topology ?? "")' on \(kind.rawValue)")
        }
        guard setup.tls == nil else { throw ServerLabError.unsupported("TLS on \(kind.rawValue)") }
        guard setup.kerberos == nil else { throw ServerLabError.unsupported("Kerberos on \(kind.rawValue)") }
        return .single
    }

    public func kerberosService(for recipe: Recipe, serverID: String, hostPort: Int) throws -> KerberosService {
        throw ServerLabError.unsupported("Kerberos on \(kind.rawValue)")
    }

    public func configure(_ server: LabServer) async throws {}

    public func waitUntilTopologyReady(_ server: LabServer, files: any ServerPartFiles) async throws {}

    public func promote(_ role: String, of server: LabServer) async throws {
        throw ServerLabError.unsupported("Promoting a \(kind.rawValue) server")
    }
}

extension ContentPack {
    /// Sample files (`LabSamples`) the pack needs mounted in the builder. Most packs need none.
    public func requiredSamples(parameters: PackParameters) throws -> [String] { [] }
}

extension LabEngine {
    public func pack(named name: String) -> (any ContentPack)? {
        packs.first { $0.name == name }
    }
}

/// Content for a server, created only through the engine's driver.
public protocol ContentPack: Sendable {
    var name: String { get }
    /// Raise when what the pack creates changes; seeded images are rebuilt.
    var version: Int { get }
    var summary: String { get }

    func apply(to server: ServerEndpoint, recipe: Recipe, parameters: PackParameters, context: PackContext) async throws
    /// Throws `ServerLabError.packCheckFailed` when the server does not hold what the pack promised.
    func verify(on server: ServerEndpoint, recipe: Recipe, parameters: PackParameters) async throws
    func requiredSamples(parameters: PackParameters) throws -> [String]
}

public struct ContainerSpec: Sendable, Hashable {
    public var image: String
    public var internalPort: Int
    public var environment: [String: String]
    public var command: [String]
    public var memoryMB: Int
    /// Files put into the container before it starts, by absolute path (configuration, certificates).
    public var files: [String: ContainerFile]
    /// More container ports to publish on fixed host ports (e.g. a proxy's control API).
    public var extraPorts: [Int]
    /// The container's host name, which becomes SQL Server's `@@SERVERNAME` when a seeded image is
    /// built. Nil: Docker's (the container ID).
    public var hostname: String?

    public init(image: String, internalPort: Int, environment: [String: String], command: [String] = [], memoryMB: Int,
                files: [String: ContainerFile] = [:], extraPorts: [Int] = [], hostname: String? = nil) {
        self.image = image
        self.internalPort = internalPort
        self.environment = environment
        self.command = command
        self.memoryMB = memoryMB
        self.files = files
        self.extraPorts = extraPorts
        self.hostname = hostname
    }
}

/// Copies files between a running server's parts.
public protocol ServerPartFiles: Sendable {
    /// Copies `path` from the part with role `source` into the same directory of each target part,
    /// keeping owner and mode.
    func copy(_ path: String, from source: String, to targets: [String]) async throws
}

/// A file put into a container, with the owner and mode the server insists on (PostgreSQL refuses
/// a private key that others can read; SQL Server runs as uid 10001).
public struct ContainerFile: Sendable, Hashable {
    public var contents: Data
    public var mode: Int
    public var owner: Int
    /// An empty directory rather than a file (only for directories the image does not have).
    public var isDirectory = false

    public init(_ contents: Data, mode: Int = 0o644, owner: Int = 0) {
        self.contents = contents
        self.mode = mode
        self.owner = owner
    }

    /// An empty directory with its owner and mode, e.g. a tablespace location.
    public static func directory(mode: Int = 0o700, owner: Int = 0) -> ContainerFile {
        var file = ContainerFile(Data(), mode: mode, owner: owner)
        file.isDirectory = true
        return file
    }

    public init(_ text: String, mode: Int = 0o644, owner: Int = 0) {
        self.init(Data(text.utf8), mode: mode, owner: owner)
    }
}

/// Calls `body` until it succeeds or `timeout` passes.
public func retryUntilReady(
    _ what: String,
    timeout: Duration,
    every interval: Duration = .seconds(2),
    _ body: @Sendable () async throws -> Void
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    var lastError = "no attempt"
    while clock.now < deadline {
        do {
            try await body()
            return
        } catch {
            lastError = String(describing: error)
        }
        try await Task.sleep(for: interval)
    }
    throw ServerLabError.notReady(what, lastError: lastError)
}

/// The logger lab code hands to drivers: warnings and errors only, so build output stays readable.
public func driverLogger(_ label: String) -> Logger {
    var logger = Logger(label: label)
    logger.logLevel = .warning
    return logger
}
