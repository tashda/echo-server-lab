import Foundation
import Logging

/// Where a running server answers and how to log in.
public struct ServerEndpoint: Sendable, Hashable {
    public var host: String
    public var port: Int
    public var username: String
    public var password: String

    public init(host: String, port: Int, username: String, password: String) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
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

    func apply(to server: ServerEndpoint, recipe: Recipe, parameters: PackParameters, log: LabLog) async throws
    /// Throws `ServerLabError.packCheckFailed` when the server does not hold what the pack promised.
    func verify(on server: ServerEndpoint, recipe: Recipe, parameters: PackParameters) async throws
}

public struct ContainerSpec: Sendable, Hashable {
    public var image: String
    public var internalPort: Int
    public var environment: [String: String]
    public var command: [String]
    public var memoryMB: Int

    public init(image: String, internalPort: Int, environment: [String: String], command: [String] = [], memoryMB: Int) {
        self.image = image
        self.internalPort = internalPort
        self.environment = environment
        self.command = command
        self.memoryMB = memoryMB
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
