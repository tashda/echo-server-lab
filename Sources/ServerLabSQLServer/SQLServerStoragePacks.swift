import Foundation
import ServerLabKit
import SQLServerKit

/// A date partition function (RIGHT) and an int one (LEFT), their schemes, and a partitioned table
/// with rows in every partition. Parameters: `database` (default `LabData`).
struct SQLServerPartitioningPack: ContentPack {
    let name = "partitioning"
    let version = 1
    let summary = "Partition functions (RANGE LEFT and RIGHT), schemes and a partitioned table with rows in every partition."

    func apply(to server: ServerEndpoint, recipe: Recipe, parameters: PackParameters, context: PackContext) async throws {
        let database = try parameters.string("database", default: SQLServerDatabasePack.defaultName)
        try await SQLServerSession.with(server, database: database) { client in
            try await client.security.createSchema(name: Self.schema)
            try await client.withConnection { connection in
                try await connection.createPartitionFunction(name: "pfOrderYear", dataType: .date, boundaryOnRight: true,
                                                             values: ["'2023-01-01'", "'2024-01-01'", "'2025-01-01'", "'2026-01-01'"])
                try await connection.createPartitionScheme(name: "psOrderYear", functionName: "pfOrderYear")
                try await connection.createPartitionFunction(name: "pfTenant", dataType: .int, boundaryOnRight: false, values: ["100", "200", "300"])
                try await connection.createPartitionScheme(name: "psTenant", functionName: "pfTenant")
                try await connection.createPartitionedTable(name: "OrdersByYear", columns: [
                    SQLServerColumnDefinition(name: "Id", definition: .standard(.init(dataType: .int, isPrimaryKey: true))),
                    SQLServerColumnDefinition(name: "OrderDate", definition: .standard(.init(dataType: .date, isPrimaryKey: true))),
                    SQLServerColumnDefinition(name: "Total", definition: .standard(.init(dataType: .decimal(precision: 12, scale: 2)))),
                ], partitionScheme: "psOrderYear", partitionColumn: "OrderDate", schema: Self.schema)
            }
            let years = ["2022", "2023", "2024", "2025", "2026"]
            try await client.admin.scoped(to: database).insertRows(into: "OrdersByYear", schema: Self.schema,
                                                                   columns: ["Id", "OrderDate", "Total"], values: (1...250).map {
                [.int($0), .string("\(years[$0 % years.count])-\(String(format: "%02d", $0 % 12 + 1))-15"), .decimal("\($0 * 3).50")]
            })
        }
        context.log("  2 partition functions and schemes, OrdersByYear across 5 partitions")
    }

    func verify(on server: ServerEndpoint, recipe: Recipe, parameters: PackParameters) async throws {
        let database = try parameters.string("database", default: SQLServerDatabasePack.defaultName)
        let properties = try await SQLServerSession.with(server, database: database) { client in
            try await client.metadata.tableProperties(database: database, schema: Self.schema, table: "OrdersByYear")
        }
        guard properties.isPartitioned == true, properties.partitionCount == 5, properties.rowCount == 250 else {
            throw ServerLabError.packCheckFailed(pack: name, reason: "partitioned \(String(describing: properties.isPartitioned)), \(String(describing: properties.partitionCount)) partitions, \(properties.rowCount) rows")
        }
    }

    static let schema = "archive"
}

/// A system-versioned table with a named history table, updated and deleted so the history holds rows.
/// Parameters: `database` (default `LabData`).
struct SQLServerTemporalPack: ContentPack {
    let name = "temporal"
    let version = 1
    let summary = "A system-versioned (temporal) table with a named history table that already holds history."

    func apply(to server: ServerEndpoint, recipe: Recipe, parameters: PackParameters, context: PackContext) async throws {
        let database = try parameters.string("database", default: SQLServerDatabasePack.defaultName)
        try await SQLServerSession.with(server, database: database) { client in
            try await client.security.createSchema(name: Self.schema)
            try await client.withConnection { connection in
                try await connection.createTable(name: "Prices", columns: [
                    SQLServerColumnDefinition(name: "Sku", definition: .standard(.init(dataType: .varchar(length: .length(20)), isPrimaryKey: true))),
                    SQLServerColumnDefinition(name: "Price", definition: .standard(.init(dataType: .decimal(precision: 10, scale: 2)))),
                ], schema: Self.schema)
            }
            let admin = client.admin.scoped(to: database)
            try await admin.insertRows(into: "Prices", schema: Self.schema, columns: ["Sku", "Price"],
                                       values: (1...30).map { [.string(String(format: "SKU-%03d", $0)), .decimal("\($0).00")] })
            try await client.temporal.addPeriodColumnsAndEnableVersioning(database: database, schema: Self.schema, table: "Prices",
                                                                          historySchema: Self.schema, historyTable: "PricesHistory")
            for round in 1...3 {
                _ = try await admin.updateRows(in: "Prices", schema: Self.schema, set: ["Price": .raw("Price * 1.1")],
                                               where: "Sku <= 'SKU-0\(round)0'")
            }
            _ = try await admin.deleteRows(from: "Prices", schema: Self.schema, where: "Sku = 'SKU-030'")
        }
        context.log("  Prices system-versioned into PricesHistory, 3 rounds of updates and a delete")
    }

    func verify(on server: ServerEndpoint, recipe: Recipe, parameters: PackParameters) async throws {
        let database = try parameters.string("database", default: SQLServerDatabasePack.defaultName)
        let (tables, history) = try await SQLServerSession.with(server, database: database) { client in
            (
                try await client.temporal.listSystemVersionedTables(database: database),
                try await client.metadata.tableProperties(database: database, schema: Self.schema, table: "PricesHistory").rowCount
            )
        }
        guard tables.contains(where: { $0.name == "Prices" }), history > 0 else {
            throw ServerLabError.packCheckFailed(pack: name, reason: "\(tables.count) temporal tables, \(history) history rows")
        }
    }

    static let schema = "pricing"
}

/// Linked servers: one back to the same instance (queries through it work), one to a host that does
/// not exist (for error handling). Provider SQLNCLI on 2017, MSOLEDBSQL from 2019.
struct SQLServerLinkedServersPack: ContentPack {
    let name = "linked-servers"
    let version = 1
    let summary = "A working loopback linked server with a login mapping, and one pointing at a host that does not exist."

    func apply(to server: ServerEndpoint, recipe: Recipe, parameters: PackParameters, context: PackContext) async throws {
        let provider = recipe.version == "2017" ? "SQLNCLI" : "MSOLEDBSQL"
        try await SQLServerSession.with(server) { client in
            try await client.linkedServers.add(name: "LAB_LOOPBACK", provider: provider, dataSource: "127.0.0.1,1433")
            try await client.linkedServers.addLoginMapping(serverName: "LAB_LOOPBACK", remoteUser: server.username, remotePassword: server.password)
            try await client.linkedServers.add(name: "LAB_UNREACHABLE", provider: provider, dataSource: "unreachable.invalid,1433")
        }
        context.log("  LAB_LOOPBACK (\(provider)) and LAB_UNREACHABLE")
    }

    func verify(on server: ServerEndpoint, recipe: Recipe, parameters: PackParameters) async throws {
        let (names, loopbackWorks) = try await SQLServerSession.with(server) { client in
            (Set(try await client.linkedServers.list().map(\.name)), try await client.linkedServers.test(name: "LAB_LOOPBACK"))
        }
        guard names.isSuperset(of: ["LAB_LOOPBACK", "LAB_UNREACHABLE"]), loopbackWorks else {
            throw ServerLabError.packCheckFailed(pack: name, reason: "linked servers \(names.sorted()), loopback works: \(loopbackWorks)")
        }
    }
}
