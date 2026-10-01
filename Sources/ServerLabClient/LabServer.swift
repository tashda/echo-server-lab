import Foundation

/// A server started by the `serverlab` command-line tool: where it answers and how to log in.
/// The same JSON `serverlab up --json` prints.
public struct LabServer: Codable, Sendable, Hashable {
    public var recipe: String
    public var engine: String
    public var version: String
    public var host: String
    public var port: Int
    public var username: String
    public var password: String
    public var containerID: String
    public var containerName: String
    public var expires: Date
    /// Every container of the server, the main one first.
    public var parts: [LabServerPart]
    /// Set when the recipe asked for TLS: the mode, the certificate kind and the files a client needs.
    public var tls: LabServerTLS?

    public var isSQLServer: Bool { engine == "sqlserver" }
    public var isPostgres: Bool { engine == "postgresql" }
    public var isMySQL: Bool { engine == "mysql" }
    public var isMariaDB: Bool { engine == "mariadb" }

    /// The host port of a part, e.g. `port(of: "standby")`.
    public func port(of role: String) -> Int? { parts.first { $0.role == role }?.port }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        recipe = try container.decode(String.self, forKey: .recipe)
        engine = try container.decode(String.self, forKey: .engine)
        version = try container.decode(String.self, forKey: .version)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decode(Int.self, forKey: .port)
        username = try container.decode(String.self, forKey: .username)
        password = try container.decode(String.self, forKey: .password)
        containerID = try container.decode(String.self, forKey: .containerID)
        containerName = try container.decode(String.self, forKey: .containerName)
        expires = try container.decode(Date.self, forKey: .expires)
        parts = try container.decodeIfPresent([LabServerPart].self, forKey: .parts)
            ?? [LabServerPart(role: "server", containerID: containerID, containerName: containerName, port: port)]
        tls = try container.decodeIfPresent(LabServerTLS.self, forKey: .tls)
    }
}

/// One container of a lab server. Its port stays the same when it is stopped and started.
public struct LabServerPart: Codable, Sendable, Hashable {
    public var role: String
    public var containerID: String
    public var containerName: String
    public var port: Int
    /// The fault proxy's control API port (part `proxy` only).
    public var controlPort: Int?
}

/// How a TLS lab server must be reached.
public struct LabServerTLS: Codable, Sendable, Hashable {
    /// `optional`, `required`, `strict` (TDS 8 / TLS 1.3 only) or `client-certificate`.
    public var mode: String
    /// `valid`, `expired`, `wrong-host` or `self-signed`.
    public var certificate: String
    /// The lab CA (PEM): pass it as the driver's CA file to verify the server.
    public var caPath: String
    public var clientCertificatePath: String?
    public var clientKeyPath: String?
}

/// Starts and stops lab servers through the `serverlab` tool, so a test target needs no database
/// driver of its own (Echo links the drivers into the app already).
public enum ServerLabCLI {
    /// `SERVERLAB_CLI`, else the release build next to the lab's sources (built once if missing).
    public static func executable(environment: [String: String] = ProcessInfo.processInfo.environment) async throws -> URL {
        if let path = environment["SERVERLAB_CLI"], FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        let package = URL(fileURLWithPath: environment["SERVERLAB_PACKAGE"]
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Development/echo-server-lab").path)
        let binary = package.appending(path: ".build/release/serverlab")
        if FileManager.default.isExecutableFile(atPath: binary.path) { return binary }
        guard FileManager.default.fileExists(atPath: package.appending(path: "Package.swift").path) else {
            throw ServerLabClientError("serverlab not found: set SERVERLAB_CLI, or SERVERLAB_PACKAGE to the echo-server-lab checkout")
        }
        _ = try await run(URL(fileURLWithPath: "/usr/bin/env"),
                          ["swift", "build", "-c", "release", "--product", "serverlab", "--package-path", package.path])
        return binary
    }

    /// Starts a fresh server from `recipe`. It is removed by `down(_:)` or when `leaseMinutes` pass.
    public static func up(_ recipe: String, owner: String, leaseMinutes: Int = 120, capture: Bool = false, faults: Bool = false) async throws -> LabServer {
        let output = try await run(executable(), ["up", recipe, "--json", "--owner", owner, "--lease", String(leaseMinutes)]
            + (capture ? ["--capture"] : []) + (faults ? ["--faults"] : []))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(LabServer.self, from: Data(output.utf8))
    }

    public static func down(_ server: LabServer) async throws {
        _ = try await run(executable(), ["down", server.containerName])
    }

    /// Stops a server, or one part of it (`primary`, `standby`, …), without removing it.
    public static func stop(_ server: LabServer, part: String? = nil) async throws {
        _ = try await run(executable(), ["stop", server.containerName] + (part.map { ["--part", $0] } ?? []))
    }

    /// Starts a stopped server or part again on the same port; returns once it takes logins.
    public static func start(_ server: LabServer, part: String? = nil) async throws {
        _ = try await run(executable(), ["start", server.containerName] + (part.map { ["--part", $0] } ?? []))
    }

    /// Promotes a standby (or secondary) to primary.
    public static func promote(_ server: LabServer, part: String = "standby") async throws {
        _ = try await run(executable(), ["promote", server.containerName, "--part", part])
    }

    /// Adds a network fault on the server's `proxy` part (`up(..., faults: true)`): `kind` is latency,
    /// bandwidth, timeout, reset, slow-close, limit or slicer, `value` its number. Returns the fault's name.
    @discardableResult
    public static func fault(_ server: LabServer, _ kind: String, _ value: Int, upstream: Bool = false) async throws -> String {
        try await run(executable(), ["fault", server.containerName, kind, String(value)] + (upstream ? ["--upstream"] : []))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `clear` (all faults, or `name`), `cut` (drop connections) or `restore`.
    public static func fault(_ server: LabServer, _ action: String, name: String? = nil) async throws {
        _ = try await run(executable(), ["fault", server.containerName, action] + (name.map { [$0] } ?? []))
    }

    /// The server's recorded traffic, decoded by Wireshark (needs `capture: true` at `up`).
    public static func wire(_ server: LabServer) async throws -> [WireMessage] {
        let output = try await run(executable(), ["wire", server.containerName, "--json"])
        return try JSONDecoder().decode([WireMessage].self, from: Data(output.utf8))
    }

    /// The server's recorded traffic as pcap bytes.
    public static func pcap(_ server: LabServer) async throws -> Data {
        let file = FileManager.default.temporaryDirectory.appending(path: "\(server.containerName)-\(UUID().uuidString.prefix(6)).pcap")
        defer { try? FileManager.default.removeItem(at: file) }
        _ = try await run(executable(), ["pcap", server.containerName, "--output", file.path])
        return try Data(contentsOf: file)
    }

    static func run(_ executable: URL, _ arguments: [String]) async throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        let status = AsyncStream<Int32> { continuation in
            process.terminationHandler = { continuation.yield($0.terminationStatus); continuation.finish() }
        }
        try process.run()
        async let standardOutput = readAll(output.fileHandleForReading)
        async let standardError = readAll(errors.fileHandleForReading)
        var exitStatus: Int32 = -1
        for await value in status { exitStatus = value }
        let (out, err) = (try await standardOutput, try await standardError)
        guard exitStatus == 0 else {
            throw ServerLabClientError("serverlab \(arguments.first ?? "") failed (\(exitStatus)): \(err.split(separator: "\n").suffix(5).joined(separator: "\n"))")
        }
        return out
    }

    @concurrent
    private static func readAll(_ handle: FileHandle) async throws -> String {
        String(decoding: try handle.readToEnd() ?? Data(), as: UTF8.self)
    }
}

public struct ServerLabClientError: Error, CustomStringConvertible, Sendable {
    public let description: String
    init(_ description: String) { self.description = description }
}
