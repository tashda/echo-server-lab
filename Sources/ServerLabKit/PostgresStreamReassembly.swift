import Foundation
import PostgresProtocol
import WireExplanation

/// Rebuilds PostgreSQL protocol messages from TCP payloads, per connection. Separate from Docker
/// so it can be tested.
public enum PostgresStreamReassembly {
    struct Connection {
        var explainer = PostgresExplainer()
        var client: [UInt8] = []
        var server: [UInt8] = []
        /// After StartupMessage, client messages carry a type byte.
        var started = false
        /// An SSLRequest or GSSENCRequest waits for its one-byte answer.
        var awaitingAnswer = false
        /// Everything after an accepted SSLRequest (or direct TLS) is TLS records.
        var encrypted = false
    }

    public static func messages(fromTSharkFields output: String, serverPort: Int) -> [ExplainedMessage] {
        var connections: [String: Connection] = [:]
        var result: [ExplainedMessage] = []
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 4, let bytes = hexBytes(fields[3]) else { continue }
            let time = Double(fields[0]) ?? 0
            let fromClient = Int(fields[1]) == serverPort
            var connection = connections[fields[2]] ?? Connection()
            if fromClient { connection.client += bytes } else { connection.server += bytes }
            result += drain(&connection, fromClient: fromClient, time: time)
            connections[fields[2]] = connection
        }
        return result
    }

    static func hexBytes(_ text: String) -> [UInt8]? {
        let digits = Array(text.replacingOccurrences(of: ":", with: "").utf8)
        guard digits.count % 2 == 0, !digits.isEmpty else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(digits.count / 2)
        var index = 0
        while index < digits.count {
            guard let byte = UInt8(String(decoding: digits[index..<index + 2], as: UTF8.self), radix: 16) else { return nil }
            bytes.append(byte)
            index += 2
        }
        return bytes
    }

    static func drain(_ connection: inout Connection, fromClient: Bool, time: Double) -> [ExplainedMessage] {
        var messages: [ExplainedMessage] = []
        func emit(_ bytes: [UInt8], _ explanation: WireExplanation) {
            messages.append(ExplainedMessage(time: time, toServer: fromClient, kind: explanation.structure, bytes: bytes, explanation: explanation))
        }
        while true {
            var buffer = fromClient ? connection.client : connection.server
            defer { if fromClient { connection.client = buffer } else { connection.server = buffer } }
            // TLS records: after an accepted SSLRequest, or direct TLS from the first byte (PostgreSQL 17+).
            if connection.encrypted || (!connection.started && fromClient && buffer.count >= 2 && buffer[0] == 0x16 && buffer[1] == 0x03) {
                connection.encrypted = true
                guard buffer.count >= 5 else { break }
                let length = 5 + (Int(buffer[3]) << 8 | Int(buffer[4]))
                guard buffer.count >= length else { break }
                let record = Array(buffer[..<length])
                buffer.removeFirst(length)
                emit(record, WireExplanation(structure: "TLS (encrypted)", byteCount: length, fields: [], problems: []))
                continue
            }
            if !fromClient, connection.awaitingAnswer {
                guard let answer = buffer.first else { break }
                buffer.removeFirst()
                connection.awaitingAnswer = false
                let meaning = ["S": "TLS follows", "G": "GSSAPI encryption follows", "N": "no; continue in plain text"][Character(UnicodeScalar(answer))] ?? "?"
                emit([answer], WireExplanation(structure: "SSL/GSS answer", byteCount: 1,
                                               fields: [WireField("answer", offset: 0, length: 1, value: "'\(String(UnicodeScalar(answer)))' \(meaning)")],
                                               problems: meaning == "?" ? ["Unexpected answer byte \(answer)"] : []))
                if answer == 0x53 || answer == 0x47 { connection.encrypted = true }
                continue
            }
            if fromClient, !connection.started {
                guard buffer.count >= 8 else { break }
                let length = Int(UInt32(buffer[0]) << 24 | UInt32(buffer[1]) << 16 | UInt32(buffer[2]) << 8 | UInt32(buffer[3]))
                guard length >= 8, buffer.count >= length else { if length < 8 { buffer = [] }; break }
                let message = Array(buffer[..<length])
                buffer.removeFirst(length)
                let explanation = connection.explainer.explainUntyped(message)
                switch explanation.structure {
                case "SSLRequest", "GSSENCRequest": connection.awaitingAnswer = true
                case "StartupMessage": connection.started = true
                default: break
                }
                emit(message, explanation)
                continue
            }
            guard buffer.count >= 5 else { break }
            let length = 1 + Int(UInt32(buffer[1]) << 24 | UInt32(buffer[2]) << 16 | UInt32(buffer[3]) << 8 | UInt32(buffer[4]))
            guard length >= 5 else {
                emit(buffer, WireExplanation(structure: "unreadable", byteCount: buffer.count, fields: [],
                                             problems: ["Not a PostgreSQL message: \(buffer.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " "))"]))
                buffer = []
                break
            }
            guard buffer.count >= length else { break }
            let message = Array(buffer[..<length])
            buffer.removeFirst(length)
            emit(message, connection.explainer.explain(message, fromClient: fromClient))
        }
        return messages
    }
}
