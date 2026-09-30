import Foundation

/// Stopping, starting and promoting single parts of a running server, for restart, failover and
/// reconnect tests. The server keeps its parts, ports and data until it is removed.
extension ServerLab {
    /// Stops one container of the server (the main one when `role` is nil) without removing it.
    public func stop(part role: String? = nil, of server: LabServer) async throws {
        let part = try server.part(role ?? server.mainRole)
        try await docker.run(["stop", "--time", "30", part.containerID])
    }

    /// Starts a stopped part again on the same port and waits until it takes logins.
    public func start(part role: String? = nil, of server: LabServer, log: @escaping LabLog = { _ in }) async throws {
        let part = try server.part(role ?? server.mainRole)
        try await docker.run(["start", part.containerID])
        if part.role == server.mainRole {
            // The capture shares the main container's network, which a restart replaces.
            // Restarting it starts a new recording.
            let capture = Self.captureName(for: server)
            if try await docker.runAllowingFailure(["inspect", "--format", "{{.Id}}", capture]).status == 0 {
                log("Restarting the capture; it records from now on")
                _ = try await docker.runAllowingFailure(["restart", capture])
            }
        }
        log("Waiting for \(part.containerName) on \(server.host):\(part.port)")
        try await engine(for: server.engine).waitUntilReady(try server.endpoint(of: part.role), timeout: .seconds(180))
    }

    /// Promotes a standby or secondary to primary through the driver (`standby` when `role` is nil).
    public func promote(part role: String? = nil, of server: LabServer) async throws {
        try await engine(for: server.engine).promote(try server.endpoint(of: role ?? "standby"))
    }

    /// A running lab server by its main container's name, for tools that did not start it (CLI, Echo Labs).
    public func server(named name: String) async throws -> LabServer {
        let format = "{{.Id}}|{{index .Config.Labels \"\(LabLabels.recipe)\"}}|{{index .Config.Labels \"\(LabLabels.engine)\"}}|{{index .Config.Labels \"\(LabLabels.version)\"}}|{{index .Config.Labels \"\(LabLabels.expires)\"}}|{{index .Config.Labels \"\(LabLabels.tls)\"}}"
        let fields = try await docker.run(["inspect", "--format", format, name]).split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 6, let engine = EngineKind(rawValue: fields[2]) else {
            throw ServerLabError.invalidParameter("server \(name)", expected: "a running lab server")
        }
        let parts = try await parts(ofServerNamed: name, internalPort: engine.internalPort)
        let main = parts.first { $0.containerName == name }
        let port = if let main { main.port } else { try await hostPort(of: name, internalPort: engine.internalPort) }
        return LabServer(recipe: fields[1], engine: engine, version: fields[3], host: host.address, port: port,
                         username: try self.engine(for: engine).adminUsername, password: try LabPassword.resolve(),
                         containerID: fields[0], containerName: name,
                         expires: Date(timeIntervalSince1970: TimeInterval(fields[4]) ?? 0),
                         parts: main.map { [$0] + parts.filter { $0.containerName != name } } ?? [],
                         tls: try tls(fromLabel: fields[5], server: name))
    }

    /// The TLS a server was started with, from its label; the files are where `start` put them.
    func tls(fromLabel label: String, server name: String) throws -> EndpointTLS? {
        let values = label.split(separator: "/").map(String.init)
        guard values.count == 2, let mode = TLSMode(rawValue: values[0]), let kind = LabCertificateKind(rawValue: values[1]) else { return nil }
        var tls = EndpointTLS(mode: mode, certificate: kind, caPath: try LabCertificateAuthority.load().certificatePath)
        if mode == .clientCertificate {
            let directory = Self.localFilesDirectory(forServer: name)
            tls.clientCertificatePath = directory.appending(path: "client.pem").path
            tls.clientKeyPath = directory.appending(path: "client.key").path
        }
        return tls
    }

    /// The server's containers, by the `server` label (containers from before parts have none).
    func parts(ofServerNamed name: String, internalPort: Int) async throws -> [LabServerPart] {
        let format = "{{.ID}}\t{{.Names}}\t{{.Label \"\(LabLabels.part)\"}}"
        let output = try await docker.run(["ps", "--all", "--no-trunc", "--format", format, "--filter", "label=\(LabLabels.server)=\(name)"])
        var parts: [LabServerPart] = []
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 3 else { continue }
            parts.append(LabServerPart(role: fields[2], containerID: fields[0], containerName: fields[1],
                                       port: try await hostPort(of: fields[1], internalPort: internalPort)))
        }
        return parts
    }

    /// The published host port. Read from the container's settings, so it is known while stopped too.
    func hostPort(of container: String, internalPort: Int) async throws -> Int {
        let format = "{{range (index .HostConfig.PortBindings \"\(internalPort)/tcp\")}}{{.HostPort}}{{end}}"
        let text = try await docker.run(["inspect", "--format", format, container])
        guard let port = Int(text), port > 0 else {
            // Containers from before fixed ports publish an ephemeral one, only visible while running.
            let mapping = try await docker.run(["port", container, "\(internalPort)/tcp"])
            guard let port = mapping.split(separator: "\n").compactMap({ $0.split(separator: ":").last.flatMap { Int($0) } }).first else {
                throw ServerLabError.noPublishedPort(container: container)
            }
            return port
        }
        return port
    }
}

extension LabServer {
    /// The role of the container tests connect to by default.
    public var mainRole: String { parts.first?.role ?? "server" }
}
