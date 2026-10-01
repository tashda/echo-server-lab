import Foundation
import ServerLabKit
import SQLServerKit

/// Snapshot replication on one instance (needs Agent): the instance as its own distributor,
/// `SalesHub` published as `LabSnapshot` (Customers, Orders) and pushed to `SalesReplica` on the
/// same instance; both agents run once, so the replica holds the rows.
struct SQLServerReplicationPack: ContentPack {
    let name = "replication"
    let version = 1
    let summary = "A distributor, a snapshot publication with two articles and a push subscription that has run (needs Agent)."

    static let publisher = "SalesHub", subscriber = "SalesReplica", publication = "LabSnapshot"

    func apply(to server: ServerEndpoint, recipe: Recipe, parameters: PackParameters, context: PackContext) async throws {
        guard recipe.settings.agent == true else {
            throw ServerLabError.packRequirement(pack: name, reason: "replication agents run in SQL Server Agent: set agent: true")
        }
        try await SQLServerSession.with(server) { client in
            for database in [Self.publisher, Self.subscriber] { try await client.admin.createDatabase(name: database) }
            let admin = client.admin.scoped(to: Self.publisher)
            try await admin.createTable(name: "Customers", columns: [
                SQLServerColumnDefinition(name: "Id", definition: .standard(.init(dataType: .int, isPrimaryKey: true))),
                SQLServerColumnDefinition(name: "Name", definition: .standard(.init(dataType: .nvarchar(length: .length(80))))),
            ])
            try await admin.createTable(name: "Orders", columns: [
                SQLServerColumnDefinition(name: "Id", definition: .standard(.init(dataType: .int, isPrimaryKey: true))),
                SQLServerColumnDefinition(name: "CustomerId", definition: .standard(.init(dataType: .int))),
                SQLServerColumnDefinition(name: "Total", definition: .standard(.init(dataType: .decimal(precision: 10, scale: 2)))),
            ])
            try await admin.insertRows(into: "Customers", columns: ["Id", "Name"], values: (1...25).map { [.int($0), .nString("Customer \($0)")] })
            try await admin.insertRows(into: "Orders", columns: ["Id", "CustomerId", "Total"],
                                       values: (1...100).map { [.int($0), .int($0 % 25 + 1), .decimal("\($0).50")] })

            let replication = client.replication
            try await replication.configureLocalDistributor(login: server.username, password: server.password,
                                                           snapshotFolder: SQLServerEngine.replicationFolder)
            try await replication.enablePublishing(database: Self.publisher)
            try await replication.createSnapshotPublication(name: Self.publication, database: Self.publisher,
                                                            description: "Customers and orders, by snapshot",
                                                            publisherLogin: server.username, publisherPassword: server.password)
            for table in ["Customers", "Orders"] {
                try await replication.addTableArticle(publication: Self.publication, database: Self.publisher, table: table)
            }
            try await replication.addPushSubscription(publication: Self.publication, database: Self.publisher,
                                                      subscriberDatabase: Self.subscriber, login: server.username, password: server.password)
            // Snapshot first, then the distribution agent applies it.
            for agentType in ["Snapshot", "Distribution"] {
                var found: String?
                for _ in 0..<30 where found == nil {
                    found = try await replication.agentStatus().first { $0.agentType == agentType }?.name
                    if found == nil { try await Task.sleep(for: .seconds(2)) }
                }
                guard let job = found else {
                    throw ServerLabError.packCheckFailed(pack: name, reason: "no \(agentType) agent")
                }
                try await client.agent.startJob(named: job)
                try await retryUntilReady("\(agentType) agent run", timeout: .seconds(240), every: .seconds(3)) {
                    let status = try await replication.agentStatus().first { $0.name == job }?.status
                    guard status == "Succeeded" || status == "Idle" else {
                        throw ServerLabError.packCheckFailed(pack: "replication", reason: "\(agentType) agent is \(status ?? "unknown")")
                    }
                }
            }
        }
        context.log("  \(Self.publication): \(Self.publisher) → \(Self.subscriber)")
    }

    func verify(on server: ServerEndpoint, recipe: Recipe, parameters: PackParameters) async throws {
        let (publications, subscriptions) = try await SQLServerSession.with(server, database: Self.publisher) { client in
            (try await client.replication.listPublications().map(\.name), try await client.replication.listSubscriptions().count)
        }
        let replicated = try await SQLServerSession.with(server, database: Self.subscriber) { client in
            try await client.metadata.tableProperties(database: Self.subscriber, schema: "dbo", table: "Orders").rowCount
        }
        guard publications.contains(Self.publication), subscriptions >= 1, replicated == 100 else {
            throw ServerLabError.packCheckFailed(pack: name, reason: "publications \(publications), \(subscriptions) subscriptions, \(replicated) replicated orders")
        }
    }
}
