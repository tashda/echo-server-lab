import Foundation
import PostgresKit
import ServerLabKit

/// `primary-standby`: the seeded server as primary, and a hot standby that clones it with
/// `pg_basebackup` when it first starts and then streams from it through a replication slot.
extension PostgresEngine {
    static let primaryStandby = "primary-standby"
    static let hbaFile = "/labconf/pg_hba.conf"
    static let standbyRole = "standby"

    public func topology(for recipe: Recipe, setup: ServerSetup) throws -> ServerTopology {
        let password = setup.password, tls = setup.tls
        let withStandby: Bool
        switch recipe.settings.topology {
        case nil: withStandby = false
        case Self.primaryStandby?: withStandby = true
        case Self.publisherSubscriber?: return try logicalTopology(for: recipe, setup: setup)
        case let other?:
            throw ServerLabError.unsupported("Topology '\(other)' on PostgreSQL (use \(Self.primaryStandby) or \(Self.publisherSubscriber))")
        }
        if withStandby, tls?.mode == .clientCertificate {
            throw ServerLabError.unsupported("A standby on a client-certificate server")
        }
        guard withStandby || tls != nil || recipe.settings.kerberos == true else { return .single }

        let spec = try containerSpec(for: recipe, password: password)
        let (files, arguments) = Self.configuration(tls: tls, kerberos: setup.kerberos, replication: withStandby)
        guard withStandby else { return ServerTopology(mainRole: "server", mainFiles: files, mainArguments: arguments) }

        let settings = spec.command.dropFirst() + arguments
        let sslMode = tls == nil ? "" : " sslmode=require"
        // Runs as root in the base image; the `if` keeps the clone when the standby is restarted.
        let script = """
            set -e
            mkdir -p /labdata/pgdata && chown postgres:postgres /labdata/pgdata && chmod 700 /labdata/pgdata
            if [ ! -s /labdata/pgdata/PG_VERSION ]; then
              gosu postgres pg_basebackup -d "host=primary port=5432 user=postgres application_name=\(Self.standbyRole)\(sslMode)" \\
                -D /labdata/pgdata -R -X stream -C -S \(Self.standbyRole)
            fi
            exec gosu postgres postgres -D /labdata/pgdata \(settings.joined(separator: " "))
            """
        let standby = ContainerSpec(
            image: spec.image, internalPort: 5432,
            environment: ["PGPASSWORD": password, "PGDATA": "/labdata/pgdata"],
            command: ["bash", "-c", script],
            memoryMB: spec.memoryMB,
            files: files
        )
        return ServerTopology(mainRole: "primary", mainFiles: files, mainArguments: arguments,
                              parts: [ServerPartSpec(role: Self.standbyRole, container: standby)])
    }

    /// pg_hba.conf and TLS files, and the server arguments that point at them.
    static func configuration(tls: ServerTLS?, kerberos: ServerKerberos?, replication: Bool) -> (files: [String: ContainerFile], arguments: [String]) {
        let sslOnly = tls != nil && tls?.mode != .optional
        let type = sslOnly ? "hostssl" : "host"
        let method = tls?.mode == .clientCertificate ? "cert" : "scram-sha-256"
        var rules = ["local all all trust"]
        // The domain user logs in with a Kerberos ticket; everyone else as before.
        if kerberos != nil { rules.append("\(type) all \(LabDomain.user) all gss include_realm=0 krb_realm=\(LabDomain.realm)") }
        rules.append("\(type) all all all \(method)")
        if replication { rules.append("\(type) replication all all \(method)") }
        if sslOnly { rules.append("hostnossl all all all reject") }
        var files = [hbaFile: ContainerFile(rules.joined(separator: "\n") + "\n")]
        var arguments = ["-c", "hba_file=\(hbaFile)"]
        if let tls {
            // The official images run PostgreSQL as uid 999, which must own a 0600 key.
            files["/labconf/server.crt"] = ContainerFile(tls.server.certificatePEM)
            files["/labconf/server.key"] = ContainerFile(tls.server.keyPEM, mode: 0o600, owner: 999)
            files["/labconf/ca.crt"] = ContainerFile(tls.caPEM)
            arguments += ["-c", "ssl=on", "-c", "ssl_cert_file=/labconf/server.crt", "-c", "ssl_key_file=/labconf/server.key",
                          "-c", "ssl_ca_file=/labconf/ca.crt"]
            if tls.mode == .strict { arguments += ["-c", "ssl_min_protocol_version=TLSv1.3"] }
        }
        if let kerberos {
            files[keytabPath] = ContainerFile(kerberos.keytab, mode: 0o600, owner: 999)
            files["/etc/krb5.conf"] = ContainerFile(kerberos.containerConfiguration)
            arguments += ["-c", "krb_server_keyfile=\(keytabPath)"]
        }
        return (files, arguments)
    }

    static let keytabPath = "/labconf/postgres.keytab"

    /// `pg-<id>` with `postgres/pg-<id>.lab.test` (libpq's default service name and the host clients use).
    public func kerberosService(for recipe: Recipe, serverID: String, hostPort: Int) throws -> KerberosService {
        let host = "pg-\(serverID).\(LabDomain.dnsName)"
        return KerberosService(hostName: host, account: "pg-\(serverID)", servicePrincipals: ["postgres/\(host)"])
    }

    /// A login role for the domain user, through the driver.
    public func configure(_ server: LabServer) async throws {
        guard server.kerberos != nil else { return }
        try await PostgresSession.with(server.endpoint) { client in
            _ = try await client.security.createRole(name: LabDomain.user, login: true)
        }
    }

    public func waitUntilTopologyReady(_ server: LabServer, files: any ServerPartFiles) async throws {
        if server.parts.contains(where: { $0.role == Self.subscriberRole }) {
            try await connectSubscriber(of: server)
            return
        }
        guard server.parts.contains(where: { $0.role == Self.standbyRole }) else { return }
        try await retryUntilReady("standby streaming from \(server.containerName)", timeout: .seconds(120)) {
            let standbys = try await PostgresSession.with(server.endpoint) { try await $0.metadata.listStandbys() }
            guard standbys.contains(where: { $0.applicationName == Self.standbyRole && $0.state == "streaming" }) else {
                throw ServerLabError.notReady("standby", lastError: "primary lists \(standbys.map { "\($0.applicationName) \($0.state)" })")
            }
        }
    }

    public func promote(_ role: String, of server: LabServer) async throws {
        let part = try server.endpoint(of: role)
        let promoted = try await PostgresSession.with(part) { client in
            try await client.replication.promote(wait: true, waitSeconds: 60)
        }
        guard promoted else { throw ServerLabError.notReady("promotion of \(part.host):\(part.port)", lastError: "pg_promote returned false") }
    }
}
