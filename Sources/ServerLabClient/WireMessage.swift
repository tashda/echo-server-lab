import Foundation

/// One protocol message on the wire, as Wireshark decodes it (same JSON as `serverlab wire --json`).
public struct WireMessage: Codable, Sendable, Hashable {
    public var time: Double
    public var toServer: Bool
    public var protocolName: String
    public var kind: String
    public var text: String?
    public var endsMessage: Bool
}

extension Array where Element == WireMessage {
    /// Requests the client sent: TDS messages ending in EOM, PostgreSQL Sync or simple Query.
    public var requests: [WireMessage] {
        filter { $0.toServer && $0.endsMessage && ($0.protocolName == "tds" || ["Sync", "Simple query"].contains($0.kind)) }
    }

    /// How many requests were sent while `text` (or a message containing it) was being run.
    public func roundTrips(containing text: String) -> Int {
        guard contains(where: { $0.protocolName == "pgsql" }) else { return requests.filter { $0.text?.contains(text) == true }.count }
        var count = 0, matched = false
        for message in self where message.toServer {
            if message.text?.contains(text) == true { matched = true }
            if matched, message.kind == "Sync" || message.kind == "Simple query" { count += 1; matched = false }
        }
        return count
    }
}

/// The recorded traffic of the enclosing `.server(..., capture: true)` server.
public struct LabWire: Sendable {
    public let server: LabServer

    @TaskLocal public static var current: LabWire?

    public func messages() async throws -> [WireMessage] {
        try await Task.sleep(for: .milliseconds(300))
        return try await ServerLabCLI.wire(server)
    }

    /// True when `text` crossed the wire unencrypted (UTF-8 or UTF-16LE).
    public func containsPlaintext(_ text: String) async throws -> Bool {
        let data = try await ServerLabCLI.pcap(server)
        let utf16 = Data(text.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
        return data.range(of: Data(text.utf8)) != nil || data.range(of: utf16) != nil
    }
}
