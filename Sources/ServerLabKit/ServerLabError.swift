import Foundation

public enum ServerLabError: Error, CustomStringConvertible, Sendable {
    case unknownRecipe(String)
    case unknownEngine(EngineKind)
    case unsupportedVersion(EngineKind, String, supported: [String])
    case unknownPack(String, engine: EngineKind)
    case invalidParameter(String, expected: String)
    case missingPassword
    case dockerNotFound
    case dockerFailed(command: String, status: Int32, output: String)
    case noPublishedPort(container: String)
    case notReady(String, lastError: String)
    case packCheckFailed(pack: String, reason: String)
    case packRequirement(pack: String, reason: String)
    case budgetTimeout(neededMB: Int, budgetMB: Int)
    case unknownPart(String, server: String, parts: [String])
    case unsupported(String)

    public var description: String {
        switch self {
        case .unknownRecipe(let name):
            "No recipe named '\(name)'."
        case .unknownEngine(let engine):
            "The lab has no engine for \(engine.rawValue)."
        case .unsupportedVersion(let engine, let version, let supported):
            "\(engine.rawValue) \(version) is not supported. Supported: \(supported.joined(separator: ", "))."
        case .unknownPack(let pack, let engine):
            "\(engine.rawValue) has no pack named '\(pack)'."
        case .invalidParameter(let key, let expected):
            "Pack parameter '\(key)' must be \(expected)."
        case .missingPassword:
            "No lab password: set SERVERLAB_PASSWORD or TESTLAB_PASSWORD in ~/.echo-testlab/credentials.env."
        case .dockerNotFound:
            "The docker command-line tool was not found (set SERVERLAB_DOCKER to its path)."
        case .dockerFailed(let command, let status, let output):
            "docker \(command) failed (\(status)): \(output)"
        case .noPublishedPort(let container):
            "Container \(container) has no published port."
        case .notReady(let what, let lastError):
            "\(what) did not become ready: \(lastError)"
        case .packCheckFailed(let pack, let reason):
            "Pack '\(pack)' check failed: \(reason)"
        case .packRequirement(let pack, let reason):
            "Pack '\(pack)' cannot run: \(reason)"
        case .budgetTimeout(let needed, let budget):
            "Waited too long for \(needed) MB within the host's \(budget) MB budget."
        case .unknownPart(let part, let server, let parts):
            "\(server) has no part '\(part)'. Parts: \(parts.joined(separator: ", "))."
        case .unsupported(let what):
            "\(what) is not supported."
        }
    }
}
