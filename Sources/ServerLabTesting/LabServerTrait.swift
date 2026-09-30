import Foundation
import ServerLabCatalog
import ServerLabKit
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
        let server = try await lab.start(
            recipeNamed: recipeName,
            owner: test.name,
            lease: lease,
            log: { print("[serverlab] \($0)") }
        )
        do {
            if capture { try await lab.startCapture(of: server) }
            let wire = capture ? LabWire(lab: lab, server: server) : nil
            try await LabServer.$current.withValue(server) {
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
    public static func server(_ recipe: String, lease: Duration = .seconds(2 * 3600), capture: Bool = false) -> Self {
        LabServerTrait(recipeName: recipe, lease: lease, capture: capture)
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
}

/// The recorded traffic of the enclosing `.server(..., capture: true)` server, decoded by Wireshark.
public struct LabWire: Sendable {
    let lab: ServerLab
    public let server: LabServer

    @TaskLocal public static var current: LabWire?

    /// Everything sent and received so far.
    public func messages() async throws -> [WireMessage] {
        // tcpdump writes each packet as it sees it; give the last ones a moment to land.
        try await Task.sleep(for: .milliseconds(300))
        return try await lab.wireMessages(of: server)
    }

    /// True when `text` crossed the wire unencrypted (UTF-8 or UTF-16LE).
    public func containsPlaintext(_ text: String) async throws -> Bool {
        try await lab.captureContainsPlaintext(text, of: server)
    }
}
