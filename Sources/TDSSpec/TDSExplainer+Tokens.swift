import Foundation

extension TDSExplainer {
    static let tokenNames: [UInt8: String] = [
        0x81: "COLMETADATA", 0xD1: "ROW", 0xD2: "NBCROW", 0xFD: "DONE", 0xFE: "DONEPROC", 0xFF: "DONEINPROC",
        0xE3: "ENVCHANGE", 0xAA: "ERROR", 0xAB: "INFO", 0xAD: "LOGINACK", 0xAE: "FEATUREEXTACK", 0x79: "RETURNSTATUS",
        0xAC: "RETURNVALUE", 0xA9: "ORDER", 0xA5: "COLINFO", 0xA4: "TABNAME", 0xE4: "SESSIONSTATE", 0xED: "SSPI",
        0xEE: "FEDAUTHINFO", 0xA3: "DATACLASSIFICATION", 0x78: "OFFSET", 0x88: "ALTMETADATA", 0xD3: "ALTROW",
    ]

    /// A tabular result's tokens, one field each, until the bytes end or a token is not in the spec.
    mutating func tokens(_ reader: inout TDSByteReader, problems: inout [String]) throws -> [TDSField] {
        var fields: [TDSField] = []
        while !reader.isAtEnd {
            let at = reader.offset
            let token = try reader.u8()
            guard let name = Self.tokenNames[token] ?? spec.tokenName(token) else {
                problems.append(String(format: "Token 0x%02X at +%d is not in the spec; the rest is not decoded", token, at))
                reader.position = reader.bytes.count
                break
            }
            var children: [TDSField] = []
            var value = ""
            switch token {
            case 0x81:
                let count = Int(try reader.u16())
                if count == 0xFFFF {
                    value = "no metadata"
                } else {
                    columns = []
                    for index in 0..<count {
                        let columnAt = reader.offset
                        let userType = try reader.u32(), flags = try reader.u16()
                        let (type, typeField) = try typeInfo(&reader, inColumnMetadata: true)
                        let columnName = try reader.bVarChar()
                        columns.append((columnName, type))
                        let flagNames = [(flags & 0x0001 != 0, "nullable"), (flags & 0x0010 != 0, "identity"), (flags & 0x0008 != 0, "updatable"),
                                         (flags & 0x0020 != 0, "computed"), (flags & 0x0800 != 0, "hidden"), (flags & 0x1000 != 0, "key"),
                                         (flags & 0x0400 != 0, "sparse column set")].filter(\.0).map(\.1)
                        children.append(TDSField("column \(index + 1) \(quoted(columnName))", offset: columnAt, length: reader.offset - columnAt,
                                                 value: ([type.name] + flagNames + (userType != 0 ? ["user type \(userType)"] : [])).joined(separator: ", "),
                                                 children: [typeField]))
                    }
                    value = "\(count) columns"
                }
            case 0xD1:
                guard !columns.isEmpty else { throw Unknown(what: "ROW without COLMETADATA", offset: at) }
                for column in columns {
                    children.append(try self.value(&reader, of: column.type, name: column.name))
                }
            case 0xD2:
                guard !columns.isEmpty else { throw Unknown(what: "NBCROW without COLMETADATA", offset: at) }
                let bitmapAt = reader.offset
                let bitmap = try reader.take((columns.count + 7) / 8)
                children.append(TDSField("null bitmap", offset: bitmapAt, length: bitmap.count, value: bitmap.hex()))
                for (index, column) in columns.enumerated() {
                    if bitmap[index / 8] & (1 << (index % 8)) != 0 {
                        children.append(TDSField(column.name, offset: reader.offset, length: 0, value: "NULL (bitmap)"))
                    } else {
                        children.append(try self.value(&reader, of: column.type, name: column.name))
                    }
                }
            case 0xFD, 0xFE, 0xFF:
                let status = try reader.u16(), command = try reader.u16(), rows = try reader.u64()
                let statusNames = [(0x01, "more"), (0x02, "error"), (0x04, "in transaction"), (0x10, "count"), (0x20, "attention"),
                                   (0x100, "server error")].filter { Int(status) & $0.0 != 0 }.map(\.1)
                value = "status \(statusNames.isEmpty ? "final" : statusNames.joined(separator: ", ")), command \(command)"
                    + (status & 0x10 != 0 ? ", \(rows) rows" : "")
            case 0xE3:
                let length = Int(try reader.u16())
                var body = TDSByteReader(try reader.take(length), base: reader.offset - length)
                value = try environmentChange(&body)
            case 0xAA, 0xAB:
                _ = try reader.u16()
                let number = try reader.u32(), state = try reader.u8(), severity = try reader.u8()
                let message = try reader.usVarChar(), server = try reader.bVarChar(), procedure = try reader.bVarChar()
                let line = try reader.u32()
                value = "\(number), state \(state), severity \(severity): \(quoted(message))"
                    + (procedure.isEmpty ? "" : " in \(procedure)") + " line \(line)" + (server.isEmpty ? "" : " on \(server)")
            case 0xAD:
                _ = try reader.u16()
                let interface = try reader.u8(), version = try reader.u32BE()
                let program = try reader.bVarChar()
                let v = try reader.take(4)
                value = "\(interface == 1 ? "SQL" : "interface \(interface)"), " + String(format: "0x%08X", version)
                    + (Self.tdsVersions[version].map { " \($0)" } ?? "") + ", \(quoted(program)) \(v[0]).\(v[1]).\(Int(v[2]) << 8 | Int(v[3]))"
            case 0xAE:
                while true {
                    let featureAt = reader.offset
                    let id = try reader.u8()
                    if id == 0xFF { break }
                    let data = try reader.take(Int(try reader.u32()))
                    children.append(TDSField(Self.featureNames[id] ?? String(format: "feature 0x%02X", id), offset: featureAt,
                                             length: reader.offset - featureAt, value: data.hex()))
                }
            case 0x79:
                value = "\(Int32(bitPattern: try reader.u32()))"
            case 0xAC:
                let ordinal = try reader.u16()
                let name = try reader.bVarChar()
                let status = try reader.u8()
                _ = try reader.u32()
                _ = try reader.u16()
                let (type, typeField) = try typeInfo(&reader, inColumnMetadata: true)
                children = [typeField, try self.value(&reader, of: type)]
                value = "parameter \(ordinal) \(name.isEmpty ? "" : name)" + (status == 0x02 ? " (UDF return value)" : "")
            case 0xA9, 0xA5, 0xA4, 0xED:
                let data = try reader.take(Int(try reader.u16()))
                value = token == 0xA9 ? "columns " + stride(from: 0, to: data.count - 1, by: 2).map { "\(Int(data[$0]) | Int(data[$0 + 1]) << 8)" }.joined(separator: ", ")
                    : data.hex()
            case 0xE4, 0xEE:
                value = try reader.take(Int(try reader.u32())).hex()
            case 0x78:
                value = "identifier \(try reader.u16()), length \(try reader.u16())"
            default:
                throw Unknown(what: "\(name) (no decoder yet)", offset: at)
            }
            fields.append(TDSField(String(format: "%@ (0x%02X)", name, token), offset: at, length: reader.offset - at, value: value, children: children))
        }
        return fields
    }

    private func environmentChange(_ body: inout TDSByteReader) throws -> String {
        let type = try body.u8()
        let names: [UInt8: String] = [1: "database", 2: "language", 3: "character set", 4: "packet size", 5: "Unicode sorting LCID",
                                      6: "Unicode comparison flags", 7: "SQL collation", 8: "begin transaction", 9: "commit transaction",
                                      10: "rollback transaction", 11: "enlist DTC transaction", 12: "defect transaction",
                                      13: "database mirroring partner", 15: "promote transaction", 16: "transaction manager address",
                                      17: "transaction ended", 18: "reset connection acknowledged", 19: "user instance name", 20: "routing"]
        let name = names[type] ?? "type \(type)"
        switch type {
        case 1, 2, 3, 4, 5, 6, 13, 19:
            let new = try body.bVarChar(), old = try body.bVarChar()
            return "\(name): \(quoted(new))" + (old.isEmpty ? "" : " (was \(quoted(old)))")
        case 7, 8, 9, 10, 11, 12, 16, 17, 18:
            let new = try body.take(Int(try body.u8())), old = try body.take(Int(try body.u8()))
            return "\(name): \(new.isEmpty ? "-" : new.hex())" + (old.isEmpty ? "" : " (was \(old.hex()))")
        case 20:
            _ = try body.u16()
            let `protocol` = try body.u8(), port = try body.u16(), server = try body.usVarChar()
            _ = try body.u16()
            return "\(name): \(`protocol` == 0 ? "TCP" : "protocol \(`protocol`)") \(server):\(port)"
        default:
            return "\(name): \(try body.take(body.remaining).hex())"
        }
    }
}
