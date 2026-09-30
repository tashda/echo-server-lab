import Foundation

/// The tools the tds-mcp server offers, as plain functions: a name, a description, parameters, and
/// a text answer. The MCP server only moves them over JSON-RPC.
public struct TDSTool: Sendable {
    public var name: String
    public var description: String
    /// Parameter name → description; all are strings.
    public var parameters: [(name: String, description: String, required: Bool)]

    public init(name: String, description: String, parameters: [(name: String, description: String, required: Bool)]) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

public enum TDSTools {
    public static let all: [TDSTool] = [
        TDSTool(name: "get_token", description: "Get detailed info about a TDS token by name or hex value. Returns byte value, length type, structure fields, and notes.",
                parameters: [("query", "Token name (e.g. 'COLMETADATA', 'DONE') or hex value (e.g. '0x81', '0xFD')", true)]),
        TDSTool(name: "get_all_tokens", description: "List all TDS tokens with their byte values and brief descriptions.", parameters: []),
        TDSTool(name: "get_data_type", description: "Get TDS data type details by name or hex value. Returns encoding category, wire format, null handling, and read/write patterns.",
                parameters: [("query", "Type name (e.g. 'nvarchar', 'guid', 'decimal') or hex value (e.g. '0xE7', '0x24')", true)]),
        TDSTool(name: "get_all_data_types", description: "List all TDS data types with encoding categories and hex values.", parameters: []),
        TDSTool(name: "get_message", description: "Get TDS client or server message details (PRELOGIN, LOGIN7, SQLBatch, RPC, COLMETADATA response, etc.).",
                parameters: [("name", "Message name (e.g. 'LOGIN7', 'PRELOGIN', 'RPC', 'SQLBatch', 'packet_header')", true)]),
        TDSTool(name: "get_protocol_flow", description: "Get the step-by-step message sequence for a TDS protocol flow (connection, query, RPC, transaction, etc.).",
                parameters: [("name", "Flow name (e.g. 'Standard Connection', 'SQL Query', 'RPC', 'Transaction', 'Bulk Insert')", true)]),
        TDSTool(name: "get_swift_pattern", description: "Get Swift/NIO ByteBuffer read/write patterns for a TDS data type. Includes known issues in sqlserver-nio.",
                parameters: [("type_name", "TDS type name (e.g. 'nvarchar', 'guid', 'decimal', 'datetime2')", true)]),
        TDSTool(name: "get_type_encoding", description: "Get the full TDS TYPE_INFO encoding for a type including COLMETADATA and RPC parameter wire format.",
                parameters: [("type_name", "TDS type name", true)]),
        TDSTool(name: "explain_bytes", description: "Decode TDS bytes field by field with a real decoder: a whole packet (header + message), a message payload (PRELOGIN, LOGIN7, SQLBatch, RPC, tabular result) or a token stream (COLMETADATA, ROW, DONE, ENVCHANGE, …). Unknown or leftover bytes are called out.",
                parameters: [("structure", "What the bytes are: 'packet' (starts with the 8-byte header; default), 'prelogin', 'login7', 'sqlbatch', 'rpc', 'tokens' (a tabular result), or a token name ('DONE', 'COLMETADATA')", false),
                             ("hex_bytes", "Hex bytes, spaces optional (e.g. '04 01 00 13 00 00 01 00' or '0401001300000100')", true)]),
        TDSTool(name: "search_spec", description: "Full-text search across all TDS spec data. Returns matching tokens, types, messages, and flows.",
                parameters: [("query", "Search terms (e.g. 'null bitmap', 'PLP', 'collation', 'ENVCHANGE')", true)]),
        TDSTool(name: "get_null_handling", description: "Get NULL value encoding rules for a specific TDS encoding category or type.",
                parameters: [("category", "Encoding category or type name (e.g. 'FIXEDLENTYPE', 'BYTELEN_TYPE', 'nvarchar', 'RPC')", true)]),
        TDSTool(name: "get_plp_info", description: "Get Partially Length-Prefixed (PLP) encoding details for MAX types, XML, JSON, and UDT. Includes sqlserver-nio implementation status.", parameters: []),
        TDSTool(name: "get_envchange_types", description: "List all ENVCHANGE token types (1-21) with their meanings and value formats.", parameters: []),
        TDSTool(name: "get_feature_ext", description: "Get FeatureExt feature details for LOGIN7 negotiation or FEATUREEXTACK token.",
                parameters: [("feature", "Feature name or ID (e.g. 'JSON', 'VECTOR', 'SESSIONRECOVERY', '0x0A')", false)]),
        TDSTool(name: "get_rpc_info", description: "Get RPC message encoding details including special ProcIDs, parameter encoding by type, and known sqlserver-nio quirks.", parameters: []),
        TDSTool(name: "get_sqlserver_nio_issues", description: "Get documented sqlserver-nio implementation issues, limitations, and env var workarounds.", parameters: []),
        TDSTool(name: "get_packet_example", description: "Get a binary packet example from the TDS spec (§4). Shows hex bytes, field annotations, and notes for each example message type.",
                parameters: [("query", "Example name or section (e.g. 'Pre-Login', 'SQL Batch', 'RPC', 'TVP', 'SparseColumn', 'Login', 'Attention', 'Bulk Load', '4.6')", true)]),
        TDSTool(name: "get_version_compat", description: "Get TDS version numbers and feature support for a SQL Server version, or look up what features a SQL Server version supports.",
                parameters: [("query", "SQL Server version or TDS version (e.g. '2019', '2008', 'TDS 7.4', '0x74000004', 'JSONSUPPORT', 'VECTOR', 'encryption')", false)]),
    ]

    /// Runs a tool. Unknown tools and missing parameters answer with a hint, never throw.
    public static func call(_ name: String, arguments: [String: String], spec: TDSSpecification = .shared) -> String {
        let query = (arguments["query"] ?? arguments["name"] ?? arguments["type_name"] ?? arguments["category"] ?? arguments["feature"] ?? "")
            .lowercased()
        func one(_ found: [JSONValue], or message: String) -> String {
            found.isEmpty ? message : (found.count == 1 ? found[0] : .array(found)).prettyText
        }
        func normalized(_ text: String) -> String { text.lowercased().filter { !"_ -".contains($0) } }
        switch name {
        case "get_token":
            let found = spec.tokenList.filter {
                ($0["name"]?.string?.lowercased().contains(query) ?? false) || ($0["value"]?.string?.lowercased().contains(query) ?? false)
            }
            return one(found, or: "No token found matching: \(arguments["query"] ?? "")")
        case "get_all_tokens":
            return JSONValue.array(spec.tokenList.map { token in
                .object(["name": token["name"] ?? .null, "value": token["value"] ?? .null,
                         "length_type": token["length_type"] ?? .null, "description": token["description"] ?? .null])
            }).prettyText
        case "get_data_type":
            let found = spec.typeList.filter { type in
                (type["name"]?.string?.lowercased().contains(query) ?? false)
                    || type["value"]?.string?.lowercased() == query
                    || (type["aliases"]?.array.contains { $0.string?.lowercased().contains(query) ?? false } ?? false)
                    || (type["swift_type"]?.string?.lowercased().contains(query) ?? false)
            }
            return one(found, or: "No data type found matching: \(arguments["query"] ?? "")")
        case "get_all_data_types":
            return JSONValue.array(spec.typeList.map { type in
                .object(["name": type["name"] ?? .null, "value": type["value"] ?? .null, "aliases": type["aliases"] ?? .null,
                         "category": type["category"] ?? .null, "swift_type": type["swift_type"] ?? .null])
            }).prettyText
        case "get_message":
            let wanted = normalized(query)
            let found = spec.messages.object.filter { key, _ in
                !key.hasPrefix("_") && (normalized(key).contains(wanted) || wanted.contains(normalized(key)))
            }
            if found.isEmpty {
                return "No message found matching: \(arguments["name"] ?? ""). Available: \(spec.messages.object.keys.filter { !$0.hasPrefix("_") }.sorted().joined(separator: ", "))"
            }
            return (found.count == 1 ? found.first!.value : .object(found)).prettyText
        case "get_protocol_flow":
            let flows = spec.flows["flows"]?.array ?? []
            let found = flows.filter { $0["name"]?.string?.lowercased().contains(query) ?? false }
            if found.isEmpty {
                return "No flow found matching: \(arguments["name"] ?? ""). Available: \(flows.compactMap { $0["name"]?.string }.joined(separator: ", "))"
            }
            guard found.count == 1 else { return JSONValue.array(found).prettyText }
            var flow = found[0].object
            flow["_token_stream_ordering"] = spec.flows["token_stream_ordering"]
            flow["_client_states"] = spec.flows["client_states"]?["states"]
            return JSONValue.object(flow).prettyText
        case "get_swift_pattern":
            let mappings = spec.swiftMappings["data_type_mappings"]?.array ?? []
            let found = mappings.filter {
                ($0["tds_type"]?.string?.lowercased().contains(query) ?? false) || ($0["swift_type"]?.string?.lowercased().contains(query) ?? false)
            }
            if found.isEmpty {
                return "No Swift mapping found for: \(arguments["type_name"] ?? "")\n\nByteBuffer helpers:\n\((spec.swiftMappings["byte_buffer_helpers"] ?? .null).prettyText)"
            }
            return JSONValue.object([
                "mappings": .array(found),
                "byte_buffer_helpers": spec.swiftMappings["byte_buffer_helpers"] ?? .null,
                "null_handling": spec.swiftMappings["null_handling"] ?? .null,
                "rpc_summary": spec.swiftMappings["rpc_param_encoding_summary"] ?? .null,
                "plp_status": spec.swiftMappings["plp_encoding"] ?? .null,
                "stream_parser_notes": spec.swiftMappings["stream_parser_notes"] ?? .null,
            ]).prettyText
        case "get_type_encoding":
            guard let type = spec.typeList.first(where: { type in
                (type["name"]?.string?.lowercased().contains(query) ?? false)
                    || (type["aliases"]?.array.contains { $0.string?.lowercased().contains(query) ?? false } ?? false)
            }) else { return "No type found: \(arguments["type_name"] ?? "")" }
            var result: [String: JSONValue] = [
                "type": type,
                "type_info_composition": spec.dataTypes["type_info_composition"] ?? .null,
                "null_handling": spec.swiftMappings["null_handling"] ?? .null,
            ]
            if let mapping = (spec.swiftMappings["data_type_mappings"]?.array ?? []).first(where: { $0["tds_type"]?.string?.lowercased().contains(query) ?? false }) {
                result["swift_rpc_write"] = mapping["rpc_write"]
                result["swift_read_pattern"] = mapping["read_pattern"]
            }
            return JSONValue.object(result).prettyText
        case "explain_bytes":
            guard let bytes = TDSExplainer.bytes(fromHex: arguments["hex_bytes"] ?? "") else {
                return "hex_bytes must be pairs of hex digits, e.g. '04 01 00 13 00 00 01 00'."
            }
            return TDSExplainer(spec: spec).explain(bytes, as: arguments["structure"] ?? "packet").text
        case "search_spec":
            return search(query, spec: spec).prettyText
        case "get_null_handling":
            let handling = spec.swiftMappings["null_handling"]?.object ?? [:]
            let matched = handling.filter { key, _ in key.lowercased().contains(query) || query.contains(key.lowercased().replacingOccurrences(of: "_", with: "")) }
            if matched.isEmpty {
                return JSONValue.object(["all_null_handling": .object(handling), "swift_null_handling": .object(handling)]).prettyText
            }
            return JSONValue.object([
                "spec_null_handling": .object(matched), "swift_null_handling": .object(matched),
                "rpc_null": spec.messages["rpc_null_encoding"] ?? spec.swiftMappings["rpc_param_encoding_summary"]?["null"] ?? .null,
            ]).prettyText
        case "get_plp_info":
            let plp = spec.swiftMappings["plp_encoding"] ?? .null
            return JSONValue.object(["spec": plp, "swift_status": plp]).prettyText
        case "get_envchange_types":
            return (spec.tokenList.first { $0["name"]?.string == "ENVCHANGE" } ?? .null).prettyText
        case "get_feature_ext":
            let features = spec.messages["LOGIN7"]?["feature_ext_features"] ?? .null
            let ack = spec.tokenList.first { $0["name"]?.string == "FEATUREEXTACK" } ?? .null
            guard !query.isEmpty else { return JSONValue.object(["login7_features": features, "featureextack_token": ack]).prettyText }
            let matched = features.array.filter {
                ($0["name"]?.string?.lowercased().contains(query) ?? false) || ($0["id"]?.string?.lowercased().contains(query) ?? false)
            }
            return JSONValue.object(["matched": matched.isEmpty ? .string("Not found") : .array(matched), "all_features": features, "featureextack": ack]).prettyText
        case "get_rpc_info":
            return JSONValue.object([
                "rpc_message": spec.messages["RPC"] ?? .null,
                "rpc_param_summary": spec.swiftMappings["rpc_param_encoding_summary"] ?? .null,
                "known_issues": spec.messages["known_issues_sqlserver_nio"] ?? .null,
            ]).prettyText
        case "get_sqlserver_nio_issues":
            let issues = (spec.swiftMappings["data_type_mappings"]?.array ?? []).compactMap { mapping -> JSONValue? in
                guard let issue = mapping["known_issue"] else { return nil }
                return .object(["type": mapping["tds_type"] ?? .null, "issue": issue])
            }
            return JSONValue.object([
                "known_issues": spec.messages["known_issues_sqlserver_nio"] ?? .null,
                "stream_parser_notes": spec.swiftMappings["stream_parser_notes"] ?? .null,
                "plp_status": spec.swiftMappings["plp_encoding"] ?? .null,
                "type_specific_issues": .array(issues),
            ]).prettyText
        case "get_packet_example":
            let examples = spec.examples["examples"]?.array ?? []
            let list = examples.map { "§\($0["id"]?.string ?? "") \($0["name"]?.string ?? "")" }.joined(separator: ", ")
            guard !query.isEmpty else { return "query parameter is required. Available examples: \(list)" }
            let found = examples.filter { $0.compactText.lowercased().contains(query) }
            return one(found, or: "No example found matching: \(arguments["query"] ?? ""). Available: \(list)")
        case "get_version_compat":
            guard !query.isEmpty else { return spec.versionCompat.prettyText }
            var result: [String: JSONValue] = [:]
            let versions = (spec.versionCompat["version_numbers"]?["versions"]?.array ?? []).filter { $0.compactText.lowercased().contains(query) }
            if !versions.isEmpty { result["versions"] = .array(versions) }
            let features = (spec.versionCompat["feature_support_matrix"]?["features"]?.array ?? []).filter { $0.compactText.lowercased().contains(query) }
            if !features.isEmpty { result["features"] = .array(features) }
            for (key, value) in spec.versionCompat.object where !key.hasPrefix("_") && key != "version_numbers" && key != "feature_support_matrix" {
                if value.compactText.lowercased().contains(query) { result[key] = value }
            }
            return (result.isEmpty ? spec.versionCompat : .object(result)).prettyText
        default:
            return "Unknown tool: \(name)"
        }
    }

    /// Every section where all words of the query appear.
    static func search(_ query: String, spec: TDSSpecification) -> JSONValue {
        let words = query.split(separator: " ").map(String.init)
        func matches(_ value: JSONValue) -> Bool {
            let text = value.compactText.lowercased()
            return words.allSatisfy { text.contains($0) }
        }
        var result: [String: JSONValue] = [
            "tokens": .array(spec.tokenList.filter(matches).map { .object(["name": $0["name"] ?? .null, "value": $0["value"] ?? .null, "description": $0["description"] ?? .null]) }),
            "data_types": .array(spec.typeList.filter(matches).map { .object(["name": $0["name"] ?? .null, "value": $0["value"] ?? .null, "category": $0["category"] ?? .null]) }),
            "messages": .array(spec.messages.object.filter { !$0.key.hasPrefix("_") && matches($0.value) }.keys.sorted().map { .string($0) }),
            "flows": .array((spec.flows["flows"]?.array ?? []).filter(matches).compactMap { $0["name"] }),
            "swift": .array((spec.swiftMappings["data_type_mappings"]?.array ?? []).filter(matches).compactMap { $0["tds_type"] }),
        ]
        let sections = spec.dataTypes.object.filter { $0.key != "types" && !$0.key.hasPrefix("_") && matches($0.value) }.keys.sorted()
        if !sections.isEmpty { result["data_type_sections"] = .array(sections.map { .string($0) }) }
        let examples = (spec.examples["examples"]?.array ?? []).filter(matches).map { JSONValue.string("§\($0["id"]?.string ?? "") \($0["name"]?.string ?? "")") }
        if !examples.isEmpty { result["examples"] = .array(examples) }
        if matches(spec.versionCompat) { result["version_compat"] = .string("Match found — use get_version_compat tool") }
        return .object(result)
    }
}
