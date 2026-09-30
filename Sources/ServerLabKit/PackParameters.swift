import Foundation

/// A pack's parameters as written in a recipe: `{ "jobCount": 20, "database": "LabData" }`.
public struct PackParameters: Codable, Sendable, Hashable {
    public var values: [String: PackParameterValue]

    public init(_ values: [String: PackParameterValue] = [:]) {
        self.values = values
    }

    public init(from decoder: any Decoder) throws {
        values = try decoder.singleValueContainer().decode([String: PackParameterValue].self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values)
    }

    public func int(_ key: String, default fallback: Int) throws -> Int {
        guard let value = values[key] else { return fallback }
        guard case .int(let int) = value else { throw ServerLabError.invalidParameter(key, expected: "a whole number") }
        return int
    }

    public func string(_ key: String, default fallback: String) throws -> String {
        try optionalString(key) ?? fallback
    }

    public func optionalString(_ key: String) throws -> String? {
        guard let value = values[key] else { return nil }
        guard case .string(let string) = value else { throw ServerLabError.invalidParameter(key, expected: "text") }
        return string
    }

    public func bool(_ key: String, default fallback: Bool) throws -> Bool {
        guard let value = values[key] else { return fallback }
        guard case .bool(let bool) = value else { throw ServerLabError.invalidParameter(key, expected: "true or false") }
        return bool
    }
}

public enum PackParameterValue: Codable, Sendable, Hashable {
    case int(Int)
    case bool(Bool)
    case string(String)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let int = try? container.decode(Int.self) {
            self = .int(int)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .int(let int): try container.encode(int)
        case .bool(let bool): try container.encode(bool)
        case .string(let string): try container.encode(string)
        }
    }
}

extension PackParameterValue: ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral, ExpressibleByStringLiteral {
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(stringLiteral value: String) { self = .string(value) }
}
