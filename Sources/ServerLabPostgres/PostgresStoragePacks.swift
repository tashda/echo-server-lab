import Foundation
import PostgresKit
import ServerLabKit

/// Declarative partitioning: a range-partitioned table with a default partition, a list-partitioned
/// and a hash-partitioned table, all with rows in every partition. Parameters: `database`.
struct PostgresPartitioningPack: ContentPack {
    let name = "partitioning"
    let version = 1
    let summary = "Range (with default), list and hash partitioned tables with rows in every partition."

    func apply(to server: ServerEndpoint, recipe: Recipe, parameters: PackParameters, log: LabLog) async throws {
        let database = try parameters.string("database", default: PostgresDatabasePack.defaultName)
        try await PostgresSession.with(server, database: database) { client in
            let admin = client.admin
            _ = try await admin.createSchema(name: Self.schema)
            _ = try await admin.createPartitionedTable(name: "orders", schema: Self.schema, columns: [
                PostgresColumnDefinition(name: "id", dataType: "integer", nullable: false),
                PostgresColumnDefinition(name: "ordered_on", dataType: "date", nullable: false),
                PostgresColumnDefinition(name: "total", dataType: "numeric(12,2)", nullable: false),
            ], partitionBy: .range, partitionColumns: ["ordered_on"])
            for year in 2023...2026 {
                _ = try await admin.createPartition(name: "orders_\(year)", schema: Self.schema, parentTable: "orders", parentSchema: Self.schema,
                                                    bound: "FOR VALUES FROM ('\(year)-01-01') TO ('\(year + 1)-01-01')")
            }
            _ = try await admin.createPartition(name: "orders_other", schema: Self.schema, parentTable: "orders", parentSchema: Self.schema, bound: "DEFAULT")
            _ = try await client.bulk.insert(into: "orders", schema: Self.schema, columns: ["id", "ordered_on", "total"], values: (1...250).map {
                [PostgresInsertValue($0), .sql("'\(2022 + $0 % 5)-\(String(format: "%02d", $0 % 12 + 1))-15'::date"), .sql("\($0 * 3).50")]
            })

            _ = try await admin.createPartitionedTable(name: "customers_by_region", schema: Self.schema, columns: [
                PostgresColumnDefinition(name: "id", dataType: "integer", nullable: false),
                PostgresColumnDefinition(name: "region", dataType: "text", nullable: false),
            ], partitionBy: .list, partitionColumns: ["region"])
            for (partition, regions) in [("customers_nordic", "'dk', 'se', 'no'"), ("customers_other", "'de', 'fr', 'us'")] {
                _ = try await admin.createPartition(name: partition, schema: Self.schema, parentTable: "customers_by_region",
                                                    parentSchema: Self.schema, bound: "FOR VALUES IN (\(regions))")
            }
            _ = try await client.bulk.insert(into: "customers_by_region", schema: Self.schema, columns: ["id", "region"], values: (1...60).map {
                [PostgresInsertValue($0), PostgresInsertValue(["dk", "se", "no", "de", "fr", "us"][$0 % 6])]
            })

            _ = try await admin.createPartitionedTable(name: "events", schema: Self.schema, columns: [
                PostgresColumnDefinition(name: "id", dataType: "bigint", nullable: false),
                PostgresColumnDefinition(name: "payload", dataType: "jsonb"),
            ], partitionBy: .hash, partitionColumns: ["id"])
            for remainder in 0..<4 {
                _ = try await admin.createPartition(name: "events_\(remainder)", schema: Self.schema, parentTable: "events", parentSchema: Self.schema,
                                                    bound: "FOR VALUES WITH (MODULUS 4, REMAINDER \(remainder))")
            }
            _ = try await client.bulk.insert(into: "events", schema: Self.schema, columns: ["id", "payload"], values: (1...200).map {
                [PostgresInsertValue($0), .jsonbLiteral(#"{"n": \#($0)}"#)]
            })
        }
        log("  orders by range (5 partitions incl. default), customers by list, events by hash")
    }

    func verify(on server: ServerEndpoint, recipe: Recipe, parameters: PackParameters) async throws {
        let database = try parameters.string("database", default: PostgresDatabasePack.defaultName)
        let (partitions, rows) = try await PostgresSession.with(server, database: database) { client in
            (
                try await client.metadata.listPartitions(schema: Self.schema, table: "orders").count,
                try await client.metadata.exactRowCount(schema: Self.schema, table: "orders")
            )
        }
        guard partitions == 5, rows == 250 else {
            throw ServerLabError.packCheckFailed(pack: name, reason: "\(partitions) partitions of orders, \(rows) rows")
        }
    }

    static let schema = "archive"
}

/// The contrib extensions in use (citext, hstore, ltree, pg_trgm, uuid-ossp, pgcrypto, btree_gist,
/// intarray, fuzzystrmatch, tablefunc, unaccent, cube and earthdistance) plus postgres_fdw with a
/// loopback server, a user mapping and a foreign table that answers. Parameters: `database`.
struct PostgresExtensionsPack: ContentPack {
    let name = "extensions"
    let version = 1
    let summary = "Contrib extensions used by real columns and indexes, and a loopback postgres_fdw foreign table."

    static let extensions = ["citext", "hstore", "ltree", "pg_trgm", "uuid-ossp", "pgcrypto", "btree_gist", "intarray",
                             "fuzzystrmatch", "tablefunc", "unaccent", "cube", "earthdistance", "postgres_fdw"]

    func apply(to server: ServerEndpoint, recipe: Recipe, parameters: PackParameters, log: LabLog) async throws {
        let database = try parameters.string("database", default: PostgresDatabasePack.defaultName)
        try await PostgresSession.with(server, database: database) { client in
            for extensionName in Self.extensions {
                _ = try await client.maintenance.createExtension(extensionName, cascade: true)
            }
            let admin = client.admin
            _ = try await admin.createSchema(name: Self.schema)
            _ = try await admin.createTable(name: "catalog_items", schema: Self.schema, columns: [
                PostgresColumnDefinition(name: "id", dataType: "uuid", nullable: false, defaultValue: "uuid_generate_v4()", primaryKey: true),
                PostgresColumnDefinition(name: "email", dataType: "citext", nullable: false),
                PostgresColumnDefinition(name: "attributes", dataType: "hstore"),
                PostgresColumnDefinition(name: "category_path", dataType: "ltree"),
                PostgresColumnDefinition(name: "title", dataType: "text", nullable: false),
                PostgresColumnDefinition(name: "tags", dataType: "integer[]"),
                PostgresColumnDefinition(name: "secret", dataType: "bytea"),
            ])
            _ = try await client.bulk.insert(into: "catalog_items", schema: Self.schema,
                                             columns: ["email", "attributes", "category_path", "title", "tags", "secret"], values: (1...100).map {
                [
                    PostgresInsertValue("Item\($0)@Example.COM"),
                    .sql("'color => \(["red", "blue"][$0 % 2]), size => \($0 % 5)'::hstore"),
                    .sql("'shop.\(["garden", "kitchen", "tools"][$0 % 3]).level\($0 % 4)'::ltree"),
                    PostgresInsertValue("Café item \($0) crème brûlée"),
                    .sql("ARRAY[\($0 % 7), \($0 % 11), \($0 % 13)]"),
                    .sql("pgp_sym_encrypt('secret \($0)', 'lab')"),
                ]
            })
            let indexes = client.indexes
            _ = try await indexes.createAdvancedIndex(name: "catalog_items_title_trgm", table: "catalog_items", schema: Self.schema,
                                                      columns: [PostgresIndexColumn(name: "title", operatorClass: "gin_trgm_ops")], indexType: .gin)
            _ = try await indexes.createAdvancedIndex(name: "catalog_items_path", table: "catalog_items", schema: Self.schema,
                                                      columns: [PostgresIndexColumn(name: "category_path")], indexType: .gist)
            _ = try await indexes.createAdvancedIndex(name: "catalog_items_attributes", table: "catalog_items", schema: Self.schema,
                                                      columns: [PostgresIndexColumn(name: "attributes")], indexType: .gin)

            // postgres_fdw back to this server: a foreign table over catalog_items.
            _ = try await admin.createForeignServer(name: "lab_loopback", fdwName: "postgres_fdw",
                                                    options: ["host": "127.0.0.1", "port": "5432", "dbname": database])
            _ = try await admin.createUserMapping(serverName: "lab_loopback", userName: server.username,
                                                  options: ["user": server.username, "password": server.password])
            _ = try await admin.createForeignTable(name: "remote_catalog_items", schema: Self.schema, serverName: "lab_loopback", columns: [
                PostgresColumnDefinition(name: "email", dataType: "citext"),
                PostgresColumnDefinition(name: "title", dataType: "text"),
            ], options: ["schema_name": Self.schema, "table_name": "catalog_items"])
        }
        log("  \(Self.extensions.count) extensions, catalog_items using them, postgres_fdw loopback foreign table")
    }

    func verify(on server: ServerEndpoint, recipe: Recipe, parameters: PackParameters) async throws {
        let database = try parameters.string("database", default: PostgresDatabasePack.defaultName)
        let (installed, remoteRows) = try await PostgresSession.with(server, database: database) { client in
            (
                Set(try await client.metadata.listExtensions().map(\.name)),
                try await client.metadata.exactRowCount(schema: Self.schema, table: "remote_catalog_items")
            )
        }
        for extensionName in Self.extensions where !installed.contains(extensionName) {
            throw ServerLabError.packCheckFailed(pack: name, reason: "extension \(extensionName) is missing")
        }
        guard remoteRows == 100 else {
            throw ServerLabError.packCheckFailed(pack: name, reason: "the foreign table returned \(remoteRows) rows, expected 100")
        }
    }

    static let schema = "ext"
}
