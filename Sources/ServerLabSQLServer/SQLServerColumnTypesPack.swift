import Foundation
import ServerLabKit
import SQLServerKit

/// A table with a column of every type the driver can declare, filled with minimum, maximum, NULL and
/// generated values, plus a table of large values.
///
/// Parameters: `database` (default `LabData`), `rows` (generated rows, default 200),
/// `largeValueKB` (size of the largest nvarchar(max)/varbinary(max) value, default 1024).
///
/// json and vector columns are added on SQL Server 2025 and later.
struct SQLServerColumnTypesPack: ContentPack {
    let name = "column-types"
    let version = 3
    let summary = "Every column type with edge values, NULLs and large nvarchar(max)/varbinary(max) values."

    func apply(to server: ServerEndpoint, recipe: Recipe, parameters: PackParameters, context: PackContext) async throws {
        let database = try parameters.string("database", default: SQLServerDatabasePack.defaultName)
        let generatedRows = try parameters.int("rows", default: 200)
        let largeValueKB = try parameters.int("largeValueKB", default: 1024)
        let columns = SQLServerTypeSamples.samples(forVersion: Int(recipe.version) ?? 0)
        let inserted = columns.filter(\.isInsertable)

        try await SQLServerSession.with(server, database: database) { client in
            let admin = client.admin.scoped(to: database)
            try await admin.createTable(
                name: Self.typesTable,
                columns: [Self.identityColumn] + columns.map { sample in
                    SQLServerColumnDefinition(name: sample.column, definition: .standard(.init(dataType: sample.type, isNullable: true)))
                }
            )
            var rows: [[SQLServerLiteralValue]] = [
                inserted.map(\.minimum),
                inserted.map(\.maximum),
                inserted.map { _ in .null },
            ]
            rows += (0..<generatedRows).map { index in inserted.map { $0.generated(index) } }
            for batch in stride(from: 0, to: rows.count, by: 100) {
                try await admin.insertRows(
                    into: Self.typesTable,
                    columns: inserted.map(\.column),
                    values: Array(rows[batch..<min(batch + 100, rows.count)])
                )
            }
            context.log("  \(Self.typesTable): \(columns.count) types, \(rows.count) rows")

            try await admin.createTable(
                name: Self.largeTable,
                columns: [
                    Self.identityColumn,
                    SQLServerColumnDefinition(name: "Label", definition: .standard(.init(dataType: .nvarchar(length: .length(50))))),
                    SQLServerColumnDefinition(name: "TextMax", definition: .standard(.init(dataType: .nvarchar(length: .max), isNullable: true))),
                    SQLServerColumnDefinition(name: "BytesMax", definition: .standard(.init(dataType: .varbinary(length: .max), isNullable: true))),
                ]
            )
            for kilobytes in Self.largeSizes(upTo: largeValueKB) {
                try await admin.insertRow(into: Self.largeTable, values: [
                    "Label": .nString("\(kilobytes) KB"),
                    "TextMax": .nString(Self.largeText(kilobytes: kilobytes)),
                    "BytesMax": .bytes(Self.largeBytes(kilobytes: kilobytes)),
                ])
            }
            context.log("  \(Self.largeTable): values up to \(largeValueKB) KB")
        }
    }

    func verify(on server: ServerEndpoint, recipe: Recipe, parameters: PackParameters) async throws {
        let database = try parameters.string("database", default: SQLServerDatabasePack.defaultName)
        let generatedRows = try parameters.int("rows", default: 200)
        let largeValueKB = try parameters.int("largeValueKB", default: 1024)
        let (columnCount, typeRows, largeRows) = try await SQLServerSession.with(server, database: database) { client in
            (
                try await client.metadata.listColumns(database: database, schema: "dbo", table: Self.typesTable).count,
                try await client.metadata.tableProperties(database: database, schema: "dbo", table: Self.typesTable).rowCount,
                try await client.metadata.tableProperties(database: database, schema: "dbo", table: Self.largeTable).rowCount
            )
        }
        let expectedColumns = SQLServerTypeSamples.samples(forVersion: Int(recipe.version) ?? 0).count + 1
        guard columnCount == expectedColumns else {
            throw ServerLabError.packCheckFailed(pack: name, reason: "\(Self.typesTable) has \(columnCount) columns, expected \(expectedColumns)")
        }
        guard typeRows == Int64(generatedRows + 3) else {
            throw ServerLabError.packCheckFailed(pack: name, reason: "\(Self.typesTable) has \(typeRows) rows, expected \(generatedRows + 3)")
        }
        guard largeRows == Int64(Self.largeSizes(upTo: largeValueKB).count) else {
            throw ServerLabError.packCheckFailed(pack: name, reason: "\(Self.largeTable) has \(largeRows) rows")
        }
    }

    static let typesTable = "AllTypes"
    static let largeTable = "LargeValues"

    static let identityColumn = SQLServerColumnDefinition(
        name: "Id",
        definition: .standard(.init(dataType: .int, isPrimaryKey: true, identity: (1, 1)))
    )

    static func largeSizes(upTo maximum: Int) -> [Int] {
        [1, 64, maximum].filter { $0 <= maximum }.reduce(into: []) { sizes, size in
            if !sizes.contains(size) { sizes.append(size) }
        }
    }

    /// Mixed-script text so encodings and truncation show: Latin, accents, Greek, CJK, emoji.
    static func largeText(kilobytes: Int) -> String {
        let unit = "Lab value ÆØÅ éè Ωμ 漢字 🚀 "
        let characters = kilobytes * 1024 / 2
        return String(String(repeating: unit, count: characters / unit.count + 1).prefix(characters))
    }

    static func largeBytes(kilobytes: Int) -> [UInt8] {
        (0..<(kilobytes * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }
    }
}
