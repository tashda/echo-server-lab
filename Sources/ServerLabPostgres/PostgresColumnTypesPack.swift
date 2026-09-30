import Foundation
import PostgresKit
import ServerLabKit

/// A table with a column of every built-in type (multiranges from 14), filled with edge values,
/// NULLs and generated rows, and a table of JSON documents from tiny to large.
///
/// Parameters: `database` (default `labdata`), `rows` (default 200), `largeValueKB` (default 1024).
struct PostgresColumnTypesPack: ContentPack {
    let name = "column-types"
    let version = 1
    let summary = "Every built-in type (json, jsonb, arrays, ranges, network, geometric, text search) with edge values."

    func apply(to server: ServerEndpoint, recipe: Recipe, parameters: PackParameters, log: LabLog) async throws {
        let database = try parameters.string("database", default: PostgresDatabasePack.defaultName)
        let generatedRows = try parameters.int("rows", default: 200)
        let largeValueKB = try parameters.int("largeValueKB", default: 1024)
        let samples = PostgresTypeSamples.samples(forVersion: Int(recipe.version) ?? 0)

        try await PostgresSession.with(server, database: database) { client in
            try await client.admin.createTable(
                name: Self.typesTable,
                columns: [Self.identityColumn] + samples.map { PostgresColumnDefinition(name: $0.column, dataType: $0.type) }
            )
            var rows = [samples.map { $0.value($0.minimum) }, samples.map { $0.value($0.maximum) }, samples.map { _ in .null }]
            rows += (0..<generatedRows).map { index in samples.map { $0.value($0.generated(index)) } }
            for batch in stride(from: 0, to: rows.count, by: 100) {
                try await client.bulk.insert(
                    into: Self.typesTable,
                    columns: samples.map(\.column),
                    values: Array(rows[batch..<min(batch + 100, rows.count)])
                )
            }
            log("  \(Self.typesTable): \(samples.count) types, \(rows.count) rows")

            try await client.admin.createTable(name: Self.documentsTable, columns: [
                Self.identityColumn,
                PostgresColumnDefinition(name: "label", dataType: "text", nullable: false),
                PostgresColumnDefinition(name: "doc_json", dataType: "json"),
                PostgresColumnDefinition(name: "doc_jsonb", dataType: "jsonb"),
                PostgresColumnDefinition(name: "body", dataType: "text"),
                PostgresColumnDefinition(name: "blob", dataType: "bytea"),
            ])
            for document in PostgresTypeSamples.documents(largeValueKB: largeValueKB) {
                try await client.bulk.insert(
                    into: Self.documentsTable,
                    columns: ["label", "doc_json", "doc_jsonb", "body", "blob"],
                    values: [[
                        PostgresInsertValue(document.label),
                        PostgresTypeSamples.cast(document.json, "json"),
                        .jsonbLiteral(document.json),
                        PostgresInsertValue(document.body),
                        PostgresTypeSamples.cast(document.hexBytes, "bytea"),
                    ]]
                )
            }
            log("  \(Self.documentsTable): JSON documents up to \(largeValueKB) KB")
        }
    }

    func verify(on server: ServerEndpoint, recipe: Recipe, parameters: PackParameters) async throws {
        let database = try parameters.string("database", default: PostgresDatabasePack.defaultName)
        let expected = PostgresTypeSamples.samples(forVersion: Int(recipe.version) ?? 0).count + 1
        let (typeColumns, documentColumns) = try await PostgresSession.with(server, database: database) { client in
            (
                try await client.metadata.listColumns(schema: "public", table: Self.typesTable).count,
                try await client.metadata.listColumns(schema: "public", table: Self.documentsTable).count
            )
        }
        guard typeColumns == expected else {
            throw ServerLabError.packCheckFailed(pack: name, reason: "\(Self.typesTable) has \(typeColumns) columns, expected \(expected)")
        }
        guard documentColumns == 6 else {
            throw ServerLabError.packCheckFailed(pack: name, reason: "\(Self.documentsTable) has \(documentColumns) columns, expected 6")
        }
    }

    static let typesTable = "all_types"
    static let documentsTable = "json_documents"
    static let identityColumn = PostgresColumnDefinition(
        name: "id", dataType: "bigint GENERATED ALWAYS AS IDENTITY", nullable: false, primaryKey: true
    )
}
