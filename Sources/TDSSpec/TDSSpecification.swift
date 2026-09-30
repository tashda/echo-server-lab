import Foundation

/// The TDS protocol reference (MS-TDS): tokens, data types, messages, flows, version support,
/// binary examples and how sqlserver-nio maps each type. Loaded from the bundled spec files.
public struct TDSSpecification: Sendable {
    public let tokens: JSONValue
    public let dataTypes: JSONValue
    public let messages: JSONValue
    public let flows: JSONValue
    public let examples: JSONValue
    public let versionCompat: JSONValue
    public let swiftMappings: JSONValue

    public static let shared: TDSSpecification = {
        do { return try TDSSpecification(bundle: .module) } catch { fatalError("TDS spec files: \(error)") }
    }()

    public init(bundle: Bundle) throws {
        func load(_ name: String) throws -> JSONValue {
            guard let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "spec")
                ?? bundle.url(forResource: name, withExtension: "json") else {
                throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "\(name).json"])
            }
            return try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
        }
        tokens = try load("tokens")
        dataTypes = try load("data-types")
        messages = try load("messages")
        flows = try load("protocol-flows")
        examples = try load("examples")
        versionCompat = try load("version-compat")
        swiftMappings = try load("swift-mappings")
    }

    public var tokenList: [JSONValue] { tokens["tokens"]?.array ?? [] }
    public var typeList: [JSONValue] { dataTypes["types"]?.array ?? [] }

    /// A token by its byte (`0xFD`).
    public func token(code: UInt8) -> JSONValue? {
        tokenList.first { Self.code($0["value"]?.string) == code }
    }

    /// A data type by its byte (`0xE7`).
    public func dataType(code: UInt8) -> JSONValue? {
        typeList.first { Self.code($0["value"]?.string) == code }
    }

    public func tokenName(_ code: UInt8) -> String? { token(code: code)?["name"]?.string }
    public func typeName(_ code: UInt8) -> String? { dataType(code: code)?["name"]?.string }

    static func code(_ text: String?) -> UInt8? {
        guard let text, text.lowercased().hasPrefix("0x") else { return nil }
        return UInt8(text.dropFirst(2), radix: 16)
    }
}
