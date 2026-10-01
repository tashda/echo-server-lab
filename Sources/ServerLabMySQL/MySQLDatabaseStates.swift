import Foundation
import MySQLKit
import MySQLWire
import ServerLabKit

/// Schemas in states a client has to show: a read-only schema (MySQL 8.0.22+), a view whose
/// table was dropped (invalid), an empty schema, and a MyISAM table next to InnoDB ones.
struct MySQLDatabaseStatesPack: ContentPack {
    let name = "database-states"
    let version = 1
    let summary = "A read-only schema (MySQL 8.0.22+), a broken view, an empty schema and a MyISAM table."

    func apply(to server: ServerEndpoint, recipe: Recipe, parameters: PackParameters, context: PackContext) async throws {
        try await MySQLSession.with(server) { client in
            for schema in ["states_read_only", "states_broken", "states_empty"] {
                try await client.admin.createDatabase(name: schema, ifNotExists: true)
            }
            for (schema, table, engine) in [("states_read_only", "frozen_rows", "InnoDB"), ("states_broken", "doomed", "InnoDB"),
                                            ("states_broken", "legacy_myisam", "MyISAM")] {
                try await client.admin.createTable(schema: schema, name: table, columns: [
                    MySQLColumnDefinition(name: "id", dataType: "INT", isNullable: false),
                    MySQLColumnDefinition(name: "label", dataType: "VARCHAR(40)"),
                ], primaryKey: ["id"], options: MySQLTableOptions(engine: engine))
                try await client.bulk.insertValues(into: table, schema: schema, columns: ["id", "label"],
                                                   rows: (1...5).map { [.data(MySQLData(int: $0)), .data(MySQLData(string: "\(table) \($0)"))] })
            }
            // The view outlives its table: selecting from it fails, listing it does not.
            try await client.views.createView(schema: "states_broken", name: "orphan_view",
                                              definitionSQL: "SELECT id, label FROM states_broken.doomed")
            try await client.admin.dropTable(schema: "states_broken", name: "doomed")
            if Self.hasReadOnlySchemas(recipe) {
                try await client.admin.setSchemaReadOnly(name: "states_read_only", readOnly: true)
            }
        }
        context.log("  read-only, broken and empty schemas")
    }

    /// `ALTER SCHEMA … READ ONLY` exists on MySQL 8.0.22 and later (all the lab's MySQL images).
    static func hasReadOnlySchemas(_ recipe: Recipe) -> Bool { recipe.engine == .mysql }

    func verify(on server: ServerEndpoint, recipe: Recipe, parameters: PackParameters) async throws {
        let (schemas, views, readOnly) = try await MySQLSession.with(server) { client in
            (try await client.metadata.listDatabases(), try await client.metadata.listTablesAndViews(in: "states_broken").map(\.name),
             Self.hasReadOnlySchemas(recipe) ? try await client.metadata.isSchemaReadOnly(name: "states_read_only") : true)
        }
        guard ["states_read_only", "states_broken", "states_empty"].allSatisfy(schemas.contains), views.contains("orphan_view"), readOnly else {
            throw ServerLabError.packCheckFailed(pack: name, reason: "schemas \(schemas), broken \(views), read-only \(readOnly)")
        }
    }
}
