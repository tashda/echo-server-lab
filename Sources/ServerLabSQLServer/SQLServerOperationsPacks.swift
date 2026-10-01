import Foundation
import ServerLabKit
import SQLServerKit

private let dataDirectory = "/var/opt/mssql/data"

/// Backup history of every kind for one database in FULL recovery: full (compressed, checksum),
/// differential, log, copy-only, striped over two files and one verified. Parameter: `database`
/// (default BackedUp).
struct SQLServerBackupsPack: ContentPack {
    let name = "backups"
    let version = 1
    let summary = "Full, differential, log, copy-only, compressed and striped backups in the history."

    func apply(to server: ServerEndpoint, recipe: Recipe, parameters: PackParameters, context: PackContext) async throws {
        let database = try parameters.string("database", default: "BackedUp")
        try await SQLServerSession.with(server) { client in
            try await client.admin.createDatabase(name: database)
            try await client.admin.alterDatabaseOption(name: database, option: .recoveryModel(.full))
            let admin = client.admin.scoped(to: database)
            try await admin.createTable(name: "Ledger", columns: [
                SQLServerColumnDefinition(name: "Id", definition: .standard(.init(dataType: .int, isPrimaryKey: true, identity: (1, 1)))),
                SQLServerColumnDefinition(name: "Entry", definition: .standard(.init(dataType: .nvarchar(length: .length(50))))),
            ])
            func file(_ suffix: String) -> SQLServerBackupDestination { .disk(path: "\(dataDirectory)/\(database)_\(suffix).bak") }
            func addRows(_ label: String) async throws {
                try await admin.insertRows(into: "Ledger", columns: ["Entry"], values: (1...10).map { [.nString("\(label) \($0)")] })
            }
            let backups = client.backupRestore
            try await addRows("before full")
            try await backups.backup(options: SQLServerBackupOptions(
                database: database, destinations: [file("full")], backupName: "Lab full", description: "Full, compressed, with checksum",
                compression: true, checksum: true, initMedia: true))
            try await addRows("before differential")
            try await backups.backup(options: SQLServerBackupOptions(
                database: database, destinations: [file("diff")], backupType: .differential, backupName: "Lab differential", initMedia: true))
            try await addRows("before log")
            try await backups.backup(options: SQLServerBackupOptions(
                database: database, destinations: [file("log")], backupType: .log, backupName: "Lab log", initMedia: true))
            try await backups.backup(options: SQLServerBackupOptions(
                database: database, destinations: [file("copy")], backupName: "Lab copy-only", copyOnly: true, initMedia: true))
            try await backups.backup(options: SQLServerBackupOptions(
                database: database, destinations: [file("stripe1"), file("stripe2")], backupName: "Lab striped",
                initMedia: true, verifyAfterBackup: true))
        }
        context.log("  5 backups of \(database)")
    }

    func verify(on server: ServerEndpoint, recipe: Recipe, parameters: PackParameters) async throws {
        let database = try parameters.string("database", default: "BackedUp")
        let history = try await SQLServerSession.with(server) { try await $0.backupRestore.getBackupHistory(database: database) }
        let names = Set(history.compactMap(\.name))
        let expected: Set = ["Lab full", "Lab differential", "Lab log", "Lab copy-only", "Lab striped"]
        guard expected.isSubset(of: names) else {
            throw ServerLabError.packCheckFailed(pack: name, reason: "history has \(names.sorted())")
        }
    }
}

/// Service Broker in one database: message types (no validation, empty, well-formed XML),
/// contracts, an active queue holding three unread messages on open conversations, a disabled
/// queue, a queue with retention and activation, services and a route to a remote broker.
/// Parameter: `database` (default BrokerLab).
struct SQLServerServiceBrokerPack: ContentPack {
    let name = "service-broker"
    let version = 1
    let summary = "Message types, contracts, queues (active, disabled, activated) with waiting messages, services and a route."

    func apply(to server: ServerEndpoint, recipe: Recipe, parameters: PackParameters, context: PackContext) async throws {
        let database = try parameters.string("database", default: "BrokerLab")
        try await SQLServerSession.with(server) { client in
            try await client.admin.createDatabase(name: database)
            try await client.admin.alterDatabaseOption(name: database, option: .brokerEnabled(true))
        }
        try await SQLServerSession.with(server, database: database) { client in
            let broker = client.serviceBroker
            try await broker.createMessageType(database: database, name: "//lab/Order", validation: .wellFormedXML)
            try await broker.createMessageType(database: database, name: "//lab/Ping", validation: .empty)
            try await broker.createMessageType(database: database, name: "//lab/Note", validation: .none)
            try await broker.createContract(database: database, name: "//lab/OrderContract",
                                            messageUsages: [("//lab/Order", .initiator), ("//lab/Note", .any)])
            try await broker.createContract(database: database, name: "//lab/PingContract", messageUsages: [("//lab/Ping", .initiator)])
            try await client.routines.createStoredProcedure(
                name: "usp_LeaveAuditMessages", parameters: [], body: "SET NOCOUNT ON; RETURN 0;", schema: "dbo")
            try await broker.createQueue(database: database, name: "OrderQueue")
            try await broker.createQueue(database: database, name: "ClientQueue")
            try await broker.createQueue(database: database, name: "PausedQueue", options: .init(status: false))
            try await broker.createQueue(database: database, name: "AuditQueue", options: .init(
                retention: true, activationEnabled: true, activationProcedure: "usp_LeaveAuditMessages", maxQueueReaders: 2,
                executeAs: "OWNER", poisonMessageHandling: false, activationProcedureSchema: "dbo"))
            try await broker.createService(database: database, name: "//lab/OrderService", queue: "OrderQueue",
                                           contracts: ["//lab/OrderContract", "//lab/PingContract"])
            try await broker.createService(database: database, name: "//lab/ClientService", queue: "ClientQueue")
            try await broker.createService(database: database, name: "//lab/AuditService", queue: "AuditQueue")
            try await broker.createRoute(database: database, name: "RemoteWarehouse", address: "TCP://warehouse.lab.test:4022",
                                         serviceName: "//warehouse/StockService", lifetime: 86_400)
            for order in 1...3 {
                try await broker.send(database: database, fromService: "//lab/ClientService", toService: "//lab/OrderService",
                                      contract: "//lab/OrderContract", messageType: "//lab/Order", body: "<order id=\"\(order)\"/>")
            }
        }
        context.log("  broker objects in \(database), 3 messages waiting")
    }

    func verify(on server: ServerEndpoint, recipe: Recipe, parameters: PackParameters) async throws {
        let database = try parameters.string("database", default: "BrokerLab")
        let (waiting, queues, routes) = try await SQLServerSession.with(server, database: database) { client in
            (try await client.serviceBroker.messageCount(database: database, queue: "OrderQueue"),
             try await client.serviceBroker.listQueues(database: database).count,
             try await client.serviceBroker.listRoutes(database: database).map(\.name))
        }
        guard waiting == 3, queues >= 4, routes.contains("RemoteWarehouse") else {
            throw ServerLabError.packCheckFailed(pack: name, reason: "\(waiting) waiting, \(queues) queues, routes \(routes)")
        }
    }
}

/// Query Store on in one database, capturing everything, with captured queries and plans and
/// one forced plan, flushed to disk. Parameter: `database` (default QueryStoreLab).
struct SQLServerQueryStorePack: ContentPack {
    let name = "query-store"
    let version = 1
    let summary = "Query Store with captured queries, plans and a forced plan."

    func apply(to server: ServerEndpoint, recipe: Recipe, parameters: PackParameters, context: PackContext) async throws {
        let database = try parameters.string("database", default: "QueryStoreLab")
        try await SQLServerSession.with(server) { client in
            try await client.admin.createDatabase(name: database)
            try await client.queryStore.setEnabled(database: database, enabled: true)
            try await client.queryStore.alterOption(database: database, option: .queryCaptureMode(.all))
            try await client.admin.scoped(to: database).createTable(name: "Readings", columns: [
                SQLServerColumnDefinition(name: "Id", definition: .standard(.init(dataType: .int, isPrimaryKey: true, identity: (1, 1)))),
                SQLServerColumnDefinition(name: "Value", definition: .standard(.init(dataType: .int))),
            ])
            try await client.admin.scoped(to: database).insertRows(into: "Readings", columns: ["Value"], values: (1...200).map { [.int($0)] })
        }
        // The driver's own metadata queries in the database are what Query Store captures.
        try await SQLServerSession.with(server, database: database) { client in
            for _ in 1...5 {
                _ = try await client.metadata.tableProperties(database: database, schema: "dbo", table: "Readings")
            }
            let store = client.queryStore
            try await store.flush(database: database)
            for query in try await store.topQueries(database: database, limit: 10) {
                guard let plan = try await store.queryPlans(database: database, queryId: query.queryId).first else { continue }
                try await store.forcePlan(database: database, queryId: query.queryId, planId: plan.planId)
                break
            }
            try await store.flush(database: database)
        }
        context.log("  Query Store on in \(database) with a forced plan")
    }

    func verify(on server: ServerEndpoint, recipe: Recipe, parameters: PackParameters) async throws {
        let database = try parameters.string("database", default: "QueryStoreLab")
        let forced = try await SQLServerSession.with(server, database: database) { client in
            var forced = 0
            for query in try await client.queryStore.topQueries(database: database, limit: 20) {
                forced += try await client.queryStore.queryPlans(database: database, queryId: query.queryId).filter(\.isForcedPlan).count
            }
            return forced
        }
        guard forced >= 1 else { throw ServerLabError.packCheckFailed(pack: name, reason: "no forced plan") }
    }
}
