import Foundation
import MySQLKit
import ServerLabKit

/// A table with one column per type (unsigned integers, DECIMAL(65,30), bits, every temporal type,
/// text and blob sizes, ENUM, SET, JSON, every geometry type, VECTOR on MySQL 9 and MariaDB 11.8,
/// MariaDB's INET4/INET6/UUID), with minimum, maximum and NULL rows plus generated ones.
///
/// Parameters: `database` (default `labdata`), `rows` (generated rows, default 200).
struct MySQLColumnTypesPack: ContentPack {
    let name = "column-types"
    let version = 1
    let summary = "Every MySQL/MariaDB column type with minimum, maximum and NULL values."
    static let table = "all_types"

    func apply(to server: ServerEndpoint, recipe: Recipe, parameters: PackParameters, context: PackContext) async throws {
        let database = try parameters.string("database", default: MySQLDatabasePack.defaultName)
        let generatedRows = try parameters.int("rows", default: 200)
        let samples = MySQLTypeSample.samples(engine: recipe.engine, version: recipe.version)
        try await MySQLSession.with(server, database: database) { client in
            try await client.admin.createDatabase(name: database, characterSet: "utf8mb4", ifNotExists: true)
            try await client.admin.createTable(
                schema: database, name: Self.table,
                columns: [MySQLColumnDefinition(name: "id", dataType: "BIGINT UNSIGNED", isNullable: false, isAutoIncrement: true)]
                    + samples.map { MySQLColumnDefinition(name: $0.column, dataType: $0.type) },
                primaryKey: ["id"], options: MySQLTableOptions(engine: "InnoDB", characterSet: "utf8mb4")
            )
            let columns = samples.map(\.column)
            var rows = [samples.map(\.minimum), samples.map(\.maximum), samples.map { _ in MySQLInsertValue.null }]
            rows += (0..<generatedRows).map { index in samples.map { $0.generated(index) } }
            try await client.bulk.insertValues(into: Self.table, schema: database, columns: columns, rows: rows)
            context.log("  \(Self.table): \(samples.count) types, \(rows.count) rows")
        }
    }

    func verify(on server: ServerEndpoint, recipe: Recipe, parameters: PackParameters) async throws {
        let database = try parameters.string("database", default: MySQLDatabasePack.defaultName)
        let expectedRows = 3 + (try parameters.int("rows", default: 200))
        let rows = try await MySQLSession.with(server, database: database) {
            try await $0.metadata.exactRowCount(schema: database, table: Self.table)
        }
        guard rows == expectedRows else {
            throw ServerLabError.packCheckFailed(pack: name, reason: "\(Self.table) has \(rows) rows, expected \(expectedRows)")
        }
    }
}
