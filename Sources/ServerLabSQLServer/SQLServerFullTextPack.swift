import Foundation
import ServerLabKit
import SQLServerKit

/// Full-text search (needs `imageVariant: fulltext`): a default and an accent-insensitive
/// catalog, an index with automatic change tracking populated over articles in several
/// languages, and one with manual tracking. Parameter: `database` (default FullTextLab).
struct SQLServerFullTextPack: ContentPack {
    let name = "full-text"
    let version = 1
    let summary = "Full-text catalogs and populated full-text indexes (needs the fulltext image)."

    static let articles = [
        "The quick brown fox jumps over the lazy dog",
        "Database mirroring and availability groups keep replicas in step",
        "Le renard brun rapide saute par-dessus le chien paresseux",
        "Der schnelle braune Fuchs springt über den faulen Hund",
        "Full-text search finds inflectional forms: run, running, ran",
    ]

    func apply(to server: ServerEndpoint, recipe: Recipe, parameters: PackParameters, context: PackContext) async throws {
        guard recipe.settings.imageVariant == "fulltext" else {
            throw ServerLabError.packRequirement(pack: name, reason: "full-text search needs imageVariant \"fulltext\"")
        }
        let database = try parameters.string("database", default: "FullTextLab")
        try await SQLServerSession.with(server) { try await $0.admin.createDatabase(name: database) }
        try await SQLServerSession.with(server, database: database) { client in
            let admin = client.admin.scoped(to: database)
            for table in ["Articles", "Notes"] {
                try await admin.createTable(name: table, columns: [
                    SQLServerColumnDefinition(name: "Id", definition: .standard(.init(dataType: .int, isNullable: false))),
                    SQLServerColumnDefinition(name: "Title", definition: .standard(.init(dataType: .nvarchar(length: .length(200))))),
                    SQLServerColumnDefinition(name: "Body", definition: .standard(.init(dataType: .nvarchar(length: .max)))),
                ])
                try await client.indexes.createUniqueIndex(name: "UX_\(table)_Id", table: table, columns: [IndexColumn(name: "Id")])
                try await admin.insertRows(into: table, columns: ["Id", "Title", "Body"], values: Self.articles.enumerated().map { index, text in
                    [.int(index + 1), .nString("\(table) \(index + 1)"), .nString(text)]
                })
            }
            try await client.fullText.createCatalog(name: "LabCatalog", isDefault: true)
            try await client.fullText.createCatalog(name: "LabAccentInsensitive", accentSensitive: false)
            try await client.fullText.createIndex(schema: "dbo", table: "Articles", keyIndex: "UX_Articles_Id",
                                                  catalogName: "LabCatalog", columns: ["Title", "Body"], changeTracking: .auto)
            try await client.fullText.createIndex(schema: "dbo", table: "Notes", keyIndex: "UX_Notes_Id",
                                                  catalogName: "LabAccentInsensitive", columns: ["Body"], changeTracking: .manual)
            try await client.fullText.startPopulation(schema: "dbo", table: "Notes")
        }
        context.log("  2 catalogs, 2 full-text indexes in \(database)")
    }

    func verify(on server: ServerEndpoint, recipe: Recipe, parameters: PackParameters) async throws {
        let database = try parameters.string("database", default: "FullTextLab")
        let (catalogs, indexes) = try await SQLServerSession.with(server, database: database) { client in
            (try await client.fullText.listCatalogs().map(\.name), try await client.fullText.listIndexes().map(\.tableName))
        }
        guard Set(catalogs) == ["LabCatalog", "LabAccentInsensitive"], Set(indexes) == ["Articles", "Notes"] else {
            throw ServerLabError.packCheckFailed(pack: name, reason: "catalogs \(catalogs), indexes \(indexes)")
        }
    }
}
