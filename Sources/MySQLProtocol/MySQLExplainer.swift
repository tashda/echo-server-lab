import Foundation
import WireExplanation

/// Decodes the MySQL client/server protocol (MySQL and MariaDB) packet by packet. One explainer
/// per connection: it follows the handshake (capabilities), which command is being answered, and a
/// result set's columns, so rows decode by type in text and binary form.
public struct MySQLExplainer: Sendable {
    enum Expecting: Sendable, Equatable {
        case greeting, handshakeResponse, authentication, command
        /// A command's first answer: OK, ERR, local infile, or a result set's column count.
        case response(binary: Bool)
        case columns(remaining: Int, binary: Bool)
        case columnsEOF(binary: Bool)
        case rows(binary: Bool)
        case prepareOK
        case prepareDefinitions(remaining: Int, thenColumns: Int)
    }

    struct Column: Sendable {
        var name: String
        var type: UInt8
        var flags: UInt16
        var decimals: UInt8
    }

    var expecting: Expecting = .greeting
    var deprecateEOF = false
    /// MariaDB's extended capability MARIADB_CLIENT_CACHE_METADATA: a column count is followed by a
    /// "metadata follows" byte, and prepared statements may skip their column definitions.
    var cacheMetadata = false
    var columns: [Column] = []
    /// Parameter counts of prepared statements, by statement ID (for COM_STMT_EXECUTE).
    var statementParameters: [UInt32: Int] = [:]

    public init() {}

    static let commands: [UInt8: String] = [
        0x01: "COM_QUIT", 0x02: "COM_INIT_DB", 0x03: "COM_QUERY", 0x04: "COM_FIELD_LIST", 0x09: "COM_STATISTICS",
        0x0E: "COM_PING", 0x11: "COM_CHANGE_USER", 0x16: "COM_STMT_PREPARE", 0x17: "COM_STMT_EXECUTE",
        0x18: "COM_STMT_SEND_LONG_DATA", 0x19: "COM_STMT_CLOSE", 0x1A: "COM_STMT_RESET", 0x1B: "COM_SET_OPTION",
        0x1C: "COM_STMT_FETCH", 0x1F: "COM_RESET_CONNECTION", 0x12: "COM_BINLOG_DUMP", 0x1E: "COM_BINLOG_DUMP_GTID",
    ]

    /// One packet: 3-byte length, sequence number, payload.
    public mutating func explain(_ packet: [UInt8], fromClient: Bool) -> WireExplanation {
        guard packet.count >= 4 else {
            return WireExplanation(structure: "packet", byteCount: packet.count, fields: [], problems: ["A packet needs a 4-byte header"])
        }
        let length = Int(packet[0]) | Int(packet[1]) << 8 | Int(packet[2]) << 16
        var fields = [WireField("header", offset: 0, length: 4, value: "length \(length), sequence \(packet[3])")]
        var problems: [String] = []
        if length + 4 != packet.count { problems.append("Length says \(length + 4) bytes, packet has \(packet.count)") }
        var reader = WireByteReader(Array(packet[4...]), base: 4)
        var structure = "packet"
        do {
            fields += fromClient ? try client(&reader, structure: &structure, sequence: packet[3])
                                 : try server(&reader, structure: &structure, problems: &problems)
        } catch {
            problems.append("\(error)")
        }
        if !reader.isAtEnd { problems.append("\(reader.remaining) bytes left in \(structure) at +\(reader.offset)") }
        return WireExplanation(structure: structure, byteCount: packet.count, fields: fields, problems: problems)
    }

    // MARK: - Client

    private mutating func client(_ reader: inout WireByteReader, structure: inout String, sequence: UInt8) throws -> [WireField] {
        var fields: [WireField] = []
        func add(_ name: String, _ value: String, from at: Int) { fields.append(WireField(name, offset: at, length: reader.offset - at, value: value)) }
        switch expecting {
        case .handshakeResponse:
            var at = reader.offset
            let capabilities = try reader.u32()
            deprecateEOF = capabilities & 0x0100_0000 != 0
            add("capabilities", String(format: "0x%08X", capabilities) + Self.capabilityNames(capabilities), from: at)
            at = reader.offset
            add("max packet size", "\(try reader.u32())", from: at)
            at = reader.offset
            add("character set", "\(try reader.u8())", from: at)
            at = reader.offset
            let filler = try reader.take(23)
            // MariaDB keeps extended capabilities in the last 4 filler bytes (when CLIENT_MYSQL, bit 0, is off).
            let extended = UInt32(filler[19]) | UInt32(filler[20]) << 8 | UInt32(filler[21]) << 16 | UInt32(filler[22]) << 24
            if capabilities & 1 == 0, extended != 0 {
                cacheMetadata = extended & 0x10 != 0
                add("MariaDB extended capabilities", String(format: "0x%08X", extended) + (cacheMetadata ? " (CACHE_METADATA)" : ""), from: at)
            }
            if reader.isAtEnd {
                structure = "SSLRequest"
                return fields
            }
            structure = "HandshakeResponse41"
            at = reader.offset
            add("user", quoted(try cString(&reader)), from: at)
            at = reader.offset
            let authLength = capabilities & 0x0020_0000 != 0 ? Int(try lengthEncoded(&reader) ?? 0) : Int(try reader.u8())
            _ = try reader.take(authLength)
            add("auth response", "\(authLength) bytes (not shown)", from: at)
            if capabilities & 0x0000_0008 != 0, !reader.isAtEnd {
                at = reader.offset
                add("database", quoted(try cString(&reader)), from: at)
            }
            if capabilities & 0x0008_0000 != 0, !reader.isAtEnd {
                at = reader.offset
                add("auth plugin", try cString(&reader), from: at)
            }
            if capabilities & 0x0010_0000 != 0, !reader.isAtEnd {
                at = reader.offset
                let total = Int(try lengthEncoded(&reader) ?? 0)
                var attributes: [String] = []
                let end = reader.position + total
                while reader.position < end {
                    attributes.append("\(try lengthEncodedString(&reader))=\(try lengthEncodedString(&reader))")
                }
                add("connection attributes", attributes.joined(separator: ", "), from: at)
            }
            if !reader.isAtEnd, capabilities & 0x0400_0000 != 0 {
                at = reader.offset
                add("zstd level", "\(try reader.u8())", from: at)
            }
            expecting = .authentication
        case .authentication:
            structure = "auth data"
            let at = reader.offset
            let data = try reader.take(reader.remaining)
            add("data", "\(data.count) bytes (not shown)", from: at)
        default:
            let at = reader.offset
            let command = try reader.u8()
            structure = Self.commands[command] ?? String(format: "command 0x%02X", command)
            add("command", String(format: "0x%02X %@", command, structure), from: at)
            switch command {
            case 0x03, 0x16:
                // MariaDB and MySQL 8.0.26+ may send query attributes first (CLIENT_QUERY_ATTRIBUTES); not decoded.
                let textAt = reader.offset
                add("SQL", quoted(String(decoding: try reader.take(reader.remaining), as: UTF8.self), limit: 400), from: textAt)
                expecting = command == 0x03 ? .response(binary: false) : .prepareOK
            case 0x02:
                let textAt = reader.offset
                add("database", quoted(String(decoding: try reader.take(reader.remaining), as: UTF8.self)), from: textAt)
                expecting = .response(binary: false)
            case 0x17:
                var fieldAt = reader.offset
                let statement = try reader.u32()
                add("statement", "\(statement)", from: fieldAt)
                fieldAt = reader.offset
                add("flags", String(format: "0x%02X", try reader.u8()), from: fieldAt)
                fieldAt = reader.offset
                add("iteration count", "\(try reader.u32())", from: fieldAt)
                if !reader.isAtEnd {
                    fieldAt = reader.offset
                    add("parameters", "\(reader.remaining) bytes (\(statementParameters[statement].map { "\($0) parameters" } ?? "parameter count unknown"))", from: fieldAt)
                    _ = try reader.take(reader.remaining)
                }
                expecting = .response(binary: true)
            case 0x19:
                let fieldAt = reader.offset
                add("statement", "\(try reader.u32())", from: fieldAt)
                expecting = .command  // no answer
            case 0x1B:
                let fieldAt = reader.offset
                add("option", try reader.u16() == 0 ? "multi statements on" : "multi statements off", from: fieldAt)
                expecting = .response(binary: false)
            case 0x01:
                expecting = .command
            default:
                if !reader.isAtEnd {
                    let fieldAt = reader.offset
                    add("arguments", try reader.take(reader.remaining).hex(), from: fieldAt)
                }
                expecting = .response(binary: false)
            }
        }
        return fields
    }
}
