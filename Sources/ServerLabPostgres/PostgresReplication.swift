import Foundation
import PostgresKit
import ServerLabKit

/// `primary-standby`: the seeded server as primary, and a hot standby that clones it with
/// `pg_basebackup` when it first starts and then streams from it through a replication slot.
extension PostgresEngine {
    static let primaryStandby = "primary-standby"
    static let hbaFile = "/labconf/pg_hba.conf"
    static let standbyRole = "standby"

    public func topology(for recipe: Recipe, password: String) throws -> ServerTopology {
        switch recipe.settings.topology {
        case nil:
            return .single
        case Self.primaryStandby?:
            let spec = try containerSpec(for: recipe, password: password)
            let hba = Data("""
                local all all trust
                host all all all scram-sha-256
                host replication all all scram-sha-256

                """.utf8)
            let settings = spec.command.dropFirst() + ["-c", "hba_file=\(Self.hbaFile)"]
            // Runs as root in the base image; the `if` keeps the clone when the standby is restarted.
            let script = """
                set -e
                mkdir -p /labdata/pgdata && chown postgres:postgres /labdata/pgdata && chmod 700 /labdata/pgdata
                if [ ! -s /labdata/pgdata/PG_VERSION ]; then
                  gosu postgres pg_basebackup -d "host=primary port=5432 user=postgres application_name=\(Self.standbyRole)" \\
                    -D /labdata/pgdata -R -X stream -C -S \(Self.standbyRole)
                fi
                exec gosu postgres postgres -D /labdata/pgdata \(settings.joined(separator: " "))
                """
            let standby = ContainerSpec(
                image: spec.image, internalPort: 5432,
                environment: ["PGPASSWORD": password, "PGDATA": "/labdata/pgdata"],
                command: ["bash", "-c", script],
                memoryMB: spec.memoryMB,
                files: [Self.hbaFile: hba]
            )
            return ServerTopology(
                mainRole: "primary",
                mainFiles: [Self.hbaFile: hba],
                mainArguments: ["-c", "hba_file=\(Self.hbaFile)"],
                parts: [ServerPartSpec(role: Self.standbyRole, container: standby)]
            )
        case let other?:
            throw ServerLabError.unsupported("Topology '\(other)' on PostgreSQL (use \(Self.primaryStandby))")
        }
    }

    public func waitUntilTopologyReady(_ server: LabServer) async throws {
        guard server.parts.contains(where: { $0.role == Self.standbyRole }) else { return }
        try await retryUntilReady("standby streaming from \(server.containerName)", timeout: .seconds(120)) {
            let standbys = try await PostgresSession.with(server.endpoint) { try await $0.metadata.listStandbys() }
            guard standbys.contains(where: { $0.applicationName == Self.standbyRole && $0.state == "streaming" }) else {
                throw ServerLabError.notReady("standby", lastError: "primary lists \(standbys.map { "\($0.applicationName) \($0.state)" })")
            }
        }
    }

    public func promote(_ part: ServerEndpoint) async throws {
        let promoted = try await PostgresSession.with(part) { client in
            try await client.replication.promote(wait: true, waitSeconds: 60)
        }
        guard promoted else { throw ServerLabError.notReady("promotion of \(part.host):\(part.port)", lastError: "pg_promote returned false") }
    }
}
