import Foundation
import MySQLKit
import ServerLabKit

/// Partitioned tables of every kind: RANGE by year with MAXVALUE, RANGE COLUMNS by date, LIST by
/// region, HASH and KEY, each with rows in several partitions. Parameter: `database`.
struct MySQLPartitioningPack: ContentPack {
    let name = "partitioning"
    let version = 1
    let summary = "RANGE, RANGE COLUMNS, LIST, HASH and KEY partitioned tables with rows."

    static let tables: [(name: String, partitioning: MySQLPartitioning)] = [
        ("sales_by_year", .range(expression: "`sold_year`", partitions: [("p2023", "2024"), ("p2024", "2025"), ("p2025", "2026"), ("pfuture", nil)])),
        ("sales_by_day", .rangeColumns(columns: ["sold_on"], partitions: [("h1", ["'2025-07-01'"]), ("h2", ["'2026-01-01'"]), ("later", ["MAXVALUE"])])),
        ("sales_by_region", .list(expression: "`region_id`", partitions: [("north", ["1", "2"]), ("south", ["3", "4"]), ("other", ["0", "5"])])),
        ("sales_hashed", .hash(expression: "`id`", count: 4)),
        ("sales_keyed", .key(columns: ["id"], count: 3)),
    ]

    func apply(to server: ServerEndpoint, recipe: Recipe, parameters: PackParameters, context: PackContext) async throws {
        let database = try parameters.string("database", default: MySQLDatabasePack.defaultName)
        try await MySQLSession.with(server, database: database) { client in
            try await client.admin.createDatabase(name: database, ifNotExists: true)
            for table in Self.tables {
                // The partitioning columns must be part of every unique key, so they join the primary key.
                try await client.admin.createTable(schema: database, name: table.name, columns: [
                    MySQLColumnDefinition(name: "id", dataType: "INT UNSIGNED", isNullable: false),
                    MySQLColumnDefinition(name: "sold_year", dataType: "SMALLINT", isNullable: false),
                    MySQLColumnDefinition(name: "sold_on", dataType: "DATE", isNullable: false),
                    MySQLColumnDefinition(name: "region_id", dataType: "TINYINT", isNullable: false),
                    MySQLColumnDefinition(name: "amount", dataType: "DECIMAL(10,2)", isNullable: false),
                ], primaryKey: ["id", "sold_year", "sold_on", "region_id"], options: MySQLTableOptions(engine: "InnoDB", partitioning: table.partitioning))
                let rows: [[MySQLInsertValue]] = (1...120).map { index in
                    let year = 2023 + index % 4
                    return [.data(MySQLData(int: index)), .data(MySQLData(int: year)),
                            .data(MySQLData(string: String(format: "%d-%02d-15", 2025 + index % 2, index % 12 + 1))),
                            .data(MySQLData(int: index % 6)), .data(MySQLData(string: "\(index).50"))]
                }
                try await client.bulk.insertValues(into: table.name, schema: database, columns: ["id", "sold_year", "sold_on", "region_id", "amount"], rows: rows)
            }
        }
        context.log("  \(Self.tables.count) partitioned tables")
    }

    func verify(on server: ServerEndpoint, recipe: Recipe, parameters: PackParameters) async throws {
        let database = try parameters.string("database", default: MySQLDatabasePack.defaultName)
        let counts = try await MySQLSession.with(server, database: database) { client in
            var counts: [String: Int] = [:]
            for table in Self.tables { counts[table.name] = try await client.metadata.listPartitions(schema: database, table: table.name).count }
            return counts
        }
        let expected = ["sales_by_year": 4, "sales_by_day": 3, "sales_by_region": 3, "sales_hashed": 4, "sales_keyed": 3]
        guard counts == expected else { throw ServerLabError.packCheckFailed(pack: name, reason: "partitions \(counts)") }
    }
}

/// MariaDB's temporal features: a system-versioned table with history from updates and deletes,
/// and sequences (one cycling). Parameter: `database`.
struct MariaDBTemporalPack: ContentPack {
    let name = "temporal"
    let version = 1
    let summary = "A system-versioned table with history, and sequences (MariaDB)."

    func apply(to server: ServerEndpoint, recipe: Recipe, parameters: PackParameters, context: PackContext) async throws {
        guard recipe.engine == .mariadb else {
            throw ServerLabError.packRequirement(pack: name, reason: "system versioning and sequences are MariaDB's")
        }
        let database = try parameters.string("database", default: MySQLDatabasePack.defaultName)
        try await MySQLSession.with(server, database: database) { client in
            try await client.admin.createDatabase(name: database, ifNotExists: true)
            try await client.admin.createTable(schema: database, name: "prices", columns: [
                MySQLColumnDefinition(name: "sku", dataType: "VARCHAR(20)", isNullable: false),
                MySQLColumnDefinition(name: "price", dataType: "DECIMAL(10,2)", isNullable: false),
            ], primaryKey: ["sku"], options: MySQLTableOptions(engine: "InnoDB", systemVersioning: true))
            try await client.bulk.insertValues(into: "prices", schema: database, columns: ["sku", "price"],
                                               rows: (1...20).map { [.data(MySQLData(string: String(format: "SKU-%03d", $0))), .data(MySQLData(string: "\($0).00"))] })
            // History: two rounds of price changes on a growing share of the rows.
            for round in 1...2 {
                for item in 1...(round * 5) {
                    try await client.bulk.updateRows(in: "prices", schema: database,
                                                     set: ["price": .data(MySQLData(string: "\(item * 2 + round).00"))],
                                                     where: ["sku": .data(MySQLData(string: String(format: "SKU-%03d", item)))])
                }
            }
            try await client.bulk.deleteRows(from: "prices", schema: database, where: ["sku": .data(MySQLData(string: "SKU-020"))])
            try await client.admin.createSequence(schema: database, name: "order_numbers", start: 1000, increment: 1, cache: 20)
            try await client.admin.createSequence(schema: database, name: "ticket_wheel", start: 1, increment: 1, minValue: 1, maxValue: 10, cycle: true)
        }
        context.log("  prices with system versioning and history, 2 sequences")
    }

    func verify(on server: ServerEndpoint, recipe: Recipe, parameters: PackParameters) async throws {
        let database = try parameters.string("database", default: MySQLDatabasePack.defaultName)
        let (versioned, sequences) = try await MySQLSession.with(server, database: database) { client in
            (try await client.metadata.listSystemVersionedTables(schema: database), try await client.metadata.listSequences(schema: database))
        }
        guard versioned == ["prices"], Set(sequences) == ["order_numbers", "ticket_wheel"] else {
            throw ServerLabError.packCheckFailed(pack: name, reason: "versioned \(versioned), sequences \(sequences)")
        }
    }
}
