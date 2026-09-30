import Foundation

/// Decodes TDS bytes field by field against MS-TDS: packets, client messages and server token
/// streams. It keeps the last COLMETADATA, so a capture's rows decode with their columns.
public struct TDSExplainer: Sendable {
    let spec: TDSSpecification
    /// The columns of the result being read (from the last COLMETADATA).
    var columns: [(name: String, type: TDSTypeInfo)] = []

    public init(spec: TDSSpecification = .shared) {
        self.spec = spec
    }

    struct Unknown: Error, CustomStringConvertible {
        var what: String, offset: Int
        var description: String { "\(what) at +\(offset) is not in the spec" }
    }

    static let packetTypes: [UInt8: String] = [
        0x01: "SQL batch", 0x02: "Pre-TDS7 login", 0x03: "RPC", 0x04: "Tabular result", 0x06: "Attention",
        0x07: "Bulk load", 0x08: "Federated authentication token", 0x0E: "Transaction manager request",
        0x10: "TDS7 login", 0x11: "SSPI", 0x12: "Pre-login",
    ]

    /// Parses `0401…` or `04 01 …` into bytes; nil when it is not hex.
    public static func bytes(fromHex text: String) -> [UInt8]? {
        let digits = text.filter { !$0.isWhitespace && $0 != "," }.replacingOccurrences(of: "0x", with: "")
        guard digits.count % 2 == 0, !digits.isEmpty else { return nil }
        var bytes: [UInt8] = []
        var index = digits.startIndex
        while index < digits.endIndex {
            let next = digits.index(index, offsetBy: 2)
            guard let byte = UInt8(digits[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    /// Explains bytes as `packet` (with its 8-byte header), a message (`prelogin`, `login7`,
    /// `sqlbatch`, `rpc`), `tokens`, or one token by name.
    public func explain(_ bytes: [UInt8], as structure: String = "packet") -> TDSExplanation {
        var explainer = self
        let key = structure.lowercased().filter { $0.isLetter || $0.isNumber }
        switch key {
        case "", "packet", "packetheader", "tdspacket":
            return explainer.explainPacket(bytes)
        case "prelogin": return explainer.explainMessage(type: 0x12, payload: bytes, toServer: true, base: 0)
        case "login7", "login": return explainer.explainMessage(type: 0x10, payload: bytes, toServer: true, base: 0)
        case "sqlbatch", "batch": return explainer.explainMessage(type: 0x01, payload: bytes, toServer: true, base: 0)
        case "rpc": return explainer.explainMessage(type: 0x03, payload: bytes, toServer: true, base: 0)
        default:
            // "tokens", "tabular result" or a token name: a token stream.
            return explainer.explainMessage(type: 0x04, payload: bytes, toServer: false, base: 0)
        }
    }

    /// A whole packet: the header, then its payload as the message type says.
    public mutating func explainPacket(_ bytes: [UInt8]) -> TDSExplanation {
        guard bytes.count >= 8 else {
            return TDSExplanation(structure: "TDS packet", byteCount: bytes.count, fields: [],
                                  problems: ["A packet header is 8 bytes; got \(bytes.count)"])
        }
        let type = bytes[0], status = bytes[1]
        let length = Int(UInt16(bytes[2]) << 8 | UInt16(bytes[3]))
        var statusNames = [(0x01, "EOM"), (0x02, "ignore"), (0x08, "reset connection"), (0x10, "reset connection, keep transaction")]
            .filter { Int(status) & $0.0 != 0 }.map(\.1)
        if statusNames.isEmpty { statusNames = ["normal"] }
        let header = TDSField("packet header", offset: 0, length: 8, children: [
            TDSField("type", offset: 0, length: 1, value: String(format: "0x%02X %@", type, Self.packetTypes[type] ?? "unknown")),
            TDSField("status", offset: 1, length: 1, value: String(format: "0x%02X %@", status, statusNames.joined(separator: ", "))),
            TDSField("length", offset: 2, length: 2, value: "\(length) (big-endian, header included)"),
            TDSField("SPID", offset: 4, length: 2, value: "\(UInt16(bytes[4]) << 8 | UInt16(bytes[5]))"),
            TDSField("packet ID", offset: 6, length: 1, value: "\(bytes[6])"),
            TDSField("window", offset: 7, length: 1, value: "\(bytes[7])"),
        ])
        var problems: [String] = []
        if length != bytes.count { problems.append("Header length \(length) but \(bytes.count) bytes given") }
        let end = min(max(length, 8), bytes.count)
        let payload = Array(bytes[8..<end])
        // A server's pre-login answer is packet type 0x04 in pre-login format (its first option is VERSION, 0x00).
        let messageType: UInt8 = type == 0x04 && payload.first == 0x00 ? 0x12 : type
        var message = explainMessage(type: messageType, payload: payload, toServer: type != 0x04, base: 8)
        message.fields.insert(header, at: 0)
        message.problems = problems + message.problems
        message.byteCount = bytes.count
        message.structure = "TDS packet: " + message.structure
        return message
    }

    /// A message payload (all packets of it joined, headers removed).
    public mutating func explainMessage(type: UInt8, payload: [UInt8], toServer: Bool, base: Int) -> TDSExplanation {
        var reader = TDSByteReader(payload, base: base)
        var fields: [TDSField] = []
        var problems: [String] = []
        let name: String
        do {
            switch type {
            case 0x12:
                name = "PRELOGIN"
                if let first = payload.first, [0x14, 0x15, 0x16, 0x17].contains(first), payload.count > 1, payload[1] == 0x03 {
                    fields.append(TDSField("TLS records (handshake inside pre-login packets)", offset: base, length: payload.count,
                                           value: tlsRecords(payload)))
                    reader.position = payload.count
                } else {
                    fields += try prelogin(&reader)
                }
            case 0x10:
                name = "LOGIN7"
                fields += try login7(&reader)
            case 0x01:
                name = "SQL batch"
                fields += try allHeaders(&reader)
                let at = reader.offset
                let text = try reader.ucs2(reader.remaining / 2)
                fields.append(TDSField("SQL text", offset: at, length: reader.offset - at, value: quoted(text, limit: 400)))
            case 0x03:
                name = "RPC"
                fields += try allHeaders(&reader)
                fields += try rpc(&reader)
            case 0x06:
                name = "Attention"
            case 0x04:
                name = "Tabular result"
                fields += try tokens(&reader, problems: &problems)
            default:
                name = Self.packetTypes[type] ?? String(format: "message type 0x%02X", type)
                fields.append(TDSField("payload", offset: base, length: payload.count, value: payload.hex()))
                reader.position = payload.count
            }
        } catch {
            return TDSExplanation(structure: Self.packetTypes[type] ?? "message", byteCount: payload.count, fields: fields,
                                  problems: problems + ["\(error)"])
        }
        if !reader.isAtEnd {
            problems.append("\(reader.remaining) bytes left at +\(reader.offset): \(Array(payload[reader.position...]).hex())")
        }
        return TDSExplanation(structure: name, byteCount: payload.count, fields: fields, problems: problems)
    }

    private func tlsRecords(_ payload: [UInt8]) -> String {
        var index = 0, kinds: [String] = []
        let names: [UInt8: String] = [0x14: "change cipher spec", 0x15: "alert", 0x16: "handshake", 0x17: "application data"]
        while index + 5 <= payload.count {
            let length = Int(UInt16(payload[index + 3]) << 8 | UInt16(payload[index + 4]))
            kinds.append(names[payload[index]] ?? String(format: "0x%02X", payload[index]))
            index += 5 + length
        }
        return kinds.joined(separator: ", ")
    }

    // MARK: - PRELOGIN

    private func prelogin(_ reader: inout TDSByteReader) throws -> [TDSField] {
        let names: [UInt8: String] = [0: "VERSION", 1: "ENCRYPTION", 2: "INSTOPT", 3: "THREADID", 4: "MARS", 5: "TRACEID",
                                      6: "FEDAUTHREQUIRED", 7: "NONCEOPT"]
        var options: [(token: UInt8, offset: Int, length: Int, at: Int)] = []
        var table: [TDSField] = []
        while true {
            let at = reader.offset
            let token = try reader.u8()
            if token == 0xFF {
                table.append(TDSField("terminator", offset: at, length: 1, value: "0xFF"))
                break
            }
            let offset = Int(try reader.u16BE()), length = Int(try reader.u16BE())
            options.append((token, offset, length, at))
            table.append(TDSField(names[token] ?? String(format: "option 0x%02X", token), offset: at, length: 5,
                                  value: "data at \(offset), \(length) bytes"))
        }
        var fields = [TDSField("option table", offset: reader.base, length: reader.offset - reader.base, children: table)]
        for option in options {
            guard option.offset + option.length <= reader.bytes.count else {
                throw TDSByteReader.PastEnd(needed: option.length, offset: reader.base + option.offset, available: reader.bytes.count - option.offset)
            }
            let data = Array(reader.bytes[option.offset..<option.offset + option.length])
            let value: String
            switch option.token {
            case 0 where data.count >= 6:
                value = "\(data[0]).\(data[1]).\(Int(data[2]) << 8 | Int(data[3])), sub-build \(Int(data[4]) << 8 | Int(data[5]))"
            case 1 where data.count >= 1:
                let modes = [0: "ENCRYPT_OFF (login only)", 1: "ENCRYPT_ON", 2: "ENCRYPT_NOT_SUP", 3: "ENCRYPT_REQ"]
                // ENCRYPT_CLIENT_CERT is the 0x80 bit (0x80, 0x81, 0x83); 0x20 (ENCRYPT_EXT) is reserved.
                value = modes[Int(data[0] & 0x0F)].map { $0 + (data[0] & 0x80 != 0 ? ", ENCRYPT_CLIENT_CERT" : "") + (data[0] & 0x20 != 0 ? ", ENCRYPT_EXT" : "") }
                    ?? String(format: "0x%02X", data[0])
            case 2: value = quoted(String(decoding: data.prefix { $0 != 0 }, as: UTF8.self))
            case 4 where data.count >= 1: value = data[0] == 1 ? "on" : "off"
            case 6 where data.count >= 1: value = data[0] == 1 ? "required" : "not required"
            default: value = data.hex()
            }
            fields.append(TDSField(names[option.token] ?? String(format: "option 0x%02X", option.token),
                                   offset: reader.base + option.offset, length: option.length, value: value))
            reader.position = max(reader.position, option.offset + option.length)
        }
        return fields
    }

    // MARK: - LOGIN7

    private func login7(_ reader: inout TDSByteReader) throws -> [TDSField] {
        var fixed: [TDSField] = []
        func add(_ name: String, _ length: Int, _ render: ([UInt8]) -> String) throws {
            let at = reader.offset
            fixed.append(TDSField(name, offset: at, length: length, value: render(try reader.take(length))))
        }
        func le(_ b: [UInt8]) -> UInt32 { b.enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) } }
        let base = reader.position
        try add("length", 4) { "\(le($0))" }
        try add("TDS version", 4) { String(format: "0x%08X", le($0)) + (Self.tdsVersions[le($0)].map { " (\($0))" } ?? "") }
        try add("packet size", 4) { "\(le($0))" }
        try add("client program version", 4) { String(format: "0x%08X", le($0)) }
        try add("client PID", 4) { "\(le($0))" }
        try add("connection ID", 4) { "\(le($0))" }
        var optionFlags3: UInt8 = 0
        try add("option flags 1", 1) { String(format: "0x%02X", $0[0]) }
        try add("option flags 2", 1) { b in
            String(format: "0x%02X", b[0]) + (b[0] & 0x80 != 0 ? " (integrated security)" : "") + (b[0] & 0x02 != 0 ? " (ODBC)" : "")
        }
        try add("type flags", 1) { b in String(format: "0x%02X", b[0]) + (b[0] & 0x20 != 0 ? " (read-only intent)" : "") }
        try add("option flags 3", 1) { b in optionFlags3 = b[0]; return String(format: "0x%02X", b[0]) + (b[0] & 0x10 != 0 ? " (extension)" : "") }
        try add("client time zone", 4) { "\(Int32(bitPattern: le($0))) min" }
        try add("client LCID", 4) { String(format: "0x%08X", le($0)) }

        let names = ["host name", "user name", "password", "application name", "server name", "extension", "client interface",
                     "language", "database"]
        var variable: [TDSField] = []
        var extensionOffset: Int?
        for name in names {
            let at = reader.offset
            let offset = Int(try reader.u16()), count = Int(try reader.u16())
            if name == "extension" {
                if optionFlags3 & 0x10 != 0, count >= 4 { extensionOffset = offset }
                fixed.append(TDSField("extension offset", offset: at, length: 4, value: "at \(offset), \(count) bytes"))
                continue
            }
            let start = base + offset
            guard start + count * 2 <= reader.bytes.count else { throw TDSByteReader.PastEnd(needed: count * 2, offset: reader.base + start, available: 0) }
            let text: String
            if name == "password" {
                // Never shown: the obfuscation is reversible.
                text = count == 0 ? "(none)" : "(obfuscated, \(count) characters, not shown)"
            } else {
                text = quoted(TDSByteReader.ucs2(Array(reader.bytes[start..<start + count * 2])))
            }
            variable.append(TDSField(name, offset: reader.base + start, length: count * 2, value: text))
        }
        let idAt = reader.offset
        fixed.append(TDSField("client ID (MAC)", offset: idAt, length: 6, value: try reader.take(6).hex()))
        for name in ["SSPI", "attach database file", "change password"] {
            let at = reader.offset
            let offset = Int(try reader.u16()), count = Int(try reader.u16())
            if count > 0 || name != "SSPI" {
                let unit = name == "SSPI" ? "bytes" : "characters"
                let shown = name == "change password" && count > 0 ? "(not shown)" : "at \(offset), \(count) \(unit)"
                fixed.append(TDSField(name, offset: at, length: 4, value: shown))
            } else {
                fixed.append(TDSField(name, offset: at, length: 4, value: "none"))
            }
        }
        let longAt = reader.offset
        fixed.append(TDSField("SSPI long length", offset: longAt, length: 4, value: "\(try reader.u32())"))

        var fields = [TDSField("fixed part", offset: reader.base + base, length: reader.position - base, children: fixed),
                      TDSField("strings", offset: variable.first?.offset ?? reader.offset, length: 0, children: variable)]
        var end = variable.map { $0.offset + $0.length - reader.base }.max() ?? reader.position
        if let extensionOffset, base + extensionOffset + 4 <= reader.bytes.count {
            var pointer = TDSByteReader(Array(reader.bytes[(base + extensionOffset)...]), base: reader.base + base + extensionOffset)
            let featureOffset = Int(try pointer.u32())
            var features = TDSByteReader(Array(reader.bytes[(base + featureOffset)...]), base: reader.base + base + featureOffset)
            var list: [TDSField] = []
            while true {
                let at = features.offset
                let id = try features.u8()
                if id == 0xFF { list.append(TDSField("terminator", offset: at, length: 1, value: "0xFF")); break }
                let length = Int(try features.u32())
                let data = try features.take(length)
                list.append(TDSField(Self.featureNames[id] ?? String(format: "feature 0x%02X", id), offset: at, length: 5 + length,
                                     value: data.isEmpty ? "requested" : data.hex()))
            }
            fields.append(TDSField("FeatureExt", offset: features.base, length: features.position, children: list))
            end = max(end, base + featureOffset + features.position)
        }
        reader.position = max(reader.position, end)
        return fields
    }

    /// TDS versions as LOGIN7 (little-endian) and LOGINACK (big-endian) read them.
    static let tdsVersions: [UInt32: String] = [0x7400_0004: "TDS 7.4", 0x730B_0003: "TDS 7.3B", 0x730A_0003: "TDS 7.3A",
                                                0x7209_0002: "TDS 7.2", 0x7100_0001: "TDS 7.1", 0x7000_0000: "TDS 7.0",
                                                0x0800_0000: "TDS 8.0"]
    static let featureNames: [UInt8: String] = [0x01: "SESSIONRECOVERY", 0x02: "FEDAUTH", 0x04: "COLUMNENCRYPTION",
                                                0x05: "GLOBALTRANSACTIONS", 0x08: "AZURESQLSUPPORT", 0x09: "DATACLASSIFICATION",
                                                0x0A: "UTF8_SUPPORT", 0x0B: "AZURESQLDNSCACHING", 0x0D: "JSONSUPPORT",
                                                0x0E: "VECTORSUPPORT", 0x0F: "ENHANCEDROUTINGSUPPORT"]

    // MARK: - ALL_HEADERS and RPC

    private func allHeaders(_ reader: inout TDSByteReader) throws -> [TDSField] {
        guard reader.remaining >= 4 else { return [] }
        var probe = reader
        let total = Int(try probe.u32())
        // Present from TDS 7.2; a plausible total length says it is there.
        guard total >= 4, total <= reader.remaining, total < 1024 else { return [] }
        let at = reader.offset
        _ = try reader.u32()
        var headers: [TDSField] = []
        while reader.offset - at < total {
            let headerAt = reader.offset
            let length = Int(try reader.u32())
            let type = try reader.u16()
            let data = try reader.take(max(0, length - 6))
            let value: String
            switch type {
            case 1: value = "query notifications, \(data.count) bytes"
            case 2 where data.count >= 12:
                var body = TDSByteReader(data)
                value = String(format: "transaction descriptor 0x%016llX, outstanding requests %d", try body.u64(), try body.u32())
            case 3: value = "trace activity " + data.hex()
            default: value = "type \(type): " + data.hex()
            }
            headers.append(TDSField("header", offset: headerAt, length: length, value: value))
        }
        return [TDSField("ALL_HEADERS", offset: at, length: total, value: "\(total) bytes", children: headers)]
    }

    static let procedures: [UInt16: String] = [1: "sp_cursor", 2: "sp_cursoropen", 3: "sp_cursorprepare", 4: "sp_cursorexecute",
                                               5: "sp_cursorprepexec", 6: "sp_cursorunprepare", 7: "sp_cursorfetch", 8: "sp_cursoroption",
                                               9: "sp_cursorclose", 10: "sp_executesql", 11: "sp_prepare", 12: "sp_execute",
                                               13: "sp_prepexec", 14: "sp_prepexecrpc", 15: "sp_unprepare"]

    private func rpc(_ reader: inout TDSByteReader) throws -> [TDSField] {
        var fields: [TDSField] = []
        while !reader.isAtEnd {
            let at = reader.offset
            let nameLength = try reader.u16()
            let procedure: String
            if nameLength == 0xFFFF {
                let id = try reader.u16()
                procedure = "\(Self.procedures[id] ?? "procedure") (ProcID \(id))"
            } else {
                procedure = quoted(try reader.ucs2(Int(nameLength)))
            }
            let flags = try reader.u16()
            var request = [TDSField("procedure", offset: at, length: reader.offset - at - 2, value: procedure),
                           TDSField("option flags", offset: reader.offset - 2, length: 2, value: String(format: "0x%04X", flags))]
            while let next = reader.peek(), next != 0x80, next != 0xFF, next != 0xFE {
                let parameterAt = reader.offset
                let name = try reader.bVarChar()
                let status = try reader.u8()
                let (type, typeField) = try typeInfo(&reader, inColumnMetadata: false)
                let value = try value(&reader, of: type)
                let statusText = [(status & 0x01 != 0, "output"), (status & 0x02 != 0, "default")].filter(\.0).map(\.1).joined(separator: ", ")
                request.append(TDSField("parameter \(name.isEmpty ? "(unnamed)" : name)", offset: parameterAt, length: reader.offset - parameterAt,
                                        value: statusText, children: [typeField, value]))
            }
            fields.append(TDSField("request", offset: at, length: reader.offset - at, children: request))
            if let separator = reader.peek(), separator == 0x80 || separator == 0xFF || separator == 0xFE {
                _ = try reader.u8()
            }
        }
        return fields
    }
}
