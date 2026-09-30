import Foundation

/// Runs the `docker` command-line tool against one host. The tool handles `ssh://` hosts itself.
public struct DockerCommand: Sendable {
    public let host: LabHost
    let executable: URL

    public init(host: LabHost, environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        self.host = host
        let candidates = [environment["SERVERLAB_DOCKER"], "/usr/local/bin/docker", "/opt/homebrew/bin/docker", "/usr/bin/docker"]
        guard let path = candidates.compactMap({ $0 }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw ServerLabError.dockerNotFound
        }
        executable = URL(fileURLWithPath: path)
    }

    /// Runs `docker <arguments>` and returns standard output, trimmed. Throws on a non-zero exit.
    @discardableResult
    public func run(_ arguments: [String]) async throws -> String {
        let result = try await runAllowingFailure(arguments)
        guard result.status == 0 else {
            throw ServerLabError.dockerFailed(
                command: arguments.prefix(2).joined(separator: " "),
                status: result.status,
                output: (result.standardError.isEmpty ? result.standardOutput : result.standardError)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public struct Result: Sendable {
        public var status: Int32
        public var standardOutput: String
        public var standardError: String
    }

    public func runAllowingFailure(_ arguments: [String]) async throws -> Result {
        let process = Process()
        process.executableURL = executable
        process.arguments = (host.dockerHost.map { ["--host", $0] } ?? []) + arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice

        let status = AsyncStream<Int32> { continuation in
            process.terminationHandler = { finished in
                continuation.yield(finished.terminationStatus)
                continuation.finish()
            }
        }
        try process.run()
        async let standardOutput = Self.collect(output.fileHandleForReading)
        async let standardError = Self.collect(errors.fileHandleForReading)
        var exitStatus: Int32 = -1
        for await value in status { exitStatus = value }
        return Result(status: exitStatus, standardOutput: try await standardOutput, standardError: try await standardError)
    }

    private static func collect(_ handle: FileHandle) async throws -> String {
        var bytes: [UInt8] = []
        for try await byte in handle.bytes { bytes.append(byte) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
