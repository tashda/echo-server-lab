import Foundation
import ServerLabKit
import SQLServerKit

/// A `shop` schema with every kind of index and constraint: composite and self-referencing foreign
/// keys (cascade, not trusted), check constraints (one not checked against existing rows), unique
/// and default constraints; plain, composite descending, covering, filtered, unique, compressed,
/// clustered and columnstore indexes, and a heap.
///
/// Parameters: `database` (default `LabData`), `products` (rows, default 200).
struct SQLServerIndexesPack: ContentPack {
    let name = "indexes-constraints"
    let version = 1
    let summary = "Every index kind (filtered, covering, columnstore, compressed) and constraint kind (FK cascade, untrusted, check, unique, default)."

    func apply(to server: ServerEndpoint, recipe: Recipe, parameters: PackParameters, context: PackContext) async throws {
        let database = try parameters.string("database", default: SQLServerDatabasePack.defaultName)
        let products = max(try parameters.int("products", default: 200), 10)
        try await SQLServerSession.with(server, database: database) { client in
            try await client.security.createSchema(name: Self.schema)
            try await Self.createTables(client)
            try await Self.fill(client, database: database, products: products)
            try await Self.addConstraints(client)
            try await Self.createIndexes(client)
        }
        context.log("  shop: 6 tables, 4 foreign keys, checks, unique and default constraints, 9 indexes")
    }

    func verify(on server: ServerEndpoint, recipe: Recipe, parameters: PackParameters) async throws {
        let database = try parameters.string("database", default: SQLServerDatabasePack.defaultName)
        let (productIndexes, productKeys, lineKeys, nodeKeys, checks, uniques) = try await SQLServerSession.with(server, database: database) { client in
            (
                try await client.metadata.listIndexes(database: database, schema: Self.schema, table: "Products").count,
                try await client.metadata.listForeignKeys(database: database, schema: Self.schema, table: "Products").count,
                try await client.metadata.listForeignKeys(database: database, schema: Self.schema, table: "OrderLines").count,
                try await client.metadata.listForeignKeys(database: database, schema: Self.schema, table: "CategoryTree").count,
                try await client.constraints.listCheckConstraints(database: database, schema: Self.schema, table: "Products").count,
                try await client.metadata.listUniqueConstraints(database: database, schema: Self.schema, table: "Products").count
            )
        }
        let found = ["Products indexes": productIndexes, "Products foreign keys": productKeys, "OrderLines foreign keys": lineKeys,
                     "CategoryTree foreign keys": nodeKeys, "check constraints": checks, "unique constraints": uniques]
        let expected = ["Products indexes": 7, "Products foreign keys": 1, "OrderLines foreign keys": 2,
                        "CategoryTree foreign keys": 1, "check constraints": 2, "unique constraints": 1]
        for (kind, count) in expected where (found[kind] ?? 0) < count {
            throw ServerLabError.packCheckFailed(pack: name, reason: "\(found[kind] ?? 0) \(kind), expected at least \(count)")
        }
    }

    static let schema = "shop"

    private static func column(_ name: String, _ type: SQLDataType, nullable: Bool = false, key: Bool = false, identity: Bool = false) -> SQLServerColumnDefinition {
        SQLServerColumnDefinition(name: name, definition: .standard(.init(dataType: type, isNullable: nullable, isPrimaryKey: key, identity: identity ? (1, 1) : nil)))
    }

    private static func createTables(_ client: SQLServerClient) async throws {
        try await client.withConnection { connection in
            try await connection.createTable(name: "Categories", columns: [
                column("Id", .int, key: true), column("Name", .nvarchar(length: .length(100))),
            ], schema: schema)
            try await connection.createTable(name: "CategoryTree", columns: [
                column("Id", .int, key: true), column("ParentId", .int, nullable: true), column("Label", .nvarchar(length: .length(100))),
            ], schema: schema)
            try await connection.createTable(name: "Products", columns: [
                column("Id", .int, key: true, identity: true), column("CategoryId", .int),
                column("Sku", .varchar(length: .length(20))), column("Name", .nvarchar(length: .length(100))),
                column("Price", .decimal(precision: 10, scale: 2)), column("Stock", .int),
                column("Discontinued", .bit, nullable: true), column("Notes", .nvarchar(length: .max), nullable: true),
            ], schema: schema)
            // Composite primary key.
            try await connection.createTable(name: "OrderLines", columns: [
                column("OrderId", .int, key: true), column("LineNumber", .int, key: true),
                column("ProductId", .int), column("CategoryId", .int), column("Quantity", .int),
            ], schema: schema)
            // Heaps (no primary key): one gets a clustered index, one a clustered columnstore index.
            try await connection.createTable(name: "AuditLog", columns: [
                column("Id", .int), column("Message", .nvarchar(length: .length(200))),
            ], schema: schema)
            try await connection.createTable(name: "Events", columns: [
                column("At", .datetime2(precision: 3)), column("Kind", .varchar(length: .length(20))), column("Value", .float(mantissa: 53)),
            ], schema: schema)
        }
    }

    private static func fill(_ client: SQLServerClient, database: String, products: Int) async throws {
        let admin = client.admin.scoped(to: database)
        try await admin.insertRows(into: "Categories", schema: schema, columns: ["Id", "Name"],
                                   values: (1...10).map { [.int($0), .nString("Category \($0)")] })
        try await admin.insertRows(into: "CategoryTree", schema: schema, columns: ["Id", "ParentId", "Label"],
                                   values: (1...15).map { [.int($0), $0 <= 3 ? .null : .int(($0 - 1) / 3), .nString("Node \($0)")] })
        for batch in stride(from: 1, through: products, by: 100) {
            try await admin.insertRows(into: "Products", schema: schema,
                                       columns: ["CategoryId", "Sku", "Name", "Price", "Stock", "Discontinued"],
                                       values: (batch...min(batch + 99, products)).map {
                [.int($0 % 10 + 1), .string(String(format: "SKU-%05d", $0)), .nString("Product \($0)"),
                 .decimal("\($0 % 500).99"), .int($0 * 7 % 1_000), .bool($0 % 9 == 0)]
            })
        }
        try await admin.insertRows(into: "OrderLines", schema: schema, columns: ["OrderId", "LineNumber", "ProductId", "CategoryId", "Quantity"],
                                   values: (0..<300).map { [.int($0 / 3 + 1), .int($0 % 3 + 1), .int($0 % products + 1), .int($0 % products % 10 + 1), .int($0 % 5 + 1)] })
        try await admin.insertRows(into: "AuditLog", schema: schema, columns: ["Id", "Message"],
                                   values: (1...50).map { [.int($0), .nString("Audit entry \($0)")] })
        try await admin.insertRows(into: "Events", schema: schema, columns: ["At", "Kind", "Value"],
                                   values: (0..<500).map { [.string("2026-01-01T00:00:\(String(format: "%02d", $0 % 60))"), .string(["click", "view", "buy"][$0 % 3]), .double(Double($0) / 3)] })
    }

    private static func addConstraints(_ client: SQLServerClient) async throws {
        let constraints = client.constraints
        try await constraints.addForeignKey(name: "FK_Products_Categories", table: "Products", columns: ["CategoryId"],
                                            referencedTable: "Categories", referencedColumns: ["Id"], schema: schema, referencedSchema: schema,
                                            options: ForeignKeyOptions(onDelete: .cascade, onUpdate: .cascade))
        try await constraints.addForeignKey(name: "FK_OrderLines_Products", table: "OrderLines", columns: ["ProductId"],
                                            referencedTable: "Products", referencedColumns: ["Id"], schema: schema, referencedSchema: schema)
        // Created WITH NOCHECK: SQL Server marks it not trusted.
        try await constraints.addForeignKey(name: "FK_OrderLines_Categories", table: "OrderLines", columns: ["CategoryId"],
                                            referencedTable: "Categories", referencedColumns: ["Id"], schema: schema, referencedSchema: schema,
                                            options: ForeignKeyOptions(checkExisting: false, isNotTrusted: true))
        try await constraints.addForeignKey(name: "FK_CategoryTree_Parent", table: "CategoryTree", columns: ["ParentId"],
                                            referencedTable: "CategoryTree", referencedColumns: ["Id"], schema: schema, referencedSchema: schema)
        try await constraints.addCheckConstraint(name: "CK_Products_Price", table: "Products", expression: "Price >= 0", schema: schema)
        try await constraints.addCheckConstraint(name: "CK_Products_Stock", table: "Products", expression: "Stock BETWEEN 0 AND 100000",
                                                 schema: schema, checkExisting: false)
        try await constraints.addUniqueConstraint(name: "UQ_Products_Sku", table: "Products", columns: ["Sku"], schema: schema)
        try await constraints.addDefaultConstraint(name: "DF_Products_Discontinued", table: "Products", column: "Discontinued", defaultValue: "0", schema: schema)
    }

    private static func createIndexes(_ client: SQLServerClient) async throws {
        let indexes = client.indexes
        try await indexes.createIndex(name: "IX_Products_Name", table: "Products", columns: [IndexColumn(name: "Name")], schema: schema)
        try await indexes.createIndex(name: "IX_Products_Category_Price", table: "Products",
                                      columns: [IndexColumn(name: "CategoryId"), IndexColumn(name: "Price", sortDirection: .descending)], schema: schema)
        try await indexes.createIndex(name: "IX_Products_Category_Covering", table: "Products",
                                      columns: [IndexColumn(name: "CategoryId"), IndexColumn(name: "Name", isIncluded: true), IndexColumn(name: "Stock", isIncluded: true)],
                                      schema: schema)
        try await indexes.createIndex(name: "IX_Products_Active", table: "Products", columns: [IndexColumn(name: "Stock")], schema: schema,
                                      filter: "Discontinued = 0")
        try await indexes.createUniqueIndex(name: "UX_Products_Name_Category", table: "Products",
                                            columns: [IndexColumn(name: "Name"), IndexColumn(name: "CategoryId")], schema: schema)
        try await indexes.createIndex(name: "IX_Products_Stock_Compressed", table: "Products", columns: [IndexColumn(name: "Stock")], schema: schema,
                                      options: IndexOptions(fillFactor: 80, padIndex: true, dataCompression: .page))
        try await indexes.createColumnstoreIndex(name: "NCCI_OrderLines", table: "OrderLines", clustered: false,
                                                 columns: ["ProductId", "Quantity"], schema: schema)
        try await indexes.createColumnstoreIndex(name: "CCI_Events", table: "Events", clustered: true, schema: schema)
        try await indexes.createClusteredIndex(name: "CIX_AuditLog_Id", table: "AuditLog",
                                               columns: [IndexColumn(name: "Id")], schema: schema)
    }
}
