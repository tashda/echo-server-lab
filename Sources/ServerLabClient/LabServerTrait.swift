import Foundation
import Testing

/// `@Suite(.server("recipe"))`: a fresh lab server for the suite (or test), removed afterwards.
/// Same API as ServerLabTesting, through the `serverlab` tool instead of linking the lab.
public struct LabServerTrait: SuiteTrait, TestTrait, TestScoping {
    public let recipeName: String
    public let leaseMinutes: Int

    public var isRecursive: Bool { false }

    public func scopeProvider(for test: Test, testCase: Test.Case?) -> LabServerTrait? {
        if test.isSuite { return self }
        return testCase == nil ? nil : self
    }

    public func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        if LabServer.current != nil, !test.isSuite {
            try await function()
            return
        }
        let server = try await ServerLabCLI.up(recipeName, owner: test.name, leaseMinutes: leaseMinutes)
        do {
            try await LabServer.$current.withValue(server) { try await function() }
        } catch {
            try? await ServerLabCLI.down(server)
            throw error
        }
        try await ServerLabCLI.down(server)
    }
}

extension Trait where Self == LabServerTrait {
    public static func server(_ recipe: String, leaseMinutes: Int = 120) -> Self {
        LabServerTrait(recipeName: recipe, leaseMinutes: leaseMinutes)
    }
}

extension LabServer {
    /// The server the enclosing `.server(...)` trait started.
    @TaskLocal public static var current: LabServer?
}
