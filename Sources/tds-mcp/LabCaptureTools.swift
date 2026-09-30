import Foundation
import ServerLabCatalog
import ServerLabKit
import TDSSpec

/// Tools over the traffic echo-server-lab recorded for a server (`serverlab up <recipe> --capture`).
enum LabCaptureTools {
    static let all: [TDSTool] = [
        TDSTool(name: "explain_capture", description: "Explain the recorded traffic of a running echo-server-lab server (started with --capture or capture: true), message by message with every field: TDS for SQL Server, the frontend/backend protocol for PostgreSQL. Encrypted parts show as TLS records.",
                parameters: [("server", "The server's container name (serverlab ps)", true),
                             ("contains", "Only messages whose explanation contains this text (e.g. 'COLMETADATA', 'sp_executesql')", false),
                             ("limit", "At most this many messages (default 20)", false)]),
        TDSTool(name: "check_capture", description: "Check a recorded capture against its protocol (MS-TDS or PostgreSQL 3.x): lists every byte sequence the decoder could not explain (unknown tokens, messages or types, lengths past the end, leftovers). Empty means the traffic matches.",
                parameters: [("server", "The server's container name (serverlab ps)", true)]),
    ]

    static func call(_ name: String, arguments: [String: String]) async -> String {
        do {
            let lab = try ServerLab.standard()
            let server = try await lab.server(named: arguments["server"] ?? "")
            let messages = try await lab.explainedWire(of: server)
            switch name {
            case "explain_capture":
                let filter = arguments["contains"]?.lowercased()
                let chosen = messages.filter { filter == nil || $0.explanation.text.lowercased().contains(filter!) }
                    .prefix(Int(arguments["limit"] ?? "") ?? 20)
                if chosen.isEmpty { return "No messages\(filter.map { " containing '\($0)'" } ?? "") in \(messages.count) recorded." }
                return chosen.map { message in
                    String(format: "%8.3fs %@ ", message.time, message.toServer ? "client →" : "server ←") + message.explanation.text
                }.joined(separator: "\n\n") + "\n\n(\(chosen.count) of \(messages.count) messages)"
            case "check_capture":
                let problems = messages.specProblems
                return problems.isEmpty ? "All \(messages.count) messages match the protocol." : problems.joined(separator: "\n")
            default:
                return "Unknown tool: \(name)"
            }
        } catch {
            return "Could not read the capture: \(error)"
        }
    }
}
