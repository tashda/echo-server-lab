import Foundation

/// One protocol message on the wire, as Wireshark decodes it.
public struct WireMessage: Codable, Sendable, Hashable {
    /// Seconds since the capture started.
    public var time: Double
    public var toServer: Bool
    /// `tds` or `pgsql`.
    public var protocolName: String
    /// Wireshark's name for the message: "SQL batch", "Remote Procedure Call", "Attention", "Parse", "Sync", ….
    public var kind: String
    /// The SQL text for batches, simple queries and Parse messages; the procedure for RPCs.
    public var text: String?
    /// True on the last TDS packet of a message (EOM); always true for PostgreSQL.
    public var endsMessage: Bool
}

extension Array where Element == WireMessage {
    /// Requests the client sent: TDS messages ending in EOM, PostgreSQL Sync or simple Query.
    public var requests: [WireMessage] {
        filter { $0.toServer && $0.endsMessage && ($0.protocolName == "tds" || ["Sync", "Simple query"].contains($0.kind)) }
    }

    /// How many requests were sent while `text` (or a message containing it) was being run.
    public func roundTrips(containing text: String) -> Int {
        let pgsql = contains { $0.protocolName == "pgsql" }
        guard pgsql else { return requests.filter { $0.text?.contains(text) == true }.count }
        // PostgreSQL's extended protocol: the Parse carries the text, the Sync ends the request.
        var count = 0
        var matched = false
        for message in self where message.toServer {
            if message.text?.contains(text) == true { matched = true }
            if matched, message.kind == "Sync" || message.kind == "Simple query" {
                count += 1
                matched = false
            }
        }
        return count
    }
}

extension EngineKind {
    /// The port the server listens on inside its container.
    public var internalPort: Int {
        switch self {
        case .sqlServer: 1433
        case .postgres: 5432
        }
    }
}

extension ServerLab {
    /// The container that records a server's traffic (it shares the server's network).
    static func captureName(for server: LabServer) -> String { "serverlab-capture-\(server.containerName.dropFirst("serverlab-".count))" }
    /// tcpdump 4.99.6 and tshark 4.6.6, pinned so decoding does not change under the tests.
    static let captureImage = "nicolaka/netshoot@sha256:b09d9b21381f47a79b3cbcb30da25266dc17186ea00ae65e99fdc51396f48e70"
    var capturesDirectory: String { (host.samplesDirectory as NSString).deletingLastPathComponent + "/captures" }

    /// Starts recording everything sent to and from the server's port into a pcap file on the host.
    /// Stops with the server (same lease) or with `stopCapture(of:)`.
    public func startCapture(of server: LabServer) async throws {
        let name = Self.captureName(for: server)
        var labels = [
            LabLabels.managed: "true", LabLabels.role: "capture", LabLabels.recipe: server.recipe,
            LabLabels.owner: server.containerName, LabLabels.expires: String(Int(server.expires.timeIntervalSince1970)),
        ]
        labels[LabLabels.engine] = server.engine.rawValue
        try await docker.run(
            ["run", "--detach", "--name", name, "--network", "container:\(server.containerID)", "--memory", "256m",
             "--volume", "\(capturesDirectory):/captures"]
            + LabLabels.arguments(labels)
            + [Self.captureImage, "tcpdump", "-i", "eth0", "-U", "-s", "0", "-w", "/captures/\(server.containerName).pcap",
               "tcp", "port", String(server.engine.internalPort)]
        )
    }

    /// Stops recording; the pcap file stays on the host until `pruneCaptures(olderThan:)`.
    public func stopCapture(of server: LabServer) async throws {
        _ = try await docker.runAllowingFailure(["rm", "--force", Self.captureName(for: server)])
    }

    /// The server's traffic so far, decoded by Wireshark (tshark). Works while the capture runs.
    public func wireMessages(of server: LabServer) async throws -> [WireMessage] {
        let fields = ["frame.time_relative", "tcp.dstport", "tds.type", "tds.status", "tds.query", "tds.rpc.name",
                      "tds.rpc.proc_id", "pgsql.type", "pgsql.query"]
        let output = try await docker.run(
            ["run", "--rm", "--volume", "\(capturesDirectory):/captures:ro", Self.captureImage,
             "tshark", "-r", "/captures/\(server.containerName).pcap", "-Y", "tds || pgsql", "-T", "fields",
             "-E", "separator=\t", "-E", "occurrence=a", "-E", "aggregator=\u{1F}"]
            + fields.flatMap { ["-e", $0] }
        )
        return WireDecoding.messages(fromTSharkFields: output, serverPort: server.engine.internalPort)
    }

    /// The raw pcap, for opening in Wireshark.
    public func captureData(of server: LabServer) async throws -> Data {
        try await docker.runData(["run", "--rm", "--volume", "\(capturesDirectory):/captures:ro", "alpine",
                                  "cat", "/captures/\(server.containerName).pcap"])
    }

    /// True when `text` appears unencrypted in the capture (UTF-8 or UTF-16LE, as TDS sends strings).
    public func captureContainsPlaintext(_ text: String, of server: LabServer) async throws -> Bool {
        let data = try await captureData(of: server)
        let utf16 = Data(text.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
        return data.range(of: Data(text.utf8)) != nil || data.range(of: utf16) != nil
    }

    /// Deletes pcap files older than `age` on the host.
    public func pruneCaptures(olderThan age: Duration = .seconds(24 * 3600)) async throws {
        let minutes = max(1, Int(age.components.seconds / 60))
        _ = try await docker.runAllowingFailure(["run", "--rm", "--volume", "\(capturesDirectory):/captures", "alpine",
                                                 "find", "/captures", "-name", "*.pcap", "-mmin", "+\(minutes)", "-delete"])
    }
}

/// Turns tshark's `-T fields` output into messages. Separate from Docker so it can be tested.
public enum WireDecoding {
    static let tdsTypes = [1: "SQL batch", 2: "Pre-TDS7 login", 3: "Remote Procedure Call", 4: "Tabular result",
                           6: "Attention", 7: "Bulk load", 8: "Federated authentication token", 14: "Transaction manager request",
                           16: "TDS7 login", 17: "SSPI", 18: "Pre-login"]

    public static func messages(fromTSharkFields output: String, serverPort: Int) -> [WireMessage] {
        var messages: [WireMessage] = []
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 9 else { continue }
            let values = fields.map { $0.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init) }
            let time = Double(fields[0]) ?? 0
            let toServer = Int(values[1].first ?? "") == serverPort
            let typeCodes = values[2].filter { !$0.isEmpty }
            if !typeCodes.isEmpty {
                let statuses = values[3], queries = values[4], procedures = values[5], procedureIDs = values[6]
                for (index, type) in typeCodes.enumerated() {
                    let code = Int(type) ?? Int(type.dropFirst(2), radix: 16) ?? -1
                    let status = Int(statuses[safe: index] ?? "") ?? Int((statuses[safe: index] ?? "").dropFirst(2), radix: 16) ?? 1
                    let text = [queries[safe: index], procedures[safe: index], procedureIDs[safe: index].map { "proc \($0)" }]
                        .compactMap { $0 }.first { !$0.isEmpty && $0 != "proc " }
                    messages.append(WireMessage(time: time, toServer: toServer, protocolName: "tds",
                                                kind: Self.tdsTypes[code] ?? "TDS \(code)", text: text, endsMessage: status & 0x01 == 1))
                }
            }
            var queries = values[8].filter { !$0.isEmpty }[...]
            for kind in values[7] where !kind.isEmpty {
                let carriesText = toServer && (kind == "Parse" || kind == "Simple query")
                let text = carriesText ? queries.popFirst() : nil
                messages.append(WireMessage(time: time, toServer: toServer, protocolName: "pgsql", kind: kind, text: text, endsMessage: true))
            }
        }
        return messages
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

extension ServerLab {
    /// A running lab server by container name, for tools that did not start it (CLI, Echo Labs).
    public func server(named name: String) async throws -> LabServer {
        let format = "{{.Id}}|{{index .Config.Labels \"\(LabLabels.recipe)\"}}|{{index .Config.Labels \"\(LabLabels.engine)\"}}|{{index .Config.Labels \"\(LabLabels.version)\"}}|{{index .Config.Labels \"\(LabLabels.expires)\"}}"
        let fields = try await docker.run(["inspect", "--format", format, name]).split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 5, let engine = EngineKind(rawValue: fields[2]) else {
            throw ServerLabError.invalidParameter("server \(name)", expected: "a running lab server")
        }
        let mapping = try await docker.run(["port", name, "\(engine.internalPort)/tcp"])
        let port = mapping.split(separator: "\n").compactMap { $0.split(separator: ":").last.flatMap { Int($0) } }.first ?? 0
        let password = try LabPassword.resolve()
        return LabServer(recipe: fields[1], engine: engine, version: fields[3], host: host.address, port: port,
                         username: try self.engine(for: engine).adminUsername, password: password,
                         containerID: fields[0], containerName: name,
                         expires: Date(timeIntervalSince1970: TimeInterval(fields[4]) ?? 0))
    }
}
