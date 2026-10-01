import Foundation
import WireExplanation

extension MySQLExplainer {
    static let typeNames: [UInt8: String] = [
        0x00: "DECIMAL", 0x01: "TINY", 0x02: "SHORT", 0x03: "LONG", 0x04: "FLOAT", 0x05: "DOUBLE", 0x06: "NULL",
        0x07: "TIMESTAMP", 0x08: "LONGLONG", 0x09: "INT24", 0x0A: "DATE", 0x0B: "TIME", 0x0C: "DATETIME", 0x0D: "YEAR",
        0x0F: "VARCHAR", 0x10: "BIT", 0x11: "TIMESTAMP2", 0xF2: "VECTOR", 0xF5: "JSON", 0xF6: "NEWDECIMAL", 0xF7: "ENUM",
        0xF8: "SET", 0xF9: "TINY_BLOB", 0xFA: "MEDIUM_BLOB", 0xFB: "LONG_BLOB", 0xFC: "BLOB", 0xFD: "VAR_STRING",
        0xFE: "STRING", 0xFF: "GEOMETRY",
    ]

    mutating func server(_ reader: inout WireByteReader, structure: inout String, problems: inout [String]) throws -> [WireField] {
        var fields: [WireField] = []
        func add(_ name: String, _ value: String, from at: Int) { fields.append(WireField(name, offset: at, length: reader.offset - at, value: value)) }
        guard let first = reader.peek() else { structure = "empty packet"; return fields }

        switch expecting {
        case .greeting:
            structure = "Handshake"
            var at = reader.offset
            add("protocol version", "\(try reader.u8())", from: at)
            at = reader.offset
            add("server version", quoted(try cString(&reader)), from: at)
            at = reader.offset
            add("connection ID", "\(try reader.u32())", from: at)
            at = reader.offset
            _ = try reader.take(9)
            add("auth data, part 1", "8 bytes and a filler", from: at)
            at = reader.offset
            let lower = UInt32(try reader.u16())
            let charset = try reader.u8()
            let status = try reader.u16()
            let upper = UInt32(try reader.u16())
            let capabilities = lower | upper << 16
            add("capabilities, character set, status", String(format: "0x%08X", capabilities) + Self.capabilityNames(capabilities)
                + ", character set \(charset), status 0x" + String(status, radix: 16), from: at)
            at = reader.offset
            let authLength = Int(try reader.u8())
            _ = try reader.take(10)
            _ = try reader.take(max(13, authLength - 8))
            add("auth data, part 2", "\(max(13, authLength - 8)) bytes", from: at)
            if !reader.isAtEnd {
                at = reader.offset
                add("auth plugin", try cString(&reader), from: at)
            }
            expecting = .handshakeResponse
            return fields
        case .authentication:
            switch first {
            case 0x00:
                fields += try okPacket(&reader, structure: &structure)
                expecting = .command
            case 0xFF:
                fields += try errorPacket(&reader, structure: &structure)
                expecting = .command
            case 0xFE:
                structure = "AuthSwitchRequest"
                _ = try reader.u8()
                let at = reader.offset
                add("plugin", try cString(&reader), from: at)
                let dataAt = reader.offset
                add("data", "\(try reader.take(reader.remaining).count) bytes", from: dataAt)
            default:
                structure = "AuthMoreData"
                _ = try reader.u8()
                let at = reader.offset
                let data = try reader.take(reader.remaining)
                let meaning = data == [0x03] ? "fast authentication succeeded" : data == [0x04] ? "full authentication needed"
                    : String(decoding: data.prefix(26), as: UTF8.self).hasPrefix("-----BEGIN PUBLIC KEY") ? "server public key" : "\(data.count) bytes"
                add("data", meaning, from: at)
            }
            return fields
        case .response(let binary):
            switch first {
            case 0x00:
                fields += try okPacket(&reader, structure: &structure)
                expecting = .command
            case 0xFF:
                fields += try errorPacket(&reader, structure: &structure)
                expecting = .command
            case 0xFB:
                structure = "LOCAL INFILE request"
                _ = try reader.u8()
                let at = reader.offset
                add("file", quoted(String(decoding: try reader.take(reader.remaining), as: UTF8.self)), from: at)
                expecting = .command
            default:
                structure = "column count"
                let at = reader.offset
                let count = Int(try lengthEncoded(&reader) ?? 0)
                add("columns", "\(count)", from: at)
                var metadataFollows = true
                if cacheMetadata {
                    let flagAt = reader.offset
                    metadataFollows = try reader.u8() != 0
                    add("metadata follows", metadataFollows ? "yes" : "no (cached by the client)", from: flagAt)
                }
                if metadataFollows {
                    columns = []
                    expecting = .columns(remaining: count, binary: binary)
                } else {
                    expecting = .rows(binary: binary)
                }
            }
        case .columns(let remaining, let binary):
            fields += try columnDefinition(&reader, structure: &structure)
            expecting = remaining > 1 ? .columns(remaining: remaining - 1, binary: binary)
                : deprecateEOF ? .rows(binary: binary) : .columnsEOF(binary: binary)
        case .columnsEOF(let binary):
            fields += try eofPacket(&reader, structure: &structure)
            expecting = .rows(binary: binary)
        case .rows(let binary):
            if first == 0xFE, reader.remaining < 0xFF_FFFF, (deprecateEOF || reader.remaining < 9) {
                let status: UInt16
                if deprecateEOF {
                    fields += try okPacket(&reader, structure: &structure)
                    status = UInt16(fields.first { $0.name == "status" }?.value.dropFirst(2) ?? "0", radix: 16) ?? 0
                } else {
                    fields += try eofPacket(&reader, structure: &structure)
                    status = UInt16(fields.first { $0.name == "status" }?.value.dropFirst(2) ?? "0", radix: 16) ?? 0
                }
                expecting = status & 0x0008 != 0 ? .response(binary: binary) : .command
            } else if first == 0xFF {
                fields += try errorPacket(&reader, structure: &structure)
                expecting = .command
            } else {
                structure = binary ? "binary row" : "text row"
                fields += binary ? try binaryRow(&reader) : try textRow(&reader)
            }
        case .prepareOK:
            if first == 0xFF {
                fields += try errorPacket(&reader, structure: &structure)
                expecting = .command
                return fields
            }
            structure = "COM_STMT_PREPARE_OK"
            _ = try reader.u8()
            var at = reader.offset
            let statement = try reader.u32()
            add("statement", "\(statement)", from: at)
            at = reader.offset
            let columnCount = Int(try reader.u16()), parameterCount = Int(try reader.u16())
            add("columns, parameters", "\(columnCount), \(parameterCount)", from: at)
            at = reader.offset
            _ = try reader.u8()
            add("warnings", "\(try reader.u16())", from: at)
            if !reader.isAtEnd {
                at = reader.offset
                add("metadata follows", "\(try reader.u8())", from: at)
            }
            statementParameters[statement] = parameterCount
            let eofs = deprecateEOF ? 0 : (parameterCount > 0 ? 1 : 0) + (columnCount > 0 ? 1 : 0)
            let total = parameterCount + columnCount + eofs
            expecting = total == 0 ? .command : .prepareDefinitions(remaining: total, thenColumns: 0)
        case .prepareDefinitions(let remaining, _):
            if first == 0xFE, reader.remaining < 9 {
                fields += try eofPacket(&reader, structure: &structure)
            } else {
                fields += try columnDefinition(&reader, structure: &structure)
            }
            expecting = remaining > 1 ? .prepareDefinitions(remaining: remaining - 1, thenColumns: 0) : .command
        case .handshakeResponse, .command:
            problems.append("The server sent a packet when the client was expected")
            _ = try reader.take(reader.remaining)
        }
        return fields
    }

    func okPacket(_ reader: inout WireByteReader, structure: inout String) throws -> [WireField] {
        var fields: [WireField] = []
        func add(_ name: String, _ value: String, from at: Int) { fields.append(WireField(name, offset: at, length: reader.offset - at, value: value)) }
        structure = (try reader.u8()) == 0x00 ? "OK" : "OK (end of rows)"
        var at = reader.offset
        add("affected rows", "\(try lengthEncoded(&reader) ?? 0)", from: at)
        at = reader.offset
        add("last insert ID", "\(try lengthEncoded(&reader) ?? 0)", from: at)
        at = reader.offset
        add("status", "0x" + String(try reader.u16(), radix: 16), from: at)
        at = reader.offset
        add("warnings", "\(try reader.u16())", from: at)
        if !reader.isAtEnd {
            at = reader.offset
            let info = try reader.take(reader.remaining)
            add("info", quoted(String(decoding: info, as: UTF8.self)), from: at)
        }
        return fields
    }

    func errorPacket(_ reader: inout WireByteReader, structure: inout String) throws -> [WireField] {
        structure = "ERR"
        _ = try reader.u8()
        let at = reader.offset
        let code = try reader.u16()
        var state = ""
        if reader.peek() == 0x23 {
            _ = try reader.u8()
            state = String(decoding: try reader.take(5), as: UTF8.self)
        }
        let message = String(decoding: try reader.take(reader.remaining), as: UTF8.self)
        return [WireField("error", offset: at, length: reader.offset - at, value: "\(code)\(state.isEmpty ? "" : " (\(state))"): \(quoted(message))")]
    }

    func eofPacket(_ reader: inout WireByteReader, structure: inout String) throws -> [WireField] {
        structure = "EOF"
        _ = try reader.u8()
        let at = reader.offset
        let warnings = try reader.u16()
        let statusAt = reader.offset
        let status = try reader.u16()
        return [WireField("warnings", offset: at, length: 2, value: "\(warnings)"),
                WireField("status", offset: statusAt, length: 2, value: "0x" + String(status, radix: 16))]
    }

    mutating func columnDefinition(_ reader: inout WireByteReader, structure: inout String) throws -> [WireField] {
        structure = "column definition"
        let at = reader.offset
        let catalog = try lengthEncodedString(&reader), schema = try lengthEncodedString(&reader)
        let table = try lengthEncodedString(&reader), _ = try lengthEncodedString(&reader)
        let name = try lengthEncodedString(&reader), _ = try lengthEncodedString(&reader)
        _ = try lengthEncoded(&reader)
        let charset = try reader.u16(), length = try reader.u32(), type = try reader.u8(), flags = try reader.u16(), decimals = try reader.u8()
        _ = try reader.take(min(2, reader.remaining))
        if !reader.isAtEnd { _ = try reader.take(reader.remaining) }  // COM_FIELD_LIST default value
        columns.append(Column(name: name, type: type, flags: flags, decimals: decimals))
        let typeName = Self.typeNames[type] ?? String(format: "type 0x%02X", type)
        let flagNames = [(0x0001, "NOT NULL"), (0x0002, "PRIMARY KEY"), (0x0020, "UNSIGNED"), (0x0080, "BINARY"), (0x0200, "AUTO_INCREMENT")]
            .filter { Int(flags) & $0.0 != 0 }.map(\.1)
        let place = [catalog == "def" ? nil : catalog, schema.isEmpty ? nil : schema, table.isEmpty ? nil : table].compactMap { $0 }.joined(separator: ".")
        return [WireField("column \(quoted(name))", offset: at, length: reader.offset - at,
                          value: ([typeName, "length \(length)", "character set \(charset)"] + flagNames + (place.isEmpty ? [] : ["from \(place)"])).joined(separator: ", "))]
    }

    func textRow(_ reader: inout WireByteReader) throws -> [WireField] {
        var fields: [WireField] = []
        for column in columns {
            let at = reader.offset
            if reader.peek() == 0xFB {
                _ = try reader.u8()
                fields.append(WireField(column.name, offset: at, length: 1, value: "NULL"))
                continue
            }
            let length = Int(try lengthEncoded(&reader) ?? 0)
            let data = try reader.take(length)
            fields.append(WireField(column.name, offset: at, length: reader.offset - at, value: render(data, column: column, binaryProtocol: false)))
        }
        return fields
    }

    func binaryRow(_ reader: inout WireByteReader) throws -> [WireField] {
        _ = try reader.u8()
        let bitmapAt = reader.offset
        let bitmap = try reader.take((columns.count + 7 + 2) / 8)
        var fields = [WireField("null bitmap", offset: bitmapAt, length: bitmap.count, value: bitmap.hex())]
        for (index, column) in columns.enumerated() {
            let bit = index + 2
            if bitmap[bit / 8] & (1 << (bit % 8)) != 0 {
                fields.append(WireField(column.name, offset: reader.offset, length: 0, value: "NULL (bitmap)"))
                continue
            }
            let at = reader.offset
            let value: String
            let unsigned = column.flags & 0x0020 != 0
            switch column.type {
            case 0x01: let b = try reader.u8(); value = unsigned ? "\(b)" : "\(Int8(bitPattern: b))"
            case 0x02, 0x0D: let b = try reader.u16(); value = unsigned || column.type == 0x0D ? "\(b)" : "\(Int16(bitPattern: b))"
            case 0x03, 0x09: let b = try reader.u32(); value = unsigned ? "\(b)" : "\(Int32(bitPattern: b))"
            case 0x08: let b = try reader.u64(); value = unsigned ? "\(b)" : "\(Int64(bitPattern: b))"
            case 0x04: value = "\(Float(bitPattern: try reader.u32()))"
            case 0x05: value = "\(Double(bitPattern: try reader.u64()))"
            case 0x0A, 0x07, 0x0C:
                let length = Int(try reader.u8())
                var r = WireByteReader(try reader.take(length))
                if length == 0 { value = "0000-00-00 00:00:00"; break }
                var text = String(format: "%04d-%02d-%02d", try r.u16(), try r.u8(), try r.u8())
                if length >= 7 { text += String(format: " %02d:%02d:%02d", try r.u8(), try r.u8(), try r.u8()) }
                if length >= 11 { text += String(format: ".%06d", try r.u32()) }
                value = text
            case 0x0B:
                let length = Int(try reader.u8())
                var r = WireByteReader(try reader.take(length))
                if length == 0 { value = "00:00:00"; break }
                let negative = try r.u8() == 1
                let days = try r.u32(), hours = try r.u8(), minutes = try r.u8(), seconds = try r.u8()
                let micro = length >= 12 ? try r.u32() : 0
                value = (negative ? "-" : "") + String(format: "%02d:%02d:%02d", Int(days) * 24 + Int(hours), minutes, seconds)
                    + (length >= 12 ? String(format: ".%06d", micro) : "")
            case 0x06:
                value = "NULL"
            default:
                let length = Int(try lengthEncoded(&reader) ?? 0)
                value = render(try reader.take(length), column: column, binaryProtocol: true)
            }
            fields.append(WireField(column.name, offset: at, length: reader.offset - at, value: value))
        }
        return fields
    }

    func render(_ data: [UInt8], column: Column, binaryProtocol: Bool) -> String {
        switch column.type {
        case 0xFF: return "geometry (SRID \(data.count >= 4 ? Int(data[0]) | Int(data[1]) << 8 | Int(data[2]) << 16 | Int(data[3]) << 24 : 0)), \(data.count) bytes WKB"
        case 0x10: return "b'" + data.map { String($0, radix: 2).leftPadded(to: 8) }.joined() + "'"
        case 0xF2: return "vector, \(data.count / 4) floats"
        case 0xF9, 0xFA, 0xFB, 0xFC, 0xFE, 0xFD, 0x0F:
            // The BINARY flag marks binary strings and blobs.
            if column.flags & 0x0080 != 0, String(bytes: data, encoding: .utf8) == nil || data.contains(0) {
                return "0x" + data.hex(limit: 48).replacingOccurrences(of: " ", with: "")
            }
            return quoted(String(decoding: data, as: UTF8.self))
        default:
            return binaryProtocol || [0xF5, 0xF7, 0xF8].contains(column.type)
                ? quoted(String(decoding: data, as: UTF8.self)) : String(decoding: data, as: UTF8.self)
        }
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

    /// A length-encoded integer; nil for 0xFB (NULL).
    func lengthEncoded(_ reader: inout WireByteReader) throws -> UInt64? {
        let first = try reader.u8()
        switch first {
        case 0xFB: return nil
        case 0xFC: return UInt64(try reader.u16())
        case 0xFD: let b = try reader.take(3); return UInt64(b[0]) | UInt64(b[1]) << 8 | UInt64(b[2]) << 16
        case 0xFE: return try reader.u64()
        default: return UInt64(first)
        }
    }

    func lengthEncodedString(_ reader: inout WireByteReader) throws -> String {
        let length = Int(try lengthEncoded(&reader) ?? 0)
        return String(decoding: try reader.take(length), as: UTF8.self)
    }

    static func capabilityNames(_ capabilities: UInt32) -> String {
        let names = [(0x0000_0800, "SSL"), (0x0000_0200, "PROTOCOL_41"), (0x0000_8000, "SECURE_CONNECTION"), (0x0008_0000, "PLUGIN_AUTH"),
                     (0x0001_0000, "MULTI_STATEMENTS"), (0x0002_0000, "MULTI_RESULTS"), (0x0100_0000, "DEPRECATE_EOF"),
                     (0x0080_0000, "SESSION_TRACK"), (0x0000_0020, "COMPRESS"), (0x0800_0000, "QUERY_ATTRIBUTES")]
            .filter { Int(capabilities) & $0.0 != 0 }.map(\.1)
        return names.isEmpty ? "" : " (" + names.joined(separator: ", ") + ")"
    }
}

extension String {
    func leftPadded(to length: Int) -> String { String(repeating: "0", count: max(0, length - count)) + self }
}
