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

    /// Runs `docker <arguments>` and returns standard output as raw bytes (for binary files).
    public func runData(_ arguments: [String]) async throws -> Data {
        await DockerGate.shared.enter()
        defer { Task { await DockerGate.shared.leave() } }
        let process = Process()
        process.executableURL = executable
        process.arguments = (host.dockerHost.map { ["--host", $0] } ?? []) + arguments
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        let status = AsyncStream<Int32> { continuation in
            process.terminationHandler = { continuation.yield($0.terminationStatus); continuation.finish() }
        }
        try process.run()
        let watchdog = Self.terminate(process, after: Self.defaultTimeout)
        defer { watchdog.cancel() }
        async let data = Self.readData(output.fileHandleForReading)
        async let errorText = Self.collect(errors.fileHandleForReading)
        var exitStatus: Int32 = -1
        for await value in status { exitStatus = value }
        let (bytes, message) = (try await data, try await errorText)
        guard exitStatus == 0 else {
            throw ServerLabError.dockerFailed(command: arguments.prefix(2).joined(separator: " "), status: exitStatus, output: message)
        }
        return bytes
    }

    /// Stops `process` if it is still running after `timeout`.
    private static func terminate(_ process: Process, after timeout: Duration) -> Task<Void, Never> {
        let processID = process.processIdentifier
        return Task(name: "docker-timeout-\(processID)") {
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            kill(processID, SIGTERM)
            // A docker CLI stuck on a dropped SSH session ignores SIGTERM.
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            kill(processID, SIGKILL)
        }
    }

    @concurrent
    private static func readData(_ handle: FileHandle) async throws -> Data {
        try handle.readToEnd() ?? Data()
    }

    public struct Result: Sendable {
        public var status: Int32
        public var standardOutput: String
        public var standardError: String
    }

    /// How long one command may run before it is stopped. A docker CLI whose SSH session the lab
    /// host dropped hangs instead of failing; ten minutes covers every ordinary command (commits
    /// of large images included), so such a hang costs a run minutes, not half an hour.
    public static let defaultTimeout: Duration = .seconds(10 * 60)
    /// Pulls and image builds download gigabytes.
    public static let longTimeout: Duration = .seconds(45 * 60)

    /// The timeout for `arguments`: long for `pull` and `build`, the default otherwise.
    static func timeout(for arguments: [String]) -> Duration {
        ["pull", "build"].contains(arguments.first ?? "") ? longTimeout : defaultTimeout
    }

    /// `input` is a file sent to the command's standard input. A command that could not reach the
    /// Docker host (an SSH connection dropped while many commands start at once) is tried again.
    public func runAllowingFailure(_ arguments: [String], input: URL? = nil, timeout: Duration? = nil) async throws -> Result {
        let timeout = timeout ?? Self.timeout(for: arguments)
        var attempt = 0
        while true {
            let result = try await runOnce(arguments, input: input, timeout: timeout)
            attempt += 1
            guard result.status != 0, Self.couldNotConnect(result.standardError), attempt < 5 else { return result }
            try await Task.sleep(for: .milliseconds(500 * attempt))
        }
    }

    /// True when the CLI never reached the daemon, so running the command again is safe.
    static func couldNotConnect(_ message: String) -> Bool {
        message.contains("error during connect") || message.contains("Cannot connect to the Docker daemon")
            || message.contains("connection reset by peer") && message.contains("dial-stdio")
    }

    private func runOnce(_ arguments: [String], input: URL?, timeout: Duration) async throws -> Result {
        await DockerGate.shared.enter()
        defer { Task { await DockerGate.shared.leave() } }
        let process = Process()
        process.executableURL = executable
        process.arguments = (host.dockerHost.map { ["--host", $0] } ?? []) + arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = try input.map { try FileHandle(forReadingFrom: $0) } ?? FileHandle.nullDevice

        let status = AsyncStream<Int32> { continuation in
            process.terminationHandler = { finished in
                continuation.yield(finished.terminationStatus)
                continuation.finish()
            }
        }
        try process.run()
        let watchdog = Self.terminate(process, after: timeout)
        defer { watchdog.cancel() }
        async let standardOutput = Self.collect(output.fileHandleForReading)
        async let standardError = Self.collect(errors.fileHandleForReading)
        var exitStatus: Int32 = -1
        for await value in status { exitStatus = value }
        var message = try await standardError
        if process.terminationReason == .uncaughtSignal {
            message += "\n(ended by a signal; the lab stops Docker commands after \(timeout))"
        }
        return Result(status: exitStatus, standardOutput: try await standardOutput, standardError: message)
    }

    /// Reads a pipe to its end on a thread-pool thread (a byte-by-byte async read is slow for
    /// large outputs such as sample scripts).
    @concurrent
    private static func collect(_ handle: FileHandle) async throws -> String {
        String(decoding: try handle.readToEnd() ?? Data(), as: UTF8.self)
    }
}

/// Limits how many docker commands one process runs at once. Each one opens its own SSH session
/// to the lab host, and sshd drops sessions when dozens start together (suites start in
/// parallel); a dropped session can leave the docker CLI hanging. `SERVERLAB_DOCKER_CONCURRENCY`
/// overrides the default of 8.
actor DockerGate {
    static let shared = DockerGate(limit: Int(ProcessInfo.processInfo.environment["SERVERLAB_DOCKER_CONCURRENCY"] ?? "") ?? 8)

    private let limit: Int
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = max(1, limit) }

    func enter() async {
        if running < limit {
            running += 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    func leave() {
        if waiting.isEmpty {
            running -= 1
        } else {
            waiting.removeFirst().resume()
        }
    }
}
