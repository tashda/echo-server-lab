import Foundation

/// The containers a server is made of. Most servers are one container. A primary with a standby,
/// an availability group, or a server with its KDC are several, on a private network where each
/// part is reachable by its role name (`primary`, `standby`, …).
public struct ServerTopology: Sendable {
    /// The role of the container tests connect to by default.
    public var mainRole: String
    /// Files the main container needs on top of its seeded image.
    public var mainFiles: [String: ContainerFile]
    /// Arguments added to the engine's command for the main container.
    public var mainArguments: [String]
    /// Containers started after the main one, in order, each once the one before is ready.
    public var parts: [ServerPartSpec]

    public init(mainRole: String, mainFiles: [String: ContainerFile] = [:], mainArguments: [String] = [], parts: [ServerPartSpec] = []) {
        self.mainRole = mainRole
        self.mainFiles = mainFiles
        self.mainArguments = mainArguments
        self.parts = parts
    }

    public static let single = ServerTopology(mainRole: "server")
}

/// A container next to the main one. It runs its own image (not the seeded one), e.g. a standby
/// that clones the primary when it starts.
public struct ServerPartSpec: Sendable {
    public var role: String
    public var container: ContainerSpec
    /// The part takes logins like the main server does (a standby does; a KDC does not).
    public var acceptsLogins: Bool

    public init(role: String, container: ContainerSpec, acceptsLogins: Bool = true) {
        self.role = role
        self.container = container
        self.acceptsLogins = acceptsLogins
    }
}

/// One container of a running server.
public struct LabServerPart: Sendable, Hashable, Codable {
    public var role: String
    public var containerID: String
    public var containerName: String
    /// The host port, fixed for the server's life (it survives `stop(part:)` and `start(part:)`).
    public var port: Int

    public init(role: String, containerID: String, containerName: String, port: Int) {
        self.role = role
        self.containerID = containerID
        self.containerName = containerName
        self.port = port
    }
}
