import Foundation
@testable import ServerLabKit
import Testing

@Suite struct WireDecodingTests {
    private let us = "\u{1F}"

    @Test func tdsBatchAndRPCWithEndOfMessage() {
        let output = [
            "0.01\t1433\t18\t1\t\t\t\t\t",
            "0.20\t1433\t1\t1\tSELECT 1\t\t\t\t",
            "0.21\t50000\t4\t1\t\t\t\t\t",
            "0.30\t1433\t3\(us)3\t0\(us)1\t\t\tsp_executesql\(us)\t\t\t",
        ].joined(separator: "\n")
        let messages = WireDecoding.messages(fromTSharkFields: output, serverPort: 1433)
        #expect(messages.map(\.kind) == ["Pre-login", "SQL batch", "Tabular result", "Remote Procedure Call", "Remote Procedure Call"])
        #expect(messages[1].text == "SELECT 1")
        #expect(messages[2].toServer == false)
        #expect(messages.requests.count == 3)
        #expect(messages.roundTrips(containing: "SELECT 1") == 1)
    }

    @Test func postgresExtendedProtocolCountsOneRoundTripPerSync() {
        let output = "0.5\t5432\t\t\t\t\t\tParse\(us)Bind\(us)Execute\(us)Sync\tSELECT $1::int\n0.6\t40000\t\t\t\t\t\tParse completion\(us)Bind completion\(us)Data row\(us)Ready for query\t"
        let messages = WireDecoding.messages(fromTSharkFields: output, serverPort: 5432)
        #expect(messages.filter(\.toServer).map(\.kind) == ["Parse", "Bind", "Execute", "Sync"])
        #expect(messages.first?.text == "SELECT $1::int")
        #expect(messages.roundTrips(containing: "SELECT $1") == 1)
    }
}

@Suite struct MySQLWireDecodingTests {
    @Test func commandsAndResponses() {
        // time, dstport, 7 TDS/PostgreSQL fields left empty, mysql.command, mysql.query, mysql.response_code
        let output = "0.007\t3306\t\t\t\t\t\t\t\t3\tSELECT 42\t\n0.008\t51234\t\t\t\t\t\t\t\t\t\t0"
        let messages = WireDecoding.messages(fromTSharkFields: output, serverPort: 3306)
        #expect(messages.map(\.kind) == ["COM_QUERY", "OK"])
        #expect(messages.first?.text == "SELECT 42")
        #expect(messages.requests.count == 1)
    }
}
