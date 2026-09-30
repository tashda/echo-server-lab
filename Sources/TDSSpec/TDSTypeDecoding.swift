import Foundation

/// A column's or parameter's TYPE_INFO: what follows on the wire for its values.
struct TDSTypeInfo: Sendable, Hashable {
    enum Layout: Sendable, Hashable {
        case fixed(Int)
        /// 1-byte value length (0: NULL).
        case byteLength
        /// 2-byte value length (0xFFFF: NULL).
        case ushortLength
        /// Partially length-prefixed: 8-byte total, then chunks (MAX types, XML, UDT, JSON).
        case plp
        /// text/ntext/image: text pointer, timestamp, 4-byte length.
        case textPointer
        /// sql_variant: 4-byte length, base type, properties.
        case variant
    }

    var code: UInt8
    var name: String
    var layout: Layout
    var maxLength = 0
    var precision = 0
    var scale = 0
    var collation: [UInt8]?

    var isUnicode: Bool { [0xE7, 0xEF, 0x63].contains(code) }
    var isCharacter: Bool { [0xA7, 0xAF, 0x23, 0x2F, 0x27].contains(code) }
    /// The collation's UTF-8 flag (SQL Server 2019+ `_UTF8` collations).
    var isUTF8: Bool { (collation.map { $0[3] & 0x04 != 0 }) ?? false }
}

enum TDSTypeCodes {
    static let fixedLengths: [UInt8: Int] = [0x1F: 0, 0x30: 1, 0x32: 1, 0x34: 2, 0x38: 4, 0x3A: 4, 0x3B: 4, 0x3C: 8,
                                              0x3D: 8, 0x3E: 8, 0x7A: 4, 0x7F: 8]
    static let byteLength: Set<UInt8> = [0x24, 0x26, 0x68, 0x6D, 0x6E, 0x6F, 0x2F, 0x27, 0x2D, 0x25]
    static let decimals: Set<UInt8> = [0x6A, 0x6C, 0x37, 0x3F]
    static let scaled: Set<UInt8> = [0x29, 0x2A, 0x2B]
    static let ushortLength: Set<UInt8> = [0xA5, 0xAD, 0xA7, 0xAF, 0xE7, 0xEF]
    static let names: [UInt8: String] = [
        0x1F: "null", 0x30: "tinyint", 0x32: "bit", 0x34: "smallint", 0x38: "int", 0x3A: "smalldatetime", 0x3B: "real",
        0x3C: "money", 0x3D: "datetime", 0x3E: "float", 0x7A: "smallmoney", 0x7F: "bigint", 0x24: "uniqueidentifier",
        0x26: "intn", 0x68: "bitn", 0x6D: "fltn", 0x6E: "moneyn", 0x6F: "datetimn", 0x6A: "decimal", 0x6C: "numeric",
        0x37: "decimal (legacy)", 0x3F: "numeric (legacy)", 0x28: "date", 0x29: "time", 0x2A: "datetime2",
        0x2B: "datetimeoffset", 0x2F: "char (legacy)", 0x27: "varchar (legacy)", 0x2D: "binary (legacy)",
        0x25: "varbinary (legacy)", 0xA5: "varbinary", 0xA7: "varchar", 0xAD: "binary", 0xAF: "char", 0xE7: "nvarchar",
        0xEF: "nchar", 0x23: "text", 0x22: "image", 0x63: "ntext", 0x62: "sql_variant", 0xF1: "xml", 0xF0: "udt",
        0xF3: "table-valued parameter", 0xF4: "json", 0xF5: "vector",
    ]
}

extension TDSExplainer {
    /// Reads TYPE_INFO. `inColumnMetadata` adds what COLMETADATA carries and RPC does not
    /// (table names for text/image, the UDT's assembly name).
    func typeInfo(_ reader: inout TDSByteReader, inColumnMetadata: Bool) throws -> (TDSTypeInfo, TDSField) {
        let start = reader.offset
        let code = try reader.u8()
        let name = TDSTypeCodes.names[code] ?? spec.typeName(code) ?? String(format: "unknown type 0x%02X", code)
        var info = TDSTypeInfo(code: code, name: name, layout: .byteLength)
        var parts: [TDSField] = []
        func part(_ name: String, _ value: String, from: Int) { parts.append(TDSField(name, offset: from, length: reader.offset - from, value: value)) }

        if let length = TDSTypeCodes.fixedLengths[code] {
            info.layout = .fixed(length)
        } else if TDSTypeCodes.byteLength.contains(code) {
            let at = reader.offset
            info.maxLength = Int(try reader.u8())
            part("max length", "\(info.maxLength)", from: at)
        } else if TDSTypeCodes.decimals.contains(code) {
            let at = reader.offset
            info.maxLength = Int(try reader.u8())
            info.precision = Int(try reader.u8())
            info.scale = Int(try reader.u8())
            part("length, precision, scale", "\(info.maxLength), \(info.precision), \(info.scale)", from: at)
        } else if code == 0x28 {
            info.layout = .byteLength
        } else if TDSTypeCodes.scaled.contains(code) {
            let at = reader.offset
            info.scale = Int(try reader.u8())
            part("scale", "\(info.scale)", from: at)
        } else if TDSTypeCodes.ushortLength.contains(code) {
            let at = reader.offset
            info.maxLength = Int(try reader.u16())
            info.layout = info.maxLength == 0xFFFF ? .plp : .ushortLength
            part("max length", info.maxLength == 0xFFFF ? "MAX (PLP)" : "\(info.maxLength) bytes", from: at)
            if [0xA7, 0xAF, 0xE7, 0xEF].contains(code) { parts.append(try collation(&reader, into: &info)) }
        } else if code == 0x23 || code == 0x63 || code == 0x22 {
            info.layout = .textPointer
            let at = reader.offset
            info.maxLength = Int(try reader.u32())
            part("max length", "\(info.maxLength)", from: at)
            if code != 0x22 { parts.append(try collation(&reader, into: &info)) }
            if inColumnMetadata {
                let at = reader.offset
                let count = Int(try reader.u8())
                let names = try (0..<count).map { _ in try reader.usVarChar() }
                part("table name", names.joined(separator: "."), from: at)
            }
        } else if code == 0x62 {
            info.layout = .variant
            let at = reader.offset
            info.maxLength = Int(try reader.u32())
            part("max length", "\(info.maxLength)", from: at)
        } else if code == 0xF1 {
            info.layout = .plp
            let at = reader.offset
            let hasSchema = try reader.u8()
            if hasSchema == 1 {
                let database = try reader.bVarChar(), owner = try reader.bVarChar(), collection = try reader.usVarChar()
                part("schema collection", "\(database).\(owner).\(collection)", from: at)
            } else {
                part("schema collection", "none", from: at)
            }
        } else if code == 0xF0 {
            info.layout = .plp
            let at = reader.offset
            if inColumnMetadata { info.maxLength = Int(try reader.u16()) }
            let database = try reader.bVarChar(), schema = try reader.bVarChar(), type = try reader.bVarChar()
            var text = "\(database).\(schema).\(type)"
            if inColumnMetadata { text += " (\(try reader.usVarChar()))" }
            part("UDT", text, from: at)
        } else if code == 0xF4 {
            info.layout = .plp
        } else if code == 0xF5 {
            let at = reader.offset
            info.maxLength = Int(try reader.u16())
            let dimensionType = try reader.u8()
            info.layout = .ushortLength
            part("max length, dimension type", "\(info.maxLength), \(dimensionType == 0 ? "float32" : String(format: "0x%02X", dimensionType))", from: at)
        } else {
            throw TDSExplainer.Unknown(what: String(format: "type 0x%02X", code), offset: start)
        }
        return (info, TDSField("type", offset: start, length: reader.offset - start, value: String(format: "0x%02X %@", code, name), children: parts))
    }

    private func collation(_ reader: inout TDSByteReader, into info: inout TDSTypeInfo) throws -> TDSField {
        let at = reader.offset
        let bytes = try reader.take(5)
        info.collation = bytes
        let lcid = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2] & 0x0F) << 16
        let flags = [(bytes[2] & 0x10 != 0, "ignore case"), (bytes[2] & 0x20 != 0, "ignore accents"), (bytes[3] & 0x04 != 0, "UTF-8"),
                     (bytes[3] & 0x01 != 0, "binary")].filter(\.0).map(\.1)
        let value = String(format: "LCID 0x%04X, sort id %d", lcid, bytes[4]) + (flags.isEmpty ? "" : ", " + flags.joined(separator: ", "))
        return TDSField("collation", offset: at, length: 5, value: value)
    }

    /// Reads one value of the type (a ROW column, an RPC parameter, a RETURNVALUE).
    func value(_ reader: inout TDSByteReader, of info: TDSTypeInfo, name: String = "value") throws -> TDSField {
        let start = reader.offset
        let bytes: [UInt8]?
        switch info.layout {
        case .fixed(let length):
            bytes = try reader.take(length)
        case .byteLength:
            let length = Int(try reader.u8())
            bytes = length == 0 && info.code != 0x28 ? nil : try reader.take(length)
            if info.code == 0x28, length == 0 { return TDSField(name, offset: start, length: 1, value: "NULL") }
        case .ushortLength:
            let length = Int(try reader.u16())
            bytes = length == 0xFFFF ? nil : try reader.take(length)
        case .plp:
            let (data, chunks) = try plp(&reader)
            let field = TDSField(name, offset: start, length: reader.offset - start,
                                 value: data.map { render($0, as: info) } ?? "NULL", children: chunks)
            return field
        case .textPointer:
            let pointerLength = Int(try reader.u8())
            if pointerLength == 0 { return TDSField(name, offset: start, length: 1, value: "NULL") }
            _ = try reader.take(pointerLength + 8)
            bytes = try reader.take(Int(try reader.u32()))
        case .variant:
            let length = Int(try reader.u32())
            if length == 0 { return TDSField(name, offset: start, length: 4, value: "NULL") }
            var inner = TDSByteReader(try reader.take(length), base: start + 4)
            return try variant(&inner, name: name, start: start, total: reader.offset - start)
        }
        guard let bytes else { return TDSField(name, offset: start, length: reader.offset - start, value: "NULL") }
        return TDSField(name, offset: start, length: reader.offset - start, value: render(bytes, as: info))
    }

    /// PLP: the total length (or unknown), then chunks until a zero-length one.
    private func plp(_ reader: inout TDSByteReader) throws -> ([UInt8]?, [TDSField]) {
        let at = reader.offset
        let total = try reader.u64()
        if total == UInt64.max { return (nil, [TDSField("PLP length", offset: at, length: 8, value: "NULL")]) }
        var fields = [TDSField("PLP length", offset: at, length: 8, value: total == UInt64.max - 1 ? "unknown" : "\(total)")]
        var data: [UInt8] = []
        while true {
            let chunkAt = reader.offset
            let length = Int(try reader.u32())
            if length == 0 {
                fields.append(TDSField("PLP terminator", offset: chunkAt, length: 4))
                break
            }
            data += try reader.take(length)
            fields.append(TDSField("chunk", offset: chunkAt, length: 4 + length, value: "\(length) bytes"))
        }
        return (data, fields.count > 6 ? Array(fields.prefix(3)) + [TDSField("… \(fields.count - 4) more chunks", offset: fields[3].offset, length: 0)] + [fields.last!] : fields)
    }

    private func variant(_ reader: inout TDSByteReader, name: String, start: Int, total: Int) throws -> TDSField {
        let code = try reader.u8()
        let propertyLength = Int(try reader.u8())
        var info = TDSTypeInfo(code: code, name: TDSTypeCodes.names[code] ?? String(format: "0x%02X", code), layout: .fixed(0))
        var properties = TDSByteReader(try reader.take(propertyLength))
        if TDSTypeCodes.decimals.contains(code) {
            info.precision = Int(try properties.u8()); info.scale = Int(try properties.u8())
        } else if TDSTypeCodes.scaled.contains(code) {
            info.scale = Int(try properties.u8())
        } else if [0xA7, 0xAF, 0xE7, 0xEF].contains(code) {
            info.collation = try properties.take(5)
        }
        let data = try reader.take(reader.remaining)
        return TDSField(name, offset: start, length: total, value: "sql_variant \(info.name): \(render(data, as: info))")
    }

    /// A value's bytes as text, by type.
    func render(_ b: [UInt8], as info: TDSTypeInfo) -> String {
        var r = TDSByteReader(b)
        func signed(_ bytes: [UInt8]) -> Int64 {
            var value: Int64 = 0
            for (index, byte) in bytes.enumerated() { value |= Int64(byte) << (8 * Int64(index)) }
            let bits = bytes.count * 8
            return bits < 64 && value & (1 << (bits - 1)) != 0 ? value - (1 << bits) : value
        }
        switch info.code {
        case 0x30: return "\(b.first ?? 0)"
        case 0x32, 0x68: return b.first == 0 ? "0 (false)" : "1 (true)"
        case 0x34, 0x38, 0x7F: return "\(signed(b))"
        case 0x26: return b.count == 1 ? "\(b[0])" : "\(signed(b))"
        case 0x3B: return "\(Float(bitPattern: (try? r.u32()) ?? 0))"
        case 0x3E: return "\(Double(bitPattern: (try? r.u64()) ?? 0))"
        case 0x6D: return b.count == 4 ? "\(Float(bitPattern: (try? r.u32()) ?? 0))" : "\(Double(bitPattern: (try? r.u64()) ?? 0))"
        case 0x3C, 0x7A, 0x6E: return money(b)
        case 0x3D, 0x3A, 0x6F: return legacyDateTime(b)
        case 0x24: return guid(b)
        case 0x6A, 0x6C, 0x37, 0x3F: return decimal(b, scale: info.scale)
        case 0x28: return b.count == 3 ? date(b) : b.hex()
        case 0x29: return time(b, scale: info.scale)
        case 0x2A:
            let timeLength = b.count - 3
            return "\(date(Array(b[timeLength...]))) \(time(Array(b[..<timeLength]), scale: info.scale))"
        case 0x2B:
            let timeLength = b.count - 5
            let offset = Int16(bitPattern: UInt16(b[b.count - 2]) | UInt16(b[b.count - 1]) << 8)
            return "\(date(Array(b[timeLength..<(timeLength + 3)]))) \(time(Array(b[..<timeLength]), scale: info.scale)) UTC, offset \(offset) min"
        case 0xE7, 0xEF, 0x63: return quoted(TDSByteReader.ucs2(b))
        case 0xA7, 0xAF, 0x23, 0x2F, 0x27:
            return quoted(info.isUTF8 ? String(decoding: b, as: UTF8.self) : String(bytes: b, encoding: .windowsCP1252) ?? b.hex())
        case 0xF1: return "xml " + quoted(TDSByteReader.ucs2(b))
        case 0xF4: return "json " + quoted(String(decoding: b, as: UTF8.self))
        case 0xF5: return vector(b)
        default: return "0x" + b.hex(limit: 64).replacingOccurrences(of: " ", with: "")
        }
    }

    private func money(_ b: [UInt8]) -> String {
        let cents: Int64
        if b.count == 8 {
            let high = UInt64(b[0]) | UInt64(b[1]) << 8 | UInt64(b[2]) << 16 | UInt64(b[3]) << 24
            let low = UInt64(b[4]) | UInt64(b[5]) << 8 | UInt64(b[6]) << 16 | UInt64(b[7]) << 24
            cents = Int64(bitPattern: high << 32 | low)
        } else {
            cents = Int64(Int32(bitPattern: UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24))
        }
        let sign = cents < 0 ? "-" : ""
        let magnitude = cents.magnitude
        return "\(sign)\(magnitude / 10_000).\(String(format: "%04d", Int(magnitude % 10_000)))"
    }

    private func legacyDateTime(_ b: [UInt8]) -> String {
        if b.count == 4 {
            let days = Int(UInt16(b[0]) | UInt16(b[1]) << 8), minutes = Int(UInt16(b[2]) | UInt16(b[3]) << 8)
            return "\(Self.civil(daysSince0001: days + Self.days1900)) \(String(format: "%02d:%02d", minutes / 60, minutes % 60))"
        }
        let days = Int(Int32(bitPattern: UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24))
        let ticks = Int(UInt32(b[4]) | UInt32(b[5]) << 8 | UInt32(b[6]) << 16 | UInt32(b[7]) << 24)
        let milliseconds = ticks * 10 / 3
        return "\(Self.civil(daysSince0001: days + Self.days1900)) " + String(format: "%02d:%02d:%02d.%03d",
            milliseconds / 3_600_000, milliseconds / 60_000 % 60, milliseconds / 1000 % 60, milliseconds % 1000)
    }

    private func guid(_ b: [UInt8]) -> String {
        guard b.count == 16 else { return b.hex() }
        let order = [3, 2, 1, 0, 5, 4, 7, 6, 8, 9, 10, 11, 12, 13, 14, 15]
        let hex = order.map { String(format: "%02X", b[$0]) }
        return [hex[0..<4], hex[4..<6], hex[6..<8], hex[8..<10], hex[10..<16]].map { $0.joined() }.joined(separator: "-")
    }

    private func decimal(_ b: [UInt8], scale: Int) -> String {
        guard let sign = b.first else { return "" }
        var magnitude: UInt128 = 0
        for (index, byte) in b.dropFirst().enumerated() where index < 16 { magnitude |= UInt128(byte) << (8 * UInt128(index)) }
        var digits = String(magnitude)
        if scale > 0 {
            if digits.count <= scale { digits = String(repeating: "0", count: scale - digits.count + 1) + digits }
            digits.insert(".", at: digits.index(digits.endIndex, offsetBy: -scale))
        }
        return (sign == 0 ? "-" : "") + digits
    }

    private func date(_ b: [UInt8]) -> String {
        Self.civil(daysSince0001: Int(UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16))
    }

    private func time(_ b: [UInt8], scale: Int) -> String {
        var units: UInt64 = 0
        for (index, byte) in b.enumerated() { units |= UInt64(byte) << (8 * UInt64(index)) }
        var divisor: UInt64 = 1
        for _ in 0..<scale { divisor *= 10 }
        let seconds = units / divisor, fraction = units % divisor
        var text = String(format: "%02d:%02d:%02d", Int(seconds / 3600), Int(seconds / 60 % 60), Int(seconds % 60))
        if scale > 0 { text += "." + String(format: "%0\(scale)llu", fraction) }
        return text
    }

    private func vector(_ b: [UInt8]) -> String {
        // Header: magic 0xA9, version, dimension count (2), element type, 3 reserved; then float32 values.
        guard b.count >= 8, b[0] == 0xA9 else { return "vector 0x" + b.hex(limit: 64).replacingOccurrences(of: " ", with: "") }
        let dimensions = Int(UInt16(b[2]) | UInt16(b[3]) << 8)
        var r = TDSByteReader(Array(b[8...]))
        let values = (0..<min(dimensions, 16)).compactMap { _ in (try? r.u32()).map { Float(bitPattern: $0) } }
        return "vector(\(dimensions)) [" + values.map { "\($0)" }.joined(separator: ", ") + (dimensions > 16 ? ", …]" : "]")
    }

    static let days1900 = 693_595

    /// yyyy-mm-dd for a day count since 0001-01-01 (proleptic Gregorian).
    static func civil(daysSince0001 days: Int) -> String {
        let z = days - 719_162 + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthPrime = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthPrime + 2) / 5 + 1
        let month = monthPrime < 10 ? monthPrime + 3 : monthPrime - 9
        let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
        return String(format: "%04d-%02d-%02d", year, month, day)
    }
}
