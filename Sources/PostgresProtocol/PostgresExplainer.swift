import Foundation
import WireExplanation

/// Decodes PostgreSQL frontend/backend protocol 3.x messages field by field. One explainer per
/// connection: it remembers the authentication step (for `p` messages), the last RowDescription
/// and Bind's result formats (for DataRow values).
public struct PostgresExplainer: Sendable {
    struct Column: Sendable {
        var name: String
        var typeOID: UInt32
        var format: Int16
    }

    var columns: [Column] = []
    var bindFormats: [Int16]?
    /// The last authentication request (`R` subtype), which says what a `p` message holds.
    var authentication: UInt32?

    public init() {}

    static let frontendNames: [UInt8: String] = [
        0x51: "Query", 0x50: "Parse", 0x42: "Bind", 0x44: "Describe", 0x45: "Execute", 0x53: "Sync", 0x48: "Flush",
        0x43: "Close", 0x58: "Terminate", 0x70: "Password or SASL response", 0x64: "CopyData", 0x63: "CopyDone",
        0x66: "CopyFail", 0x46: "FunctionCall",
    ]
    static let backendNames: [UInt8: String] = [
        0x52: "Authentication", 0x53: "ParameterStatus", 0x4B: "BackendKeyData", 0x5A: "ReadyForQuery",
        0x54: "RowDescription", 0x44: "DataRow", 0x43: "CommandComplete", 0x45: "ErrorResponse", 0x4E: "NoticeResponse",
        0x31: "ParseComplete", 0x32: "BindComplete", 0x33: "CloseComplete", 0x6E: "NoData", 0x74: "ParameterDescription",
        0x49: "EmptyQueryResponse", 0x73: "PortalSuspended", 0x47: "CopyInResponse", 0x48: "CopyOutResponse",
        0x57: "CopyBothResponse", 0x64: "CopyData", 0x63: "CopyDone", 0x41: "NotificationResponse",
        0x56: "FunctionCallResponse", 0x76: "NegotiateProtocolVersion",
    ]

    /// A message without a type byte: StartupMessage, SSLRequest, GSSENCRequest or CancelRequest.
    public func explainUntyped(_ bytes: [UInt8], base: Int = 0) -> WireExplanation {
        var reader = WireByteReader(bytes, base: base)
        var fields: [WireField] = []
        var problems: [String] = []
        var name = "Startup"
        do {
            let length = Int(try reader.u32BE())
            fields.append(WireField("length", offset: base, length: 4, value: "\(length)"))
            let code = try reader.u32BE()
            switch code {
            case 80_877_103:
                name = "SSLRequest"
                fields.append(WireField("code", offset: base + 4, length: 4, value: "80877103 (SSLRequest)"))
            case 80_877_104:
                name = "GSSENCRequest"
                fields.append(WireField("code", offset: base + 4, length: 4, value: "80877104 (GSSENCRequest)"))
            case 80_877_102:
                name = "CancelRequest"
                fields.append(WireField("code", offset: base + 4, length: 4, value: "80877102 (CancelRequest)"))
                fields.append(WireField("process ID", offset: reader.offset, length: 4, value: "\(try reader.u32BE())"))
                let at = reader.offset
                fields.append(WireField("secret key", offset: at, length: reader.remaining, value: "\(reader.remaining) bytes (not shown)"))
                reader.position = reader.bytes.count
            default:
                name = "StartupMessage"
                fields.append(WireField("protocol", offset: base + 4, length: 4, value: "\(code >> 16).\(code & 0xFFFF)"))
                var parameters: [WireField] = []
                while let next = reader.peek(), next != 0 {
                    let at = reader.offset
                    let key = try cString(&reader), value = try cString(&reader)
                    parameters.append(WireField(key, offset: at, length: reader.offset - at, value: quoted(value)))
                }
                if !reader.isAtEnd { _ = try reader.u8() }
                fields.append(WireField("parameters", offset: parameters.first?.offset ?? reader.offset, length: 0, children: parameters))
            }
            if length != bytes.count { problems.append("Length says \(length), message has \(bytes.count) bytes") }
        } catch {
            problems.append("\(error)")
        }
        if !reader.isAtEnd { problems.append("\(reader.remaining) bytes left at +\(reader.offset)") }
        return WireExplanation(structure: name, byteCount: bytes.count, fields: fields, problems: problems)
    }

    /// A typed message (type byte, 4-byte length, body) from the client or the server.
    public mutating func explain(_ bytes: [UInt8], fromClient: Bool, base: Int = 0) -> WireExplanation {
        guard bytes.count >= 5 else {
            return WireExplanation(structure: "message", byteCount: bytes.count, fields: [], problems: ["A message needs at least 5 bytes"])
        }
        let type = bytes[0]
        let length = Int(UInt32(bytes[1]) << 24 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 8 | UInt32(bytes[4]))
        let names = fromClient ? Self.frontendNames : Self.backendNames
        guard let name = names[type] else {
            return WireExplanation(structure: String(format: "message '%@' (0x%02X)", String(UnicodeScalar(type)), type), byteCount: bytes.count,
                                   fields: [], problems: [String(format: "Message type '%@' (0x%02X) from the %@ is not in the protocol",
                                                                 String(UnicodeScalar(type)), type, fromClient ? "client" : "server")])
        }
        var fields = [WireField("type", offset: base, length: 1, value: "'\(String(UnicodeScalar(type)))' \(name)"),
                      WireField("length", offset: base + 1, length: 4, value: "\(length)")]
        var problems: [String] = []
        if length + 1 != bytes.count { problems.append("Length says \(length + 1) bytes with the type, message has \(bytes.count)") }
        var reader = WireByteReader(Array(bytes[5...]), base: base + 5)
        var structure = name
        do {
            if fromClient {
                fields += try frontend(type, &reader, structure: &structure)
            } else {
                fields += try backend(type, &reader, structure: &structure, problems: &problems)
            }
        } catch {
            problems.append("\(error)")
        }
        if !reader.isAtEnd { problems.append("\(reader.remaining) bytes left in \(structure) at +\(reader.offset)") }
        return WireExplanation(structure: structure, byteCount: bytes.count, fields: fields, problems: problems)
    }

    func cString(_ reader: inout WireByteReader) throws -> String {
        var bytes: [UInt8] = []
        while true {
            let byte = try reader.u8()
            if byte == 0 { break }
            bytes.append(byte)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private mutating func frontend(_ type: UInt8, _ reader: inout WireByteReader, structure: inout String) throws -> [WireField] {
        var fields: [WireField] = []
        func add(_ name: String, _ value: String, from at: Int) { fields.append(WireField(name, offset: at, length: reader.offset - at, value: value)) }
        switch type {
        case 0x51:
            let at = reader.offset
            add("SQL", quoted(try cString(&reader), limit: 400), from: at)
            bindFormats = nil
        case 0x50:
            var at = reader.offset
            add("statement", quoted(try cString(&reader)), from: at)
            at = reader.offset
            add("SQL", quoted(try cString(&reader), limit: 400), from: at)
            at = reader.offset
            let count = Int(try reader.u16BE())
            let types = try (0..<count).map { _ in PostgresTypes.name(try reader.u32BE()) }
            add("parameter types", count == 0 ? "none (server infers)" : types.joined(separator: ", "), from: at)
        case 0x42:
            var at = reader.offset
            add("portal", quoted(try cString(&reader)), from: at)
            at = reader.offset
            add("statement", quoted(try cString(&reader)), from: at)
            at = reader.offset
            let formatCount = Int(try reader.u16BE())
            let formats = try (0..<formatCount).map { _ in Int16(bitPattern: try reader.u16BE()) }
            add("parameter formats", formats.map { $0 == 1 ? "binary" : "text" }.joined(separator: ", "), from: at)
            at = reader.offset
            let count = Int(try reader.u16BE())
            var parameters: [WireField] = []
            for index in 0..<count {
                let parameterAt = reader.offset
                let length = Int32(bitPattern: try reader.u32BE())
                let format = formats.count == 1 ? formats[0] : (formats.indices.contains(index) ? formats[index] : 0)
                let value = length < 0 ? "NULL" : (format == 1 ? "binary " + (try reader.take(Int(length))).hex() : quoted(String(decoding: try reader.take(Int(length)), as: UTF8.self)))
                parameters.append(WireField("$\(index + 1)", offset: parameterAt, length: reader.offset - parameterAt, value: value))
            }
            fields.append(WireField("parameters", offset: at, length: reader.offset - at, value: "\(count)", children: parameters))
            at = reader.offset
            let resultCount = Int(try reader.u16BE())
            bindFormats = try (0..<resultCount).map { _ in Int16(bitPattern: try reader.u16BE()) }
            add("result formats", resultCount == 0 ? "all text" : (bindFormats ?? []).map { $0 == 1 ? "binary" : "text" }.joined(separator: ", "), from: at)
        case 0x44, 0x43:
            var at = reader.offset
            let kind = try reader.u8()
            add("what", kind == 0x53 ? "prepared statement" : "portal", from: at)
            at = reader.offset
            add("name", quoted(try cString(&reader)), from: at)
        case 0x45:
            var at = reader.offset
            add("portal", quoted(try cString(&reader)), from: at)
            at = reader.offset
            let rows = try reader.u32BE()
            add("max rows", rows == 0 ? "all" : "\(rows)", from: at)
        case 0x70:
            let at = reader.offset
            switch authentication {
            case 10:
                structure = "SASLInitialResponse"
                add("mechanism", try cString(&reader), from: at)
                let dataAt = reader.offset
                let length = Int32(bitPattern: try reader.u32BE())
                if length > 0 { _ = try reader.take(Int(length)) }
                add("client-first message", "\(max(length, 0)) bytes (not shown)", from: dataAt)
            case 11:
                structure = "SASLResponse"
                _ = try reader.take(reader.remaining)
                add("client-final message with proof", "not shown", from: at)
            case 7, 8:
                structure = "GSSResponse"
                let data = try reader.take(reader.remaining)
                add("GSSAPI token", "\(data.count) bytes", from: at)
            default:
                structure = "PasswordMessage"
                _ = try reader.take(reader.remaining)
                add("password", "never shown", from: at)
            }
        case 0x64:
            let at = reader.offset
            let data = try reader.take(reader.remaining)
            add("data", "\(data.count) bytes " + quoted(String(decoding: data.prefix(120), as: UTF8.self)), from: at)
        case 0x66:
            let at = reader.offset
            add("reason", quoted(try cString(&reader)), from: at)
        default:
            if !reader.isAtEnd {
                let at = reader.offset
                add("body", try reader.take(reader.remaining).hex(), from: at)
            }
        }
        return fields
    }
}
