import Foundation
import TDSSpec

/// A minimal MCP server over stdio: initialize, ping, tools/list and tools/call.
struct MCPServer: Sendable {
    let tools: [TDSTool]
    let handler: @Sendable (String, [String: String]) async -> String

    init(tools: [TDSTool], handler: @escaping @Sendable (String, [String: String]) async -> String) {
        self.tools = tools
        self.handler = handler
    }

    func run() async {
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty, let data = line.data(using: .utf8),
                  let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let response = await respond(to: message) { write(response) }
        }
    }

    func respond(to message: [String: Any]) async -> [String: Any]? {
        let id = message["id"]
        let method = message["method"] as? String ?? ""
        let params = message["params"] as? [String: Any] ?? [:]
        // Notifications have no id and get no answer.
        guard let id else { return nil }
        func result(_ value: Any) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "result": value] }
        switch method {
        case "initialize":
            return result([
                "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "tds-mcp", "version": "2.0.0"],
                "instructions": "MS-TDS reference, a TDS decoder (explain_bytes) and explained captures of echo-server-lab servers.",
            ])
        case "ping":
            return result([String: Any]())
        case "tools/list":
            return result(["tools": tools.map(Self.definition)])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = (params["arguments"] as? [String: Any] ?? [:]).mapValues { "\($0)" }
            let text = await handler(name, arguments)
            return result(["content": [["type": "text", "text": text]], "isError": text.hasPrefix("Unknown tool")])
        default:
            return ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found: \(method)"]]
        }
    }

    static func definition(_ tool: TDSTool) -> [String: Any] {
        [
            "name": tool.name,
            "description": tool.description,
            "inputSchema": [
                "type": "object",
                "properties": Dictionary(uniqueKeysWithValues: tool.parameters.map { ($0.name, ["type": "string", "description": $0.description]) }),
                "required": tool.parameters.filter(\.required).map(\.name),
            ] as [String: Any],
        ]
    }

    func write(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else { return }
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }
}
