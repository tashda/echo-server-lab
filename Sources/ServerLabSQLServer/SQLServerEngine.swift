import Foundation
import ServerLabKit
import SQLServerKit

/// SQL Server on Linux containers (amd64 images from mcr.microsoft.com).
public struct SQLServerEngine: LabEngine {
    public let kind = EngineKind.sqlServer
    public let supportedVersions = ["2017", "2019", "2022", "2025"]
    public let adminUsername = "sa"
    public let packs: [any ContentPack] = [
        SQLServerDatabasePack(),
        SQLServerColumnTypesPack(),
        SQLServerAgentJobsPack(),
        SQLServerProgrammabilityPack(),
        SQLServerIndexesPack(),
        SQLServerSecurityPack(),
        SQLServerPartitioningPack(),
        SQLServerTemporalPack(),
        SQLServerLinkedServersPack(),
        SQLServerSamplePack(),
        SQLServerChangeTrackingPack(),
        SQLServerDatabaseStatesPack(),
        SQLServerBackupsPack(),
        SQLServerServiceBrokerPack(),
        SQLServerQueryStorePack(),
        SQLServerExtendedPropertiesPack(),
        SQLServerExtendedEventsPack(),
        SQLServerResourceGovernorPack(),
        SQLServerCentralManagementPack(),
        SQLServerLowPrivilegePack(),
        SQLServerEdgeCasesPack(),
        SQLServerDatabaseMailPack(),
    ]

    public init() {}

    public func containerSpec(for recipe: Recipe, password: String) throws -> ContainerSpec {
        guard supportedVersions.contains(recipe.version) else {
            throw ServerLabError.unsupportedVersion(kind, recipe.version, supported: supportedVersions)
        }
        if recipe.settings.serverOptions?.isEmpty == false {
            throw ServerLabError.unsupported("serverOptions on SQL Server (use agent, collation, tls or a pack)")
        }
        let memoryMB = recipe.settings.memoryMB ?? 3_072
        var environment = [
            "ACCEPT_EULA": "Y",
            "MSSQL_PID": "Developer",
            "MSSQL_SA_PASSWORD": password,
            "MSSQL_AGENT_ENABLED": (recipe.settings.agent ?? false) ? "true" : "false",
            // Leave room inside the container limit for the process itself.
            "MSSQL_MEMORY_LIMIT_MB": String(max(2_048, memoryMB - 512)),
        ]
        if let collation = recipe.settings.collation { environment["MSSQL_COLLATION"] = collation }
        let availabilityGroup = recipe.settings.topology == Self.availabilityGroup
        if availabilityGroup { environment["MSSQL_ENABLE_HADR"] = "1" }
        // The image declares no volumes, so /var/opt/mssql is kept by `docker commit`.
        return ContainerSpec(
            image: "mcr.microsoft.com/mssql/server:\(recipe.version)-latest",
            internalPort: 1433,
            environment: environment,
            memoryMB: memoryMB,
            // @@SERVERNAME comes from the builder's host name; an AG names its replicas by it.
            hostname: availabilityGroup ? Self.primaryRole : nil
        )
    }

    /// TLS and Active Directory through mssql.conf: the lab's certificate, `forceencryption`,
    /// `forcestrict` (2025+), and the service account's keytab for Kerberos and NTLM logins.
    public func topology(for recipe: Recipe, setup: ServerSetup) throws -> ServerTopology {
        let availabilityGroup: Bool
        switch recipe.settings.topology {
        case nil: availabilityGroup = false
        case Self.availabilityGroup?: availabilityGroup = true
        case let other?: throw ServerLabError.unsupported("Topology '\(other)' on SQL Server (use \(Self.availabilityGroup))")
        }
        if availabilityGroup, recipe.settings.kerberos == true { throw ServerLabError.unsupported("Kerberos on an availability group") }
        let mail = recipe.settings.mailServer == true
        guard availabilityGroup || mail || setup.tls != nil || setup.kerberos != nil || recipe.settings.kerberos == true else { return .single }
        var network = ["[network]"]
        var files: [String: ContainerFile] = [:]
        if let tls = setup.tls {
            switch tls.mode {
            case .clientCertificate:
                throw ServerLabError.unsupported("Client-certificate login on SQL Server")
            case .strict where recipe.version < "2025":
                throw ServerLabError.unsupported("Strict encryption (TDS 8) on SQL Server \(recipe.version); it needs 2025")
            case .strict where tls.certificateKind != .valid:
                throw ServerLabError.unsupported("Strict encryption with a \(tls.certificateKind.rawValue) certificate (the lab could not log in)")
            default:
                break
            }
            network += ["tlscert = /var/opt/mssql/tls/server.pem", "tlskey = /var/opt/mssql/tls/server.key",
                        "forceencryption = \(tls.mode == .optional ? 0 : 1)"]
            if tls.mode == .strict { network.append("forcestrict = 1") }
            files["/var/opt/mssql/tls/server.pem"] = ContainerFile(tls.server.certificatePEM, mode: 0o400, owner: 10001)
            files["/var/opt/mssql/tls/server.key"] = ContainerFile(tls.server.keyPEM, mode: 0o400, owner: 10001)
        }
        if let kerberos = setup.kerberos {
            network += ["privilegedadaccount = \(kerberos.service.account)", "kerberoskeytabfile = \(Self.keytabPath)"]
            files[Self.keytabPath] = ContainerFile(kerberos.keytab, mode: 0o440, owner: 10001)
            files["/etc/krb5.conf"] = ContainerFile(kerberos.containerConfiguration)
        }
        // The images run SQL Server as uid 10001 (mssql); the seeded images have no mssql.conf of their own.
        if network.count > 1 {
            files["/var/opt/mssql/mssql.conf"] = ContainerFile(network.joined(separator: "\n") + "\n", owner: 10001)
        }
        var topology = availabilityGroup
            ? try availabilityGroupTopology(for: recipe, password: setup.password, files: files)
            : ServerTopology(mainRole: "server", mainFiles: files)
        if mail { topology.parts.append(Self.mailServerPart) }
        return topology
    }

    static let keytabPath = "/var/opt/mssql/secrets/mssql.keytab"

    /// `sql-<id>` with `MSSQLSvc/sql-<id>.lab.test:<port>` (what clients ask for) and the portless SPN.
    public func kerberosService(for recipe: Recipe, serverID: String, hostPort: Int) throws -> KerberosService {
        let host = "sql-\(serverID).\(LabDomain.dnsName)"
        return KerberosService(hostName: host, account: "sql-\(serverID)",
                               servicePrincipals: ["MSSQLSvc/\(host):\(hostPort)", "MSSQLSvc/\(host)"])
    }

    /// A Windows login for the domain user, through the driver.
    public func configure(_ server: LabServer) async throws {
        guard server.kerberos != nil else { return }
        try await SQLServerSession.with(server.endpoint) { client in
            try await client.serverSecurity.createWindowsLogin(name: "\(LabDomain.netbiosName)\\\(LabDomain.user)")
        }
    }

    public func waitUntilReady(_ server: ServerEndpoint, timeout: Duration) async throws {
        try await retryUntilReady("SQL Server at \(server.host):\(server.port)", timeout: timeout) {
            try await SQLServerSession.with(server) { client in
                _ = try await client.metadata.listDatabases()
            }
        }
    }
}

/// Opens a driver client for a lab server and always closes it.
enum SQLServerSession {
    static func with<T: Sendable>(
        _ server: ServerEndpoint,
        database: String = "master",
        _ body: (SQLServerClient) async throws -> T
    ) async throws -> T {
        let client = try await SQLServerClient.connect(
            hostname: server.host,
            port: server.port,
            database: database,
            authentication: .sqlPassword(username: server.username, password: server.password),
            tlsEnabled: true,
            // Strict (TDS 8) always checks the certificate; otherwise the lab trusts any, since some
            // servers present bad ones on purpose.
            trustServerCertificate: server.tls?.mode != .strict,
            caCertificatePath: server.tls?.mode == .strict ? server.tls?.caPath : nil,
            encryptionMode: server.tls?.mode == .strict ? .strict : .mandatory,
            logger: driverLogger("serverlab.sqlserver")
        )
        do {
            let result = try await body(client)
            try await client.shutdownGracefully()
            return result
        } catch {
            try? await client.shutdownGracefully()
            throw error
        }
    }
}
