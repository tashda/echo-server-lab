import Foundation

/// One decoded piece of a wire protocol: where it is, what it is, and what it holds.
public struct WireField: Sendable, Hashable, Codable {
    public var name: String
    /// Offset in the explained bytes.
    public var offset: Int
    public var length: Int
    /// The value as text (`1433`, `'master'`, `0x04 Tabular result`); empty for groups.
    public var value: String
    public var children: [WireField]

    public init(_ name: String, offset: Int, length: Int, value: String = "", children: [WireField] = []) {
        self.name = name
        self.offset = offset
        self.length = length
        self.value = value
        self.children = children
    }
}

/// A decoded structure with anything the decoder could not match to its protocol's spec.
public struct WireExplanation: Sendable, Hashable, Codable {
    public var structure: String
    public var byteCount: Int
    public var fields: [WireField]
    /// Bytes the spec does not explain: unknown messages or types, lengths past the end, leftovers.
    public var problems: [String]

    public init(structure: String, byteCount: Int, fields: [WireField], problems: [String]) {
        self.structure = structure
        self.byteCount = byteCount
        self.fields = fields
        self.problems = problems
    }

    /// The tree as indented text with offsets.
    public var text: String {
        var lines = ["\(structure) (\(byteCount) bytes)"]
        func add(_ field: WireField, depth: Int) {
            let indent = String(repeating: "  ", count: depth)
            let position = String(format: "[+%04d]", field.offset)
            let size = field.length > 0 ? " (\(field.length)B)" : ""
            lines.append("\(indent)\(position) \(field.name)\(size)\(field.value.isEmpty ? "" : ": \(field.value)")")
            for child in field.children { add(child, depth: depth + 1) }
        }
        for field in fields { add(field, depth: 1) }
        if !problems.isEmpty {
            lines.append("Problems:")
            lines += problems.map { "  - \($0)" }
        }
        return lines.joined(separator: "\n")
    }
}

/// Reads little- and big-endian values from a byte array, throwing past the end.
public struct WireByteReader {
    public let bytes: [UInt8]
    /// Where these bytes start in the explained input (for offsets).
    public let base: Int
    public var position = 0

    public init(_ bytes: [UInt8], base: Int = 0) {
        self.bytes = bytes
        self.base = base
    }

    public struct PastEnd: Error, CustomStringConvertible {
        public var needed: Int, offset: Int, available: Int
        public init(needed: Int, offset: Int, available: Int) {
            self.needed = needed
            self.offset = offset
            self.available = available
        }
        public var description: String { "needs \(needed) bytes at +\(offset), \(available) left" }
    }

    public var offset: Int { base + position }
    public var remaining: Int { bytes.count - position }
    public var isAtEnd: Bool { position >= bytes.count }

    public mutating func take(_ count: Int) throws -> [UInt8] {
        guard count >= 0, count <= remaining else { throw PastEnd(needed: count, offset: offset, available: remaining) }
        defer { position += count }
        return Array(bytes[position..<position + count])
    }

    public func peek() -> UInt8? { isAtEnd ? nil : bytes[position] }

    public mutating func u8() throws -> UInt8 { try take(1)[0] }
    public mutating func u16() throws -> UInt16 { let b = try take(2); return UInt16(b[0]) | UInt16(b[1]) << 8 }
    public mutating func u16BE() throws -> UInt16 { let b = try take(2); return UInt16(b[0]) << 8 | UInt16(b[1]) }
    public mutating func u32() throws -> UInt32 { try take(4).enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) } }
    public mutating func u32BE() throws -> UInt32 { try take(4).reduce(0) { $0 << 8 | UInt32($1) } }
    public mutating func u64() throws -> UInt64 { try take(8).enumerated().reduce(0) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) } }

    /// UCS-2 text of `characters` characters.
    public mutating func ucs2(_ characters: Int) throws -> String {
        WireByteReader.ucs2(try take(characters * 2))
    }

    /// B_VARCHAR: a 1-byte character count and UCS-2 text.
    public mutating func bVarChar() throws -> String { try ucs2(Int(try u8())) }
    /// US_VARCHAR: a 2-byte character count and UCS-2 text.
    public mutating func usVarChar() throws -> String { try ucs2(Int(try u16())) }

    public static func ucs2(_ bytes: [UInt8]) -> String {
        var units: [UInt16] = []
        units.reserveCapacity(bytes.count / 2)
        var index = 0
        while index + 1 < bytes.count {
            units.append(UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8)
            index += 2
        }
        return String(decoding: units, as: UTF16.self)
    }
}

extension Array where Element == UInt8 {
    /// `0A 0B …`, cut after `limit` bytes.
    public func hex(limit: Int = 32) -> String {
        let shown = prefix(limit).map { String(format: "%02X", $0) }.joined(separator: " ")
        return count > limit ? "\(shown) … (\(count) bytes)" : shown
    }
}

/// Quoted, shortened text for display.
public func quoted(_ text: String, limit: Int = 200) -> String {
    let shown = text.count > limit ? String(text.prefix(limit)) + "… (\(text.count) chars)" : text
    return "'" + shown.replacingOccurrences(of: "\n", with: "\\n") + "'"
}
