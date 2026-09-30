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

    public var isSQLServer: Bool { engine == "sqlserver" }
    public var isPostgres: Bool { engine == "postgresql" }
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
    public static func up(_ recipe: String, owner: String, leaseMinutes: Int = 120, capture: Bool = false) async throws -> LabServer {
        let output = try await run(executable(), ["up", recipe, "--json", "--owner", owner, "--lease", String(leaseMinutes)] + (capture ? ["--capture"] : []))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(LabServer.self, from: Data(output.utf8))
    }

    public static func down(_ server: LabServer) async throws {
        _ = try await run(executable(), ["down", server.containerName])
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
