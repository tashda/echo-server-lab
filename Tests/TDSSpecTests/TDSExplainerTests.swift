import Foundation
import Testing
@testable import TDSSpec

@Suite struct TDSToolTests {
    @Test(arguments: TDSTools.all.map(\.name))
    func everyToolAnswers(_ name: String) {
        let answer = TDSTools.call(name, arguments: ["query": "nvarchar", "name": "LOGIN7", "type_name": "nvarchar",
                                                     "category": "nvarchar", "feature": "JSON", "hex_bytes": "06 01 00 08 00 00 01 00"])
        #expect(!answer.isEmpty)
        #expect(!answer.hasPrefix("Unknown tool"))
    }

    @Test func tokensAndTypesAreFoundByNameAndByte() {
        #expect(TDSTools.call("get_token", arguments: ["query": "0xfd"]).contains("\"DONE\""))
        #expect(TDSTools.call("get_data_type", arguments: ["query": "0xe7"]).contains("nvarchar"))
        #expect(TDSSpecification.shared.dataType(code: 0xF4)?["name"]?.string == "json")
    }
}

@Suite struct TDSExplainerTests {
    let explainer = TDSExplainer()

    /// The §4 examples: whole packets decode with nothing left over; partial ones (the spec files
    /// often keep only the header) still decode their header.
    @Test func specExamplesDecode() throws {
        let examples = TDSSpecification.shared.examples["examples"]?.array ?? []
        var decoded = 0
        for example in examples {
            guard let hex = example["hex"]?.string, let bytes = TDSExplainer.bytes(fromHex: hex), bytes.count >= 8 else { continue }
            let explanation = explainer.explain(bytes)
            #expect(explanation.fields.first?.name == "packet header")
            if Int(bytes[2]) << 8 | Int(bytes[3]) == bytes.count {
                #expect(explanation.problems.isEmpty, "\(example["id"]?.string ?? ""): \(explanation.problems)")
            }
            decoded += 1
        }
        #expect(decoded >= 5)
    }

    @Test func preloginOptionsAndClientCertificateBit() throws {
        // VERSION 16.0.1000 sub 0, ENCRYPTION 0x81 (ON + client certificate), terminator.
        let payload: [UInt8] = [0x00, 0x00, 0x0B, 0x00, 0x06, 0x01, 0x00, 0x11, 0x00, 0x01, 0xFF,
                                0x10, 0x00, 0x03, 0xE8, 0x00, 0x00, 0x81]
        let explanation = explainer.explain(payload, as: "prelogin")
        #expect(explanation.problems.isEmpty, "\(explanation.problems)")
        #expect(explanation.text.contains("16.0.1000"))
        #expect(explanation.text.contains("ENCRYPT_ON, ENCRYPT_CLIENT_CERT"))
    }

    @Test func sqlBatchShowsItsText() throws {
        let sql = Array("SELECT 1".utf16).flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        let headers: [UInt8] = [0x16, 0, 0, 0, 0x12, 0, 0, 0, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0]
        let payload = headers + sql
        let packet: [UInt8] = [0x01, 0x01, 0, UInt8(8 + payload.count), 0, 0, 1, 0] + payload
        let explanation = explainer.explain(packet)
        #expect(explanation.problems.isEmpty)
        #expect(explanation.text.contains("'SELECT 1'"))
        #expect(explanation.text.contains("outstanding requests 1"))
    }

    @Test func columnsThenRowsThenDone() throws {
        // COLMETADATA: 2 columns: int NOT NULL "Id", nvarchar(10) "Name"; ROW 7, 'ab'; DONE count 1.
        let collation: [UInt8] = [0x09, 0x04, 0xD0, 0x00, 0x34]
        var tokens: [UInt8] = [0x81, 0x02, 0x00]
        tokens += [0, 0, 0, 0, 0x00, 0x00, 0x38, 0x02] + Array("Id".utf16).flatMap { [UInt8($0), 0] }
        tokens += [0, 0, 0, 0, 0x01, 0x00, 0xE7, 0x14, 0x00] + collation + [0x04] + Array("Name".utf16).flatMap { [UInt8($0), 0] }
        tokens += [0xD1, 0x07, 0, 0, 0, 0x04, 0x00, 0x61, 0x00, 0x62, 0x00]
        tokens += [0xD2, 0x02, 0x08, 0, 0, 0]  // NBCROW: Name NULL, Id 8
        tokens += [0xFD, 0x10, 0x00, 0xC1, 0x00, 0x02, 0, 0, 0, 0, 0, 0, 0]
        let explanation = explainer.explain(tokens, as: "tokens")
        #expect(explanation.problems.isEmpty, "\(explanation.problems)")
        let text = explanation.text
        #expect(text.contains("column 2 'Name'") && text.contains("nvarchar"))
        #expect(text.contains("Id (4B): 7") && text.contains("Name (6B): 'ab'"))
        #expect(text.contains("Name: NULL (bitmap)") && text.contains("Id (4B): 8"))
        #expect(text.contains("2 rows"))
    }

    @Test func login7NeverShowsThePassword() throws {
        func ucs2(_ text: String) -> [UInt8] { Array(text.utf16).flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] } }
        let strings = [("host", "mac"), ("user", "sa"), ("password", "Secret123"), ("app", "echo"), ("server", "db"),
                       ("extension", ""), ("interface", "nio"), ("language", ""), ("database", "master")]
        let fixedLength = 36 + 9 * 4 + 6 + 3 * 4 + 4
        var offset = fixedLength
        var table: [UInt8] = [], data: [UInt8] = []
        for (name, value) in strings {
            let bytes = name == "password" ? ucs2(value).map { (($0 << 4) | ($0 >> 4)) ^ 0xA5 } : ucs2(value)
            table += [UInt8(offset & 0xFF), UInt8(offset >> 8), UInt8(value.count), 0]
            data += bytes
            offset += bytes.count
        }
        let total = fixedLength + data.count
        var login: [UInt8] = [UInt8(total & 0xFF), UInt8(total >> 8), 0, 0, 0x04, 0, 0, 0x74, 0, 0x10, 0, 0]
        login += [UInt8](repeating: 0, count: 12) + [0xE0, 0x03, 0, 0] + [0, 0, 0, 0, 0x09, 0x04, 0, 0]
        login += table + [UInt8](repeating: 0, count: 6) + [UInt8](repeating: 0, count: 12) + [0, 0, 0, 0] + data
        let explanation = explainer.explain(login, as: "login7")
        #expect(explanation.problems.isEmpty, "\(explanation.problems)")
        #expect(explanation.text.contains("user name") && explanation.text.contains("'sa'"))
        #expect(explanation.text.contains("TDS 7.4"))
        #expect(explanation.text.contains("not shown"))
        #expect(!explanation.text.contains("Secret123"))
    }

    @Test func unknownTokensAreCalledOut() {
        let explanation = explainer.explain([0xFD, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x42], as: "tokens")
        #expect(explanation.problems.contains { $0.contains("0x42") })
    }

    @Test func datesAndDecimals() {
        #expect(TDSExplainer.civil(daysSince0001: 0) == "0001-01-01")
        #expect(TDSExplainer.civil(daysSince0001: TDSExplainer.days1900) == "1900-01-01")
        let decimal = TDSTypeInfo(code: 0x6A, name: "decimal", layout: .byteLength, maxLength: 5, precision: 9, scale: 2)
        #expect(explainer.render([0x01, 0x39, 0x30, 0x00, 0x00], as: decimal) == "123.45")
        #expect(explainer.render([0x00, 0x05, 0x00, 0x00, 0x00], as: decimal) == "-0.05")
    }
}
