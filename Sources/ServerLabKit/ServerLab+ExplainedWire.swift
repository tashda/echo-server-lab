import Foundation
import TDSSpec
import WireExplanation

/// One protocol message from a capture, decoded by the lab's own decoders (not Wireshark's).
public struct ExplainedMessage: Sendable, Hashable, Codable {
    /// Seconds since the capture started (of the message's first packet).
    public var time: Double
    public var toServer: Bool
    /// What it is: `PRELOGIN`, `LOGIN7`, `SQL batch`, `Tabular result`, `Parse`, `DataRow`, `TLS (encrypted)`, ….
    public var kind: String
    /// Every packet of the message, headers included.
    public var bytes: [UInt8]
    public var explanation: WireExplanation
}

extension Array where Element == ExplainedMessage {
    /// Everything the decoder could not match to MS-TDS, with where it was.
    public var specProblems: [String] {
        flatMap { message in
            message.explanation.problems.map { "\(message.toServer ? "→" : "←") \(message.kind) at \(String(format: "%.3f", message.time))s: \($0)" }
        }
    }
}

extension ServerLab {
    /// The captured traffic of a server as whole protocol messages (TDS or PostgreSQL) explained
    /// field by field by the lab's own decoders (TDS, PostgreSQL, MySQL). Encrypted parts show as TLS records.
    public func explainedWire(of server: LabServer) async throws -> [ExplainedMessage] {
        let output = try await docker.run(
            ["run", "--rm", "--volume", "\(capturesDirectory):/captures:ro", Self.captureImage,
             "tshark", "-r", "/captures/\(server.containerName).pcap", "-Y", "tcp.len > 0", "-T", "fields",
             "-E", "separator=\t", "-e", "frame.time_relative", "-e", "tcp.dstport", "-e", "tcp.stream", "-e", "tcp.payload"]
        )
        switch server.engine {
        case .sqlServer: return TDSStreamReassembly.messages(fromTSharkFields: output, serverPort: server.engine.internalPort)
        case .postgres: return PostgresStreamReassembly.messages(fromTSharkFields: output, serverPort: server.engine.internalPort)
        case .mysql, .mariadb: return MySQLStreamReassembly.messages(fromTSharkFields: output, serverPort: server.engine.internalPort)
        }
    }
}

/// Rebuilds TDS messages from TCP payloads, per connection and direction. Separate from Docker so
/// it can be tested.
public enum TDSStreamReassembly {
    struct Direction {
        var buffer: [UInt8] = []
        var message: [UInt8] = []
        var packets: [UInt8] = []
        var messageType: UInt8 = 0
        var started: Double = 0
        var explainer = TDSExplainer()
    }

    public static func messages(fromTSharkFields output: String, serverPort: Int) -> [ExplainedMessage] {
        var directions: [String: Direction] = [:]
        var result: [ExplainedMessage] = []
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 4, let bytes = TDSExplainer.bytes(fromHex: fields[3].replacingOccurrences(of: ":", with: "")) else { continue }
            let time = Double(fields[0]) ?? 0
            let toServer = Int(fields[1]) == serverPort
            let key = "\(fields[2])-\(toServer)"
            var direction = directions[key] ?? Direction()
            direction.buffer += bytes
            result += drain(&direction, time: time, toServer: toServer)
            directions[key] = direction
        }
        return result
    }

    static func drain(_ direction: inout Direction, time: Double, toServer: Bool) -> [ExplainedMessage] {
        var messages: [ExplainedMessage] = []
        while true {
            let buffer = direction.buffer
            // Raw TLS records: login-only encryption, a fully encrypted session, or TDS 8 strict.
            if buffer.count >= 5, (0x14...0x17).contains(buffer[0]), buffer[1] == 0x03, direction.message.isEmpty {
                let length = 5 + (Int(buffer[3]) << 8 | Int(buffer[4]))
                guard buffer.count >= length else { break }
                let record = Array(buffer[..<length])
                direction.buffer.removeFirst(length)
                let kind = [0x14: "change cipher spec", 0x15: "alert", 0x16: "handshake", 0x17: "application data"][Int(record[0])] ?? "record"
                messages.append(ExplainedMessage(time: time, toServer: toServer, kind: "TLS (encrypted)", bytes: record,
                                                 explanation: TDSExplanation(structure: "TLS \(kind)", byteCount: length, fields: [], problems: [])))
                continue
            }
            guard buffer.count >= 8 else { break }
            let length = Int(buffer[2]) << 8 | Int(buffer[3])
            guard length >= 8, buffer.count >= length else {
                if length < 8 {
                    messages.append(ExplainedMessage(time: time, toServer: toServer, kind: "unreadable", bytes: buffer,
                                                     explanation: TDSExplanation(structure: "bytes", byteCount: buffer.count, fields: [],
                                                                                 problems: ["Not a TDS packet: \(buffer.hex())"])))
                    direction.buffer = []
                }
                break
            }
            let packet = Array(buffer[..<length])
            direction.buffer.removeFirst(length)
            if direction.message.isEmpty && direction.packets.isEmpty {
                direction.started = time
                direction.messageType = packet[0]
            }
            direction.packets += packet
            direction.message += packet[8...]
            guard packet[1] & 0x01 != 0 else { continue }
            // A server's pre-login answer is type 0x04 in pre-login format (its first option is VERSION, 0x00).
            var type = direction.messageType
            if type == 0x04, direction.message.first == 0x00, !toServer { type = 0x12 }
            let explanation = direction.explainer.explainMessage(type: type, payload: direction.message, toServer: toServer, base: 0)
            messages.append(ExplainedMessage(time: direction.started, toServer: toServer, kind: explanation.structure,
                                             bytes: direction.packets, explanation: explanation))
            direction.message = []
            direction.packets = []
        }
        return messages
    }
}

extension Array where Element == UInt8 {
    func hex() -> String { prefix(32).map { String(format: "%02X", $0) }.joined(separator: " ") + (count > 32 ? " …" : "") }
}
