import Foundation
import ServerLabCatalog
import ServerLabKit
/// `LabServer.startWorkload(_:)` comes with the trait.
@_exported import ServerLabWorkloads
import Testing

/// Starts a fresh server from a recipe for a suite (or a single test) and removes it afterwards.
///
/// ```swift
/// @Suite(.server("mssql-2022-agent-jobs"))
/// struct JobActivityTests {
///     @Test func listsJobs() async throws {
///         let server = try #require(LabServer.current)
///     }
/// }
/// ```
public struct LabServerTrait: SuiteTrait, TestTrait, TestScoping {
    public let recipeName: String
    public let lease: Duration
    /// Record the server's traffic; read it with `LabWire.current`.
    public let capture: Bool
    /// Put a fault proxy in front of the server: connect to `endpoint(of: "proxy")`, then
    /// `addFault(_:)`, `cutConnections()`, ….
    public let faults: Bool

    public var isRecursive: Bool { false }

    public func scopeProvider(for test: Test, testCase: Test.Case?) -> LabServerTrait? {
        if test.isSuite { return self }
        return testCase == nil ? nil : self
    }

    public func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        // A test inside a suite that already has a server keeps the suite's server.
        if LabServer.current != nil, !test.isSuite {
            try await function()
            return
        }
        let lab = try ServerLab.standard()
        // Drivers that support it log TLS secrets here, so recorded TLS traffic can be decrypted.
        if capture { LabWire.enableKeyLogging() }
        // SERVERLAB_SERVER=<container>: run against a server already up (e.g. while debugging one),
        // when its recipe matches; it is left running.
        if let name = ProcessInfo.processInfo.environment["SERVERLAB_SERVER"],
           let existing = try? await lab.server(named: name), existing.recipe == recipeName {
            let wire = capture ? LabWire(lab: lab, server: existing) : nil
            try await LabServer.$current.withValue(existing) {
                try await LabWire.$current.withValue(wire) { try await function() }
            }
            return
        }
        var server = try await lab.start(
            recipeNamed: recipeName,
            owner: labOwner(forSuite: test.name),
            lease: lease,
            log: { print("[serverlab] \($0)") }
        )
        do {
            if faults { server = try await lab.startFaultProxy(for: server) }
            if capture { try await lab.startCapture(of: server) }
            let started = server
            let wire = capture ? LabWire(lab: lab, server: started) : nil
            try await LabServer.$current.withValue(started) {
                try await LabWire.$current.withValue(wire) { try await function() }
            }
        } catch {
            try? await lab.stop(server)
            throw error
        }
        try await lab.stop(server)
    }
}

extension Trait where Self == LabServerTrait {
    /// A fresh server from the named recipe for this suite or test.
    public static func server(_ recipe: String, lease: Duration = .seconds(2 * 3600), capture: Bool = false, faults: Bool = false) -> Self {
        LabServerTrait(recipeName: recipe, lease: lease, capture: capture, faults: faults)
    }
}

extension LabServer {
    /// The server the enclosing `.server(...)` trait started.
    @TaskLocal public static var current: LabServer?

    /// Stops the server, or one part of it (`primary`, `standby`, …), without removing it.
    public func stop(part: String? = nil) async throws {
        try await ServerLab.standard().stop(part: part, of: self)
    }

    /// Starts a stopped server or part again on the same port; returns once it takes logins.
    public func start(part: String? = nil) async throws {
        try await ServerLab.standard().start(part: part, of: self)
    }

    /// Promotes a standby (or secondary) to primary through the driver.
    public func promote(part: String = "standby") async throws {
        try await ServerLab.standard().promote(part: part, of: self)
    }

    /// Adds a network fault to connections through the `proxy` part (`.server(..., faults: true)`).
    @discardableResult
    public func addFault(_ fault: LabFault, direction: LabFaultDirection = .downstream) async throws -> String {
        try await ServerLab.standard().addFault(fault, direction: direction, to: self)
    }

    /// Removes one fault, or all of them.
    public func clearFaults(_ name: String? = nil) async throws {
        try await ServerLab.standard().clearFaults(name, of: self)
    }

    /// Drops open connections through the proxy and refuses new ones until `restoreConnections()`.
    public func cutConnections() async throws {
        try await ServerLab.standard().cutConnections(of: self)
    }

    public func restoreConnections() async throws {
        try await ServerLab.standard().restoreConnections(of: self)
    }
}

/// The recorded traffic of the enclosing `.server(..., capture: true)` server, decoded by Wireshark.
public struct LabWire: Sendable {
    let lab: ServerLab
    public let server: LabServer

    @TaskLocal public static var current: LabWire?

    /// Points `SSLKEYLOGFILE` at a per-process file under ~/.echo-testlab/keylogs unless it is set.
    static func enableKeyLogging() {
        guard ServerLab.keyLogPath == nil else { return }
        let directory = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".echo-testlab/keylogs")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Logs of earlier runs older than a day go.
        let dayAgo = Date(timeIntervalSinceNow: -86_400)
        for file in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        where ((try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantFuture) < dayAgo {
            try? FileManager.default.removeItem(at: file)
        }
        setenv("SSLKEYLOGFILE", directory.appending(path: "tests-\(ProcessInfo.processInfo.processIdentifier).keys").path, 0)
    }

    /// Everything sent and received so far.
    public func messages() async throws -> [WireMessage] {
        // tcpdump writes each packet as it sees it; give the last ones a moment to land.
        try await Task.sleep(for: .milliseconds(300))
        return try await lab.wireMessages(of: server)
    }

    /// The traffic so far as whole protocol messages (TDS or PostgreSQL), explained by the lab's
    /// decoders. `specProblems` on the result lists anything they could not match to the protocol.
    public func explainedMessages() async throws -> [ExplainedMessage] {
        try await Task.sleep(for: .milliseconds(300))
        return try await lab.explainedWire(of: server)
    }

    /// True when `text` crossed the wire unencrypted (UTF-8 or UTF-16LE).
    public func containsPlaintext(_ text: String) async throws -> Bool {
        try await lab.captureContainsPlaintext(text, of: server)
    }
}

/// The owner label for a suite's servers: its name, after `SERVERLAB_OWNER_PREFIX/` when that is
/// set (CI sets it per run, so `serverlab down --all --owner-prefix <prefix>` removes exactly that
/// run's servers, including ones a crash left behind).
func labOwner(forSuite name: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
    // `<suite>@<machine>:<pid>`, so `serverlab down --abandoned` can remove what a killed process left.
    var buffer = [CChar](repeating: 0, count: 256)
    gethostname(&buffer, buffer.count - 1)
    let owner = "\(name)@\(String(cString: buffer)):\(getpid())"
    guard let prefix = environment["SERVERLAB_OWNER_PREFIX"], !prefix.isEmpty else { return owner }
    return "\(prefix)/\(owner)"
}
