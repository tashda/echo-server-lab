import Foundation
import MySQLProtocol
import WireExplanation

/// Rebuilds MySQL protocol packets from TCP payloads, per connection. Separate from Docker so it
/// can be tested.
public enum MySQLStreamReassembly {
    struct Connection {
        var explainer = MySQLExplainer()
        var client: [UInt8] = []
        var server: [UInt8] = []
        /// After an SSLRequest, both directions carry TLS records.
        var encrypted = false
    }

    public static func messages(fromTSharkFields output: String, serverPort: Int) -> [ExplainedMessage] {
        var connections: [String: Connection] = [:]
        var result: [ExplainedMessage] = []
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 4, let bytes = PostgresStreamReassembly.hexBytes(fields[3]) else { continue }
            let time = Double(fields[0]) ?? 0
            let fromClient = Int(fields[1]) == serverPort
            var connection = connections[fields[2]] ?? Connection()
            if fromClient { connection.client += bytes } else { connection.server += bytes }
            result += drain(&connection, fromClient: fromClient, time: time)
            connections[fields[2]] = connection
        }
        return result
    }

    static func drain(_ connection: inout Connection, fromClient: Bool, time: Double) -> [ExplainedMessage] {
        var messages: [ExplainedMessage] = []
        while true {
            var buffer = fromClient ? connection.client : connection.server
            defer { if fromClient { connection.client = buffer } else { connection.server = buffer } }
            if connection.encrypted {
                guard buffer.count >= 5 else { break }
                let length = 5 + (Int(buffer[3]) << 8 | Int(buffer[4]))
                guard buffer.count >= length else { break }
                let record = Array(buffer[..<length])
                buffer.removeFirst(length)
                messages.append(ExplainedMessage(time: time, toServer: fromClient, kind: "TLS (encrypted)", bytes: record,
                                                 explanation: WireExplanation(structure: "TLS (encrypted)", byteCount: length, fields: [], problems: [])))
                continue
            }
            guard buffer.count >= 4 else { break }
            let length = 4 + (Int(buffer[0]) | Int(buffer[1]) << 8 | Int(buffer[2]) << 16)
            guard buffer.count >= length else { break }
            let packet = Array(buffer[..<length])
            buffer.removeFirst(length)
            let explanation = connection.explainer.explain(packet, fromClient: fromClient)
            if explanation.structure == "SSLRequest" { connection.encrypted = true }
            messages.append(ExplainedMessage(time: time, toServer: fromClient, kind: explanation.structure, bytes: packet, explanation: explanation))
        }
        return messages
    }
}
