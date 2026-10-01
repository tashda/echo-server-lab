import Testing
@testable import MySQLProtocol
import WireExplanation

@Suite struct MySQLExplainerTests {
    func packet(_ sequence: UInt8, _ payload: [UInt8]) -> [UInt8] {
        [UInt8(payload.count & 0xFF), UInt8(payload.count >> 8 & 0xFF), UInt8(payload.count >> 16), sequence] + payload
    }
    func lenenc(_ text: String) -> [UInt8] { [UInt8(text.utf8.count)] + Array(text.utf8) }

    @Test func queryResultWithTextRows() {
        var explainer = MySQLExplainer()
        explainer.expecting = .command
        explainer.deprecateEOF = true
        let query = explainer.explain(packet(0, [0x03] + Array("SELECT id, name FROM t".utf8)), fromClient: true)
        #expect(query.structure == "COM_QUERY" && query.problems.isEmpty)
        #expect(explainer.explain(packet(1, [0x02]), fromClient: false).structure == "column count")
        for (index, (name, type)) in [("id", UInt8(0x08)), ("name", UInt8(0xFD))].enumerated() {
            let definition = lenenc("def") + lenenc("labdata") + lenenc("t") + lenenc("t") + lenenc(name) + lenenc(name)
                + [0x0C, 0x21, 0x00, 0x14, 0, 0, 0, type, 0x01, 0x00, 0x00, 0x00, 0x00]
            let explanation = explainer.explain(packet(UInt8(2 + index), definition), fromClient: false)
            #expect(explanation.problems.isEmpty, "\(explanation.problems)")
        }
        let row = explainer.explain(packet(4, lenenc("7") + [0xFB]), fromClient: false)
        #expect(row.structure == "text row" && row.text.contains("id (2B): 7") && row.text.contains("name (1B): NULL"))
        let end = explainer.explain(packet(5, [0xFE, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00]), fromClient: false)
        #expect(end.structure == "OK (end of rows)" && end.problems.isEmpty)
        #expect(explainer.expecting == .command)
    }

    @Test func errorsShowCodeAndState() {
        var explainer = MySQLExplainer()
        explainer.expecting = .response(binary: false)
        let error = explainer.explain(packet(1, [0xFF, 0x7A, 0x04, 0x23] + Array("42S02Table 'x' doesn't exist".utf8)), fromClient: false)
        #expect(error.text.contains("1146 (42S02)"))
    }
}
