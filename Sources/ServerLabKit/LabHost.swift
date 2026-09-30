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

    public init(name: String, dockerHost: String?, address: String, memoryBudgetMB: Int) {
        self.name = name
        self.dockerHost = dockerHost
        self.address = address
        self.memoryBudgetMB = memoryBudgetMB
    }

    /// The Proxmox VM `testlab` (192.168.1.153), reached over SSH (`Host testlab` in ~/.ssh/config).
    public static let testlab = LabHost(
        name: "testlab",
        dockerHost: "ssh://testlab",
        address: "192.168.1.153",
        memoryBudgetMB: 12_288
    )

    /// Docker on this Mac (OrbStack, Colima or Docker Desktop).
    public static let local = LabHost(
        name: "local",
        dockerHost: nil,
        address: "127.0.0.1",
        memoryBudgetMB: 8_192
    )

    /// `SERVERLAB_HOST` selects `testlab` (default) or `local`.
    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> LabHost {
        switch environment["SERVERLAB_HOST"]?.lowercased() {
        case "local": .local
        default: .testlab
        }
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
