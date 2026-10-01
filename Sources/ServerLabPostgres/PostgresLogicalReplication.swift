import Foundation
import PostgresKit
import ServerLabKit

/// `publisher-subscriber`: logical replication. The seeded server publishes (`wal_level=logical`)
/// the table `replicated_items` in labdata; a fresh subscriber gets the same table, subscribes,
/// and receives the existing rows (copy_data) and every change after.
extension PostgresEngine {
    static let publisherSubscriber = "publisher-subscriber"
    static let publisherRole = "publisher"
    static let subscriberRole = "subscriber"
    static let publication = "lab_publication"
    static let subscription = "lab_subscription"
    static let replicatedTable = "replicated_items"

    func logicalTopology(for recipe: Recipe, setup: ServerSetup) throws -> ServerTopology {
        guard setup.tls == nil, setup.kerberos == nil else {
            throw ServerLabError.unsupported("TLS or Kerberos on a publisher-subscriber server")
        }
        let subscriber = try containerSpec(for: recipe, password: setup.password)
        return ServerTopology(mainRole: Self.publisherRole, parts: [ServerPartSpec(role: Self.subscriberRole, container: subscriber)])
    }

    static let replicatedColumns = [
        PostgresColumnDefinition(name: "id", dataType: "integer", nullable: false, primaryKey: true),
        PostgresColumnDefinition(name: "label", dataType: "text"),
        PostgresColumnDefinition(name: "changed_at", dataType: "timestamptz"),
    ]

    func connectSubscriber(of server: LabServer) async throws {
        try await PostgresSession.with(server.endpoint) { client in
            if try await !client.metadata.listDatabases().contains(PostgresDatabasePack.defaultName) {
                try await client.admin.createDatabase(name: PostgresDatabasePack.defaultName)
            }
        }
        try await PostgresSession.with(server.endpoint, database: PostgresDatabasePack.defaultName) { client in
            try await client.admin.createTable(name: Self.replicatedTable, columns: Self.replicatedColumns)
            try await client.bulk.insert(into: Self.replicatedTable, columns: ["id", "label"],
                                         values: (1...10).map { [PostgresInsertValue($0), PostgresInsertValue("item \($0)")] })
            try await client.replication.createPublication(name: Self.publication, tables: [Self.replicatedTable])
        }
        let subscriber = try server.endpoint(of: Self.subscriberRole)
        try await PostgresSession.with(subscriber) { client in
            try await client.admin.createDatabase(name: PostgresDatabasePack.defaultName)
        }
        try await PostgresSession.with(subscriber, database: PostgresDatabasePack.defaultName) { client in
            try await client.admin.createTable(name: Self.replicatedTable, columns: Self.replicatedColumns)
            try await client.replication.createSubscription(
                name: Self.subscription,
                connectionString: "host=\(Self.publisherRole) port=5432 dbname=\(PostgresDatabasePack.defaultName) user=\(server.username) password=\(server.password)",
                publications: [Self.publication]
            )
        }
        try await retryUntilReady("subscriber of \(server.containerName)", timeout: .seconds(90), every: .milliseconds(500)) {
            let rows = try await PostgresSession.with(subscriber, database: PostgresDatabasePack.defaultName) {
                try await $0.metadata.exactRowCount(table: Self.replicatedTable)
            }
            guard rows == 10 else { throw ServerLabError.notReady("initial copy", lastError: "\(rows) of 10 rows") }
        }
    }
}
