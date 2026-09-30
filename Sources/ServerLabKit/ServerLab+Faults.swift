import Foundation

/// A network fault between clients and a server, made by Toxiproxy.
public enum LabFault: Sendable, Hashable, Codable {
    /// Delay every chunk of data.
    case latency(milliseconds: Int, jitter: Int = 0)
    /// Throttle to a rate.
    case bandwidth(kilobytesPerSecond: Int)
    /// Stop all data, and close the connection after the time (0: keep it open, silent).
    case timeout(milliseconds: Int)
    /// Reset the connection (TCP RST) after the time.
    case resetPeer(afterMilliseconds: Int)
    /// Delay closing the connection.
    case slowClose(milliseconds: Int)
    /// Close the connection after this many bytes.
    case limitData(bytes: Int)
    /// Cut data into small packets with a delay between them.
    case slicer(averageBytes: Int, delayMicroseconds: Int)

    var toxic: (type: String, attributes: [String: Int]) {
        switch self {
        case .latency(let milliseconds, let jitter): ("latency", ["latency": milliseconds, "jitter": jitter])
        case .bandwidth(let rate): ("bandwidth", ["rate": rate])
        case .timeout(let milliseconds): ("timeout", ["timeout": milliseconds])
        case .resetPeer(let milliseconds): ("reset_peer", ["timeout": milliseconds])
        case .slowClose(let milliseconds): ("slow_close", ["delay": milliseconds])
        case .limitData(let bytes): ("limit_data", ["bytes": bytes])
        case .slicer(let size, let delay): ("slicer", ["average_size": size, "size_variation": size / 2, "delay": delay])
        }
    }
}

/// Which way a fault acts: on data to the client (`downstream`) or to the server (`upstream`).
public enum LabFaultDirection: String, Sendable, Codable, CaseIterable {
    case downstream, upstream
}

/// Faults go through a `proxy` part in front of the server: connect to its port (not the server's)
/// and every fault added acts on those connections. Any server can have one.
extension ServerLab {
    /// Toxiproxy 2.12.0, pinned.
    static let faultProxyImage = "ghcr.io/shopify/toxiproxy@sha256:9378ed52a28bc50edc1350f936f518f31fa95f0d15917d6eb40b8e376d1a214e"
    static let faultProxyRole = "proxy"
    static let proxyName = "server"

    /// Adds the `proxy` part and returns the server with it. Connections to `endpoint(of: "proxy")`
    /// reach the main part through the proxy.
    public func startFaultProxy(for server: LabServer, log: @escaping LabLog = { _ in }) async throws -> LabServer {
        if server.parts.contains(where: { $0.role == Self.faultProxyRole }) { return server }
        let main = try server.part(server.mainRole)
        let recipe = try recipes.recipe(named: server.recipe)
        _ = try await baseImageID(Self.faultProxyImage, log: log)

        // The proxy reaches the main part by its role on the server's network (made now if it has none).
        let networks = try await docker.run(["network", "ls", "--quiet", "--filter", "label=\(LabLabels.server)=\(server.containerName)"])
            .split(separator: "\n").map(String.init)
        let network: String
        if let existing = networks.first {
            network = existing
        } else {
            network = try await createNetwork(forServer: server.containerName)
            try await docker.run(["network", "connect", "--alias", main.role, network, main.containerID])
        }
        let internalPort = server.engine.internalPort
        let spec = ContainerSpec(image: Self.faultProxyImage, internalPort: internalPort, environment: [:],
                                 memoryMB: 128, extraPorts: [8474])
        let lease = Duration.seconds(max(60, Int(server.expires.timeIntervalSinceNow)))
        let started = try await startContainer(
            image: Self.faultProxyImage, spec: spec, role: .server, recipe: recipe, owner: server.containerName, lease: lease,
            fingerprint: nil, environment: [:], command: ["-host=0.0.0.0"],
            name: "\(server.containerName)-\(Self.faultProxyRole)", server: server.containerName, part: Self.faultProxyRole,
            extraArguments: ["--network", network]
        )
        var withProxy = server
        withProxy.parts.append(LabServerPart(role: Self.faultProxyRole, containerID: started.id, containerName: started.name,
                                             port: started.port, controlPort: started.extraPorts[8474]))
        let proxied = withProxy
        do {
            try await retryUntilReady("fault proxy \(started.name)", timeout: .seconds(30), every: .milliseconds(250)) {
                _ = try await proxyAPI(proxied, "POST", "/proxies", [
                    "name": Self.proxyName, "listen": "0.0.0.0:\(internalPort)",
                    "upstream": "\(main.role):\(internalPort)", "enabled": true,
                ])
            }
        } catch {
            _ = try? await docker.runAllowingFailure(["rm", "--force", started.id])
            throw error
        }
        return withProxy
    }

    /// Adds a fault to every connection through the proxy (new and open ones). Returns its name.
    @discardableResult
    public func addFault(_ fault: LabFault, direction: LabFaultDirection = .downstream, to server: LabServer) async throws -> String {
        let (type, attributes) = fault.toxic
        let name = "\(type)-\(direction.rawValue)-\(UUID().uuidString.prefix(6).lowercased())"
        _ = try await proxyAPI(server, "POST", "/proxies/\(Self.proxyName)/toxics", [
            "name": name, "type": type, "stream": direction.rawValue, "toxicity": 1.0, "attributes": attributes,
        ])
        return name
    }

    /// Removes one fault, or all of them when `name` is nil, and lets connections through again.
    public func clearFaults(_ name: String? = nil, of server: LabServer) async throws {
        if let name {
            _ = try await proxyAPI(server, "DELETE", "/proxies/\(Self.proxyName)/toxics/\(name)", nil)
        } else {
            _ = try await proxyAPI(server, "POST", "/reset", nil)
        }
    }

    /// Cuts the network: open connections through the proxy drop and new ones are refused, until
    /// `restoreConnections`.
    public func cutConnections(of server: LabServer) async throws {
        _ = try await proxyAPI(server, "POST", "/proxies/\(Self.proxyName)", ["enabled": false])
    }

    public func restoreConnections(of server: LabServer) async throws {
        _ = try await proxyAPI(server, "POST", "/proxies/\(Self.proxyName)", ["enabled": true])
    }

    func proxyAPI(_ server: LabServer, _ method: String, _ path: String, _ body: [String: any Sendable]?) async throws -> Data {
        guard let port = try server.part(Self.faultProxyRole).controlPort,
              let url = URL(string: "http://\(host.address):\(port)\(path)") else {
            throw ServerLabError.unsupported("Faults on \(server.containerName) without a fault proxy")
        }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = method
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw ServerLabError.dockerFailed(command: "toxiproxy \(method) \(path)", status: Int32(status),
                                              output: String(decoding: data, as: UTF8.self))
        }
        return data
    }
}
