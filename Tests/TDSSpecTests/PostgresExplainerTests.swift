import Foundation
import Testing
@testable import PostgresProtocol
import WireExplanation

@Suite struct PostgresExplainerTests {
    func message(_ type: Character, _ body: [UInt8]) -> [UInt8] {
        let length = UInt32(body.count + 4)
        return [UInt8(type.asciiValue!), UInt8(length >> 24), UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)] + body
    }
    func cString(_ text: String) -> [UInt8] { Array(text.utf8) + [0] }
    func be16(_ value: Int) -> [UInt8] { [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }
    func be32(_ value: Int) -> [UInt8] { [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }

    @Test func startupShowsItsParameters() {
        let body = be32(196_608) + cString("user") + cString("postgres") + cString("database") + cString("labdata") + [0]
        let startup = be32(body.count + 4) + body
        let explanation = PostgresExplainer().explainUntyped(startup)
        #expect(explanation.problems.isEmpty, "\(explanation.problems)")
        #expect(explanation.structure == "StartupMessage")
        #expect(explanation.text.contains("protocol (4B): 3.0") && explanation.text.contains("'labdata'"))
    }

    @Test func rowsDecodeTextAndBinaryByType() {
        var explainer = PostgresExplainer()
        // RowDescription: id int4 (binary via Bind), name text, price numeric.
        var description = be16(3)
        for (name, oid) in [("id", 23), ("name", 25), ("price", 1700)] {
            description += cString(name) + be32(0) + be16(0) + be32(oid) + be16(4) + be32(-1) + be16(0)
        }
        #expect(explainer.explain(message("T", description), fromClient: false).problems.isEmpty)
        // Bind asking for binary results.
        let bind = cString("") + cString("") + be16(0) + be16(0) + be16(1) + be16(1)
        #expect(explainer.explain(message("B", bind), fromClient: true).problems.isEmpty)
        // numeric 12.50: ndigits 2, weight 0, sign +, dscale 2, digits 12, 5000.
        let numeric = be16(2) + be16(0) + be16(0) + be16(2) + be16(12) + be16(5000)
        let row = be16(3) + be32(4) + be32(42) + be32(2) + Array("ab".utf8) + be32(numeric.count) + numeric
        let explanation = explainer.explain(message("D", row), fromClient: false)
        #expect(explanation.problems.isEmpty, "\(explanation.problems)")
        #expect(explanation.text.contains("id (8B): 42"))
        #expect(explanation.text.contains("price (16B): 12.50"))
    }

    @Test func passwordsAndProofsAreNeverShown() {
        var explainer = PostgresExplainer()
        _ = explainer.explain(message("R", be32(3)), fromClient: false)
        let password = explainer.explain(message("p", cString("Secret123")), fromClient: true)
        #expect(password.structure == "PasswordMessage")
        #expect(!password.text.contains("Secret123"))
    }

    @Test func errorsListTheirFields() {
        let body: [UInt8] = [UInt8(ascii: "S")] + cString("ERROR") + [UInt8(ascii: "C")] + cString("42P01") + [UInt8(ascii: "M")] + cString("relation does not exist") + [0]
        var explainer = PostgresExplainer()
        let explanation = explainer.explain(message("E", body), fromClient: false)
        #expect(explanation.problems.isEmpty)
        #expect(explanation.text.contains("SQLSTATE") && explanation.text.contains("42P01"))
    }

    @Test func binaryTypes() {
        #expect(PostgresTypes.binary([0, 0, 0, 0], oid: 1082) == "2000-01-01")
        #expect(PostgresTypes.binary([0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF], oid: 1184) == "infinity")
        #expect(PostgresTypes.binary([0x80, 0, 0, 0, 0, 0, 0, 0], oid: 1114) == "-infinity")
        #expect(PostgresTypes.binary([0x7F, 0xFF, 0xFF, 0xFF], oid: 1082) == "infinity")
        #expect(PostgresTypes.binary([0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0, 0, 1, 2, 3, 4, 5, 6, 7], oid: 2950) == "12345678-9abc-def0-0001-020304050607")
        // -0.05: ndigits 1, weight -1, sign -, dscale 2, digit 500.
        #expect(PostgresTypes.numeric([0, 1, 0xFF, 0xFF, 0x40, 0, 0, 2, 0x01, 0xF4]) == "-0.05")
    }
}
