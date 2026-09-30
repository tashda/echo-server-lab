import Foundation
import WireExplanation

extension PostgresExplainer {
    mutating func backend(_ type: UInt8, _ reader: inout WireByteReader, structure: inout String, problems: inout [String]) throws -> [WireField] {
        var fields: [WireField] = []
        func add(_ name: String, _ value: String, from at: Int) { fields.append(WireField(name, offset: at, length: reader.offset - at, value: value)) }
        switch type {
        case 0x52:
            let at = reader.offset
            let code = try reader.u32BE()
            authentication = code
            let names: [UInt32: String] = [0: "AuthenticationOk", 2: "AuthenticationKerberosV5", 3: "AuthenticationCleartextPassword",
                                           5: "AuthenticationMD5Password", 7: "AuthenticationGSS", 8: "AuthenticationGSSContinue",
                                           9: "AuthenticationSSPI", 10: "AuthenticationSASL", 11: "AuthenticationSASLContinue",
                                           12: "AuthenticationSASLFinal"]
            structure = names[code] ?? "Authentication \(code)"
            add("request", "\(code) \(structure)", from: at)
            switch code {
            case 5:
                let saltAt = reader.offset
                add("salt", try reader.take(4).hex(), from: saltAt)
            case 10:
                var mechanisms: [String] = []
                let listAt = reader.offset
                while let next = reader.peek(), next != 0 { mechanisms.append(try cString(&reader)) }
                _ = try reader.u8()
                add("mechanisms", mechanisms.joined(separator: ", "), from: listAt)
            case 8, 11, 12:
                let dataAt = reader.offset
                let data = try reader.take(reader.remaining)
                add(code == 8 ? "GSSAPI token" : "SCRAM data", "\(data.count) bytes (not shown)", from: dataAt)
            default:
                break
            }
        case 0x53:
            let at = reader.offset
            let name = try cString(&reader), value = try cString(&reader)
            add(name, quoted(value), from: at)
        case 0x4B:
            var at = reader.offset
            add("process ID", "\(try reader.u32BE())", from: at)
            at = reader.offset
            let key = try reader.take(reader.remaining)
            add("secret key", "\(key.count) bytes (not shown)", from: at)
        case 0x5A:
            let at = reader.offset
            let status = try reader.u8()
            add("transaction status", ["I": "idle", "T": "in a transaction", "E": "in a failed transaction"][Character(UnicodeScalar(status))] ?? "\(status)", from: at)
        case 0x54:
            let count = Int(try reader.u16BE())
            columns = []
            var children: [WireField] = []
            for _ in 0..<count {
                let at = reader.offset
                let name = try cString(&reader)
                let table = try reader.u32BE(), attribute = try reader.u16BE(), oid = try reader.u32BE()
                let size = Int16(bitPattern: try reader.u16BE()), modifier = Int32(bitPattern: try reader.u32BE())
                let format = Int16(bitPattern: try reader.u16BE())
                columns.append(Column(name: name, typeOID: oid, format: format))
                var detail = "\(PostgresTypes.name(oid)), \(format == 1 ? "binary" : "text")"
                if table != 0 { detail += ", table \(table) column \(attribute)" }
                if modifier >= 0 { detail += ", modifier \(modifier)" }
                if size > 0 { detail += ", \(size) bytes" }
                children.append(WireField("column \(quoted(name))", offset: at, length: reader.offset - at, value: detail))
            }
            fields.append(WireField("columns", offset: children.first?.offset ?? reader.offset, length: 0, value: "\(count)", children: children))
        case 0x44:
            let count = Int(try reader.u16BE())
            if count != columns.count { problems.append("DataRow has \(count) values, the last RowDescription \(columns.count) columns") }
            for index in 0..<count {
                let at = reader.offset
                let length = Int32(bitPattern: try reader.u32BE())
                let column = columns.indices.contains(index) ? columns[index] : Column(name: "column \(index + 1)", typeOID: 0, format: 0)
                let format = resultFormat(index, column)
                let value: String
                if length < 0 {
                    value = "NULL"
                } else {
                    let data = try reader.take(Int(length))
                    value = format == 1 ? PostgresTypes.binary(data, oid: column.typeOID) : quoted(String(decoding: data, as: UTF8.self))
                }
                fields.append(WireField(column.name, offset: at, length: reader.offset - at, value: value))
            }
        case 0x43:
            let at = reader.offset
            add("tag", try cString(&reader), from: at)
        case 0x45, 0x4E:
            let names: [Character: String] = ["S": "severity", "V": "severity (not localized)", "C": "SQLSTATE", "M": "message", "D": "detail",
                                              "H": "hint", "P": "position", "p": "internal position", "q": "internal query", "W": "where",
                                              "s": "schema", "t": "table", "c": "column", "d": "data type", "n": "constraint",
                                              "F": "file", "L": "line", "R": "routine"]
            while let code = reader.peek(), code != 0 {
                let at = reader.offset
                _ = try reader.u8()
                let key = Character(UnicodeScalar(code))
                add(names[key] ?? "field \(key)", quoted(try cString(&reader)), from: at)
            }
            _ = try reader.u8()
        case 0x74:
            let at = reader.offset
            let count = Int(try reader.u16BE())
            add("parameter types", try (0..<count).map { _ in PostgresTypes.name(try reader.u32BE()) }.joined(separator: ", "), from: at)
        case 0x47, 0x48, 0x57:
            var at = reader.offset
            add("format", try reader.u8() == 1 ? "binary" : "text", from: at)
            at = reader.offset
            let count = Int(try reader.u16BE())
            add("column formats", try (0..<count).map { _ in try reader.u16BE() == 1 ? "binary" : "text" }.joined(separator: ", "), from: at)
        case 0x64:
            let at = reader.offset
            let data = try reader.take(reader.remaining)
            add("data", "\(data.count) bytes " + quoted(String(decoding: data.prefix(120), as: UTF8.self)), from: at)
        case 0x41:
            var at = reader.offset
            add("process ID", "\(try reader.u32BE())", from: at)
            at = reader.offset
            add("channel", quoted(try cString(&reader)), from: at)
            at = reader.offset
            add("payload", quoted(try cString(&reader)), from: at)
        case 0x76:
            var at = reader.offset
            add("newest minor version", "\(try reader.u32BE())", from: at)
            at = reader.offset
            let count = Int(try reader.u32BE())
            add("unrecognized options", try (0..<count).map { _ in try cString(&reader) }.joined(separator: ", "), from: at)
        default:
            if !reader.isAtEnd {
                let at = reader.offset
                add("body", try reader.take(reader.remaining).hex(), from: at)
            }
        }
        return fields
    }

    /// A DataRow column's format: Bind's result formats when a Bind came since the last simple Query.
    private func resultFormat(_ index: Int, _ column: Column) -> Int16 {
        guard let formats = bindFormats else { return column.format }
        if formats.isEmpty { return 0 }
        if formats.count == 1 { return formats[0] }
        return formats.indices.contains(index) ? formats[index] : 0
    }
}

/// PostgreSQL's built-in types: names by OID and their binary formats.
public enum PostgresTypes {
    static let names: [UInt32: String] = [
        16: "bool", 17: "bytea", 18: "char", 19: "name", 20: "int8", 21: "int2", 23: "int4", 24: "regproc", 25: "text",
        26: "oid", 28: "xid", 114: "json", 142: "xml", 600: "point", 650: "cidr", 700: "float4", 701: "float8", 790: "money",
        829: "macaddr", 869: "inet", 1042: "bpchar", 1043: "varchar", 1082: "date", 1083: "time", 1114: "timestamp",
        1184: "timestamptz", 1186: "interval", 1266: "timetz", 1560: "bit", 1562: "varbit", 1700: "numeric", 2249: "record",
        2278: "void", 2950: "uuid", 3614: "tsvector", 3615: "tsquery", 3802: "jsonb", 3904: "int4range", 4072: "jsonpath",
        1000: "bool[]", 1001: "bytea[]", 1005: "int2[]", 1007: "int4[]", 1016: "int8[]", 1009: "text[]", 1015: "varchar[]",
        1021: "float4[]", 1022: "float8[]", 1231: "numeric[]", 2951: "uuid[]", 1182: "date[]", 1115: "timestamp[]",
        1185: "timestamptz[]", 199: "json[]", 3807: "jsonb[]",
    ]

    public static func name(_ oid: UInt32) -> String { names[oid] ?? "type \(oid)" }

    /// A binary-format value as text.
    public static func binary(_ b: [UInt8], oid: UInt32) -> String {
        var r = WireByteReader(b)
        func be(_ bytes: [UInt8]) -> Int64 {
            var value: Int64 = 0
            for byte in bytes { value = value << 8 | Int64(byte) }
            let bits = bytes.count * 8
            return bits < 64 && value & (1 << (bits - 1)) != 0 ? value - (1 << bits) : value
        }
        switch oid {
        case 16: return b.first == 1 ? "true" : "false"
        case 20, 21, 23: return "\(be(b))"
        case 26, 28, 24: return "\(UInt32(truncatingIfNeeded: be(b)))"
        case 25, 1043, 1042, 19, 114, 142, 4072: return quoted(String(decoding: b, as: UTF8.self))
        case 3802: return b.first == 1 ? "jsonb " + quoted(String(decoding: b.dropFirst(), as: UTF8.self)) : b.hex()
        case 700: return "\(Float(bitPattern: (try? r.u32BE()) ?? 0))"
        case 701: return "\(Double(bitPattern: UInt64(bitPattern: be(b))))"
        case 790: let cents = be(b); return "\(cents < 0 ? "-" : "")\(cents.magnitude / 100).\(String(format: "%02d", Int(cents.magnitude % 100)))"
        case 1082:
            let days = be(b)
            if days == Int64(Int32.max) { return "infinity" }
            if days == Int64(Int32.min) { return "-infinity" }
            return civil(daysSince2000: Int(days))
        case 1083: return clock(microseconds: be(b))
        case 1266 where b.count == 12:
            // Microseconds, then the zone in seconds west of UTC.
            let west = be(Array(b[8..<12]))
            return clock(microseconds: be(Array(b[0..<8]))) + String(format: "%@%02lld:%02lld", west <= 0 ? "+" : "-", abs(west) / 3600, abs(west) / 60 % 60)
        case 1114, 1184:
            let microseconds = be(b)
            if microseconds == .max { return "infinity" }
            if microseconds == .min { return "-infinity" }
            let days = Int(microseconds >= 0 ? microseconds / 86_400_000_000 : (microseconds - 86_399_999_999) / 86_400_000_000)
            return "\(civil(daysSince2000: days)) \(clock(microseconds: microseconds - Int64(days) * 86_400_000_000))\(oid == 1184 ? " UTC" : "")"
        case 1186 where b.count == 16:
            return "\(be(Array(b[12..<16]))) months \(be(Array(b[8..<12]))) days \(clock(microseconds: be(Array(b[0..<8]))))"
        case 2950 where b.count == 16:
            let hex = b.map { String(format: "%02x", $0) }.joined()
            let parts = [hex.prefix(8), hex.dropFirst(8).prefix(4), hex.dropFirst(12).prefix(4), hex.dropFirst(16).prefix(4), hex.dropFirst(20)]
            return parts.map(String.init).joined(separator: "-")
        case 1700: return numeric(b)
        case 869, 650 where b.count >= 4:
            let address = b.dropFirst(4)
            let text = b[0] == 2 ? address.map { "\($0)" }.joined(separator: ".") : Array(address).hex()
            return "\(text)/\(b[1])"
        default:
            if let element = arrayElements[oid] { return array(b, element: element) }
            return "0x" + b.hex(limit: 48).replacingOccurrences(of: " ", with: "")
        }
    }

    static let arrayElements: [UInt32: UInt32] = [1000: 16, 1001: 17, 1005: 21, 1007: 23, 1016: 20, 1009: 25, 1015: 1043,
                                                  1021: 700, 1022: 701, 1231: 1700, 2951: 2950, 1182: 1082, 1115: 1114,
                                                  1185: 1184, 199: 114, 3807: 3802]

    static func array(_ b: [UInt8], element: UInt32) -> String {
        var r = WireByteReader(b)
        guard let dimensions = try? r.u32BE(), (try? r.u32BE()) != nil, (try? r.u32BE()) != nil else { return b.hex() }
        guard dimensions > 0 else { return "{}" }
        var count = 1
        for _ in 0..<dimensions {
            count *= Int((try? r.u32BE()) ?? 0)
            _ = try? r.u32BE()
        }
        var values: [String] = []
        for _ in 0..<count {
            guard let length = try? r.u32BE() else { break }
            if Int32(bitPattern: length) < 0 { values.append("NULL"); continue }
            guard let data = try? r.take(Int(length)) else { break }
            values.append(binary(data, oid: element))
        }
        return "{" + values.joined(separator: ", ") + "}"
    }

    static func numeric(_ b: [UInt8]) -> String {
        var r = WireByteReader(b)
        guard let count = try? r.u16BE(), let weightBits = try? r.u16BE(), let sign = try? r.u16BE(), let scale = try? r.u16BE() else { return b.hex() }
        if sign == 0xC000 { return "NaN" }
        if sign == 0xD000 { return "Infinity" }
        if sign == 0xF000 { return "-Infinity" }
        let weight = Int(Int16(bitPattern: weightBits))
        let digits = (0..<Int(count)).compactMap { _ in try? r.u16BE() }
        var integer = ""
        for position in 0...max(weight, 0) {
            let digit = position < digits.count && weight >= 0 ? Int(digits[position]) : 0
            integer += position == 0 ? "\(digit)" : String(format: "%04d", digit)
        }
        var fraction = ""
        for position in (weight + 1)..<(weight + 1 + (Int(scale) + 3) / 4) {
            let digit = position >= 0 && position < digits.count ? Int(digits[position]) : 0
            fraction += String(format: "%04d", digit)
        }
        if weight < -1 { fraction = String(repeating: "0000", count: -weight - 1) + fraction }
        let shown = scale > 0 ? integer + "." + fraction.prefix(Int(scale)) : integer
        return (sign == 0x4000 ? "-" : "") + shown
    }

    static func clock(microseconds: Int64) -> String {
        let seconds = microseconds / 1_000_000, fraction = microseconds % 1_000_000
        return String(format: "%02lld:%02lld:%02lld", seconds / 3600, seconds / 60 % 60, seconds % 60) + (fraction == 0 ? "" : String(format: ".%06lld", fraction))
    }

    /// yyyy-mm-dd for a day count since 2000-01-01.
    static func civil(daysSince2000 days: Int) -> String {
        let z = days + 10_957 + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthPrime = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthPrime + 2) / 5 + 1
        let month = monthPrime < 10 ? monthPrime + 3 : monthPrime - 9
        return String(format: "%04d-%02d-%02d", yearOfEra + era * 400 + (month <= 2 ? 1 : 0), month, day)
    }
}
