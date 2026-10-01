import Foundation

/// Puts captured TCP payloads in sequence order per connection and direction before the protocol
/// decoders see them: retransmitted copies are dropped, overlapping ones trimmed, and a segment
/// that arrives early waits for the gap before it. Busy hosts retransmit; without this a decoder
/// reads a repeated stretch of bytes as the start of a message.
public enum TCPSegmentOrdering {
    /// Input lines: time, destination port, stream, sequence number (relative), payload (hex).
    /// Output lines: time, destination port, stream, payload (hex): what the decoders read.
    public static func ordered(fromTSharkFields output: String) -> String {
        struct Flow {
            var next: Int?
            var pending: [Int: (time: String, port: String, payload: [UInt8])] = [:]
        }
        var flows: [String: Flow] = [:]
        var lines: [String] = []

        func emit(_ time: String, _ port: String, _ stream: String, _ payload: [UInt8]) {
            lines.append("\(time)\t\(port)\t\(stream)\t\(payload.map { String(format: "%02x", $0) }.joined())")
        }

        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 5, let seq = Int(fields[3]) else { continue }
            let payload = bytes(fromHex: fields[4].replacingOccurrences(of: ":", with: ""))
            guard !payload.isEmpty else { continue }
            let key = "\(fields[2])-\(fields[1])"
            var flow = flows[key] ?? Flow()
            let next = flow.next ?? seq
            if seq + payload.count <= next {
                // A copy of bytes already passed on.
            } else if seq > next {
                flow.pending[seq] = (fields[0], fields[1], payload)
                if flow.next == nil { flow.next = seq }
            } else {
                let fresh = Array(payload[(next - seq)...])
                emit(fields[0], fields[1], fields[2], fresh)
                flow.next = next + fresh.count
                // Segments that were waiting for this one.
                while let current = flow.next, let waiting = flow.pending.keys.filter({ $0 <= current }).min() {
                    let segment = flow.pending.removeValue(forKey: waiting)!
                    if waiting + segment.payload.count > current {
                        let rest = Array(segment.payload[(current - waiting)...])
                        emit(segment.time, segment.port, fields[2], rest)
                        flow.next = current + rest.count
                    }
                }
            }
            flows[key] = flow
        }
        // Whatever never got its gap filled (lost from the capture) still goes out, in order,
        // so the decoder reports the problem instead of the bytes vanishing.
        for (key, flow) in flows.sorted(by: { $0.key < $1.key }) {
            let stream = String(key.split(separator: "-").first ?? "")
            for seq in flow.pending.keys.sorted() {
                let segment = flow.pending[seq]!
                emit(segment.time, segment.port, stream, segment.payload)
            }
        }
        return lines.joined(separator: "\n")
    }

    static func bytes(fromHex hex: String) -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex, let end = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) {
            guard let byte = UInt8(hex[index..<end], radix: 16) else { return [] }
            result.append(byte)
            index = end
        }
        return result
    }
}
