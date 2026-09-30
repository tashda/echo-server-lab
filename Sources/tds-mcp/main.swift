import Foundation
import TDSSpec

/// tds-mcp: the TDS protocol reference and decoder as an MCP server on stdio (one JSON-RPC message
/// per line). Tools come from TDSTools, plus the lab's capture tools (LabCaptureTools).
let server = MCPServer(tools: TDSTools.all + LabCaptureTools.all) { name, arguments in
    if LabCaptureTools.all.contains(where: { $0.name == name }) {
        return await LabCaptureTools.call(name, arguments: arguments)
    }
    return TDSTools.call(name, arguments: arguments)
}
await server.run()
