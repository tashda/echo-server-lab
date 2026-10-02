import Foundation

/// A machine running Docker that lab servers run on.
public struct LabHost: Sendable, Hashable {
    public var name: String
    /// Passed to `docker --host`; nil uses the local Docker context.
    public var dockerHost: String?
    /// The address clients connect to for published ports.
    public var address: String
    /// Lab containers on this host may not reserve more memory than this together.
    public var memoryBudgetMB: Int
    /// True when only the lab uses this host's Docker, so unused volumes may be pruned.
    public var isDedicated: Bool
    /// Directory on the Docker host holding sample database files (see `LabSamples`).
    public var samplesDirectory: String

    public init(name: String, dockerHost: String?, address: String, memoryBudgetMB: Int, isDedicated: Bool, samplesDirectory: String) {
        self.name = name
        self.dockerHost = dockerHost
        self.address = address
        self.memoryBudgetMB = memoryBudgetMB
        self.isDedicated = isDedicated
        self.samplesDirectory = samplesDirectory
    }

    /// Docker on this machine (OrbStack, Colima or Docker Desktop). The default when nothing else is configured.
    public static let local = LabHost(
        name: "local",
        dockerHost: nil,
        address: "127.0.0.1",
        memoryBudgetMB: 8_192,
        isDedicated: false,
        samplesDirectory: FileManager.default.homeDirectoryForCurrentUser.appending(path: ".echo-testlab/samples").path
    )

    /// The host to use, chosen in this order:
    ///
    /// 1. `SERVERLAB_DOCKER_HOST` (for example `ssh://lab`) with `SERVERLAB_ADDRESS`, and optionally
    ///    `SERVERLAB_MEMORY_MB`, `SERVERLAB_DEDICATED=1` and `SERVERLAB_SAMPLES_DIR`: a host defined
    ///    entirely by the environment (CI).
    /// 2. `SERVERLAB_HOST=<name>`: `local`, a host in `~/.echo-testlab/hosts.json`, or else any name
    ///    `docker --host ssh://<name>` can reach (the name is also the address clients connect to).
    /// 3. The `default` host in `~/.echo-testlab/hosts.json`.
    /// 4. `local`.
    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment,
        configuration: LabHostConfiguration? = LabHostConfiguration.load()
    ) -> LabHost {
        if let dockerHost = environment["SERVERLAB_DOCKER_HOST"], !dockerHost.isEmpty,
           let address = environment["SERVERLAB_ADDRESS"], !address.isEmpty {
            return LabHost(
                name: environment["SERVERLAB_HOST"] ?? "remote",
                dockerHost: dockerHost,
                address: address,
                memoryBudgetMB: Int(environment["SERVERLAB_MEMORY_MB"] ?? "") ?? 16_384,
                isDedicated: environment["SERVERLAB_DEDICATED"] == "1",
                samplesDirectory: environment["SERVERLAB_SAMPLES_DIR"] ?? "/opt/serverlab/samples"
            )
        }
        let requested = environment["SERVERLAB_HOST"].flatMap { $0.isEmpty ? nil : $0 } ?? configuration?.defaultHost ?? "local"
        if requested.lowercased() == "local" { return .local }
        if let configured = configuration?.hosts[requested] { return configured.host(named: requested) }
        return LabHost(name: requested, dockerHost: "ssh://\(requested)", address: requested, memoryBudgetMB: 16_384,
                       isDedicated: false, samplesDirectory: "/opt/serverlab/samples")
    }
}

/// `~/.echo-testlab/hosts.json`: the machines this user's lab can run on, kept out of the repository.
///
///     { "default": "lab", "hosts": { "lab": { "dockerHost": "ssh://lab", "address": "192.0.2.10",
///       "memoryBudgetMB": 16384, "isDedicated": true, "samplesDirectory": "/opt/serverlab/samples" } } }
public struct LabHostConfiguration: Sendable, Codable, Equatable {
    public struct Entry: Sendable, Codable, Equatable {
        public var dockerHost: String?
        public var address: String
        public var memoryBudgetMB: Int?
        public var isDedicated: Bool?
        public var samplesDirectory: String?

        public func host(named name: String) -> LabHost {
            LabHost(name: name, dockerHost: dockerHost, address: address, memoryBudgetMB: memoryBudgetMB ?? 16_384,
                    isDedicated: isDedicated ?? false, samplesDirectory: samplesDirectory ?? "/opt/serverlab/samples")
        }
    }

    public var `default`: String?
    public var hosts: [String: Entry]
    public var defaultHost: String? { `default` }

    public static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".echo-testlab/hosts.json")
    }

    public static func load(from url: URL = fileURL) -> LabHostConfiguration? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LabHostConfiguration.self, from: data)
    }
}

/// The admin password lab servers are built with.
public enum LabPassword {
    /// `SERVERLAB_PASSWORD`, else `TESTLAB_PASSWORD` in `~/.echo-testlab/credentials.env`.
    public static func resolve(_ environment: [String: String] = ProcessInfo.processInfo.environment) throws -> String {
        if let password = environment["SERVERLAB_PASSWORD"], !password.isEmpty { return password }
        let file = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".echo-testlab/credentials.env")
        if let text = try? String(contentsOf: file, encoding: .utf8) {
            for line in text.split(separator: "\n") where line.hasPrefix("TESTLAB_PASSWORD=") {
                let password = String(line.dropFirst("TESTLAB_PASSWORD=".count))
                if !password.isEmpty { return password }
            }
        }
        throw ServerLabError.missingPassword
    }
}
