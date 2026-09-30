import Foundation

/// One decoded piece of TDS: where it is, what it is, and what it holds.
public struct TDSField: Sendable, Hashable, Codable {
    public var name: String
    /// Offset in the explained bytes.
    public var offset: Int
    public var length: Int
    /// The value as text (`1433`, `'master'`, `0x04 Tabular result`); empty for groups.
    public var value: String
    public var children: [TDSField]

    public init(_ name: String, offset: Int, length: Int, value: String = "", children: [TDSField] = []) {
        self.name = name
        self.offset = offset
        self.length = length
        self.value = value
        self.children = children
    }
}

/// A decoded structure with anything the decoder could not match to the spec.
public struct TDSExplanation: Sendable, Hashable, Codable {
    public var structure: String
    public var byteCount: Int
    public var fields: [TDSField]
    /// Bytes the spec does not explain: unknown tokens or types, lengths past the end, leftovers.
    public var problems: [String]

    public init(structure: String, byteCount: Int, fields: [TDSField], problems: [String]) {
        self.structure = structure
        self.byteCount = byteCount
        self.fields = fields
        self.problems = problems
    }

    /// The tree as indented text with offsets.
    public var text: String {
        var lines = ["\(structure) (\(byteCount) bytes)"]
        func add(_ field: TDSField, depth: Int) {
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
struct TDSByteReader {
    let bytes: [UInt8]
    /// Where these bytes start in the explained input (for offsets).
    let base: Int
    var position = 0

    init(_ bytes: [UInt8], base: Int = 0) {
        self.bytes = bytes
        self.base = base
    }

    struct PastEnd: Error, CustomStringConvertible {
        var needed: Int, offset: Int, available: Int
        var description: String { "needs \(needed) bytes at +\(offset), \(available) left" }
    }

    var offset: Int { base + position }
    var remaining: Int { bytes.count - position }
    var isAtEnd: Bool { position >= bytes.count }

    mutating func take(_ count: Int) throws -> [UInt8] {
        guard count >= 0, count <= remaining else { throw PastEnd(needed: count, offset: offset, available: remaining) }
        defer { position += count }
        return Array(bytes[position..<position + count])
    }

    func peek() -> UInt8? { isAtEnd ? nil : bytes[position] }

    mutating func u8() throws -> UInt8 { try take(1)[0] }
    mutating func u16() throws -> UInt16 { let b = try take(2); return UInt16(b[0]) | UInt16(b[1]) << 8 }
    mutating func u16BE() throws -> UInt16 { let b = try take(2); return UInt16(b[0]) << 8 | UInt16(b[1]) }
    mutating func u32() throws -> UInt32 { try take(4).enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) } }
    mutating func u32BE() throws -> UInt32 { try take(4).reduce(0) { $0 << 8 | UInt32($1) } }
    mutating func u64() throws -> UInt64 { try take(8).enumerated().reduce(0) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) } }

    /// UCS-2 text of `characters` characters.
    mutating func ucs2(_ characters: Int) throws -> String {
        TDSByteReader.ucs2(try take(characters * 2))
    }

    /// B_VARCHAR: a 1-byte character count and UCS-2 text.
    mutating func bVarChar() throws -> String { try ucs2(Int(try u8())) }
    /// US_VARCHAR: a 2-byte character count and UCS-2 text.
    mutating func usVarChar() throws -> String { try ucs2(Int(try u16())) }

    static func ucs2(_ bytes: [UInt8]) -> String {
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
    func hex(limit: Int = 32) -> String {
        let shown = prefix(limit).map { String(format: "%02X", $0) }.joined(separator: " ")
        return count > limit ? "\(shown) … (\(count) bytes)" : shown
    }
}

/// Quoted, shortened text for display.
func quoted(_ text: String, limit: Int = 200) -> String {
    let shown = text.count > limit ? String(text.prefix(limit)) + "… (\(text.count) chars)" : text
    return "'" + shown.replacingOccurrences(of: "\n", with: "\\n") + "'"
}
