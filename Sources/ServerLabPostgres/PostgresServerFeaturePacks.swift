import Foundation
import PostgresKit
import ServerLabKit

/// Roles with little permission: connect only, read only, no CONNECT on labdata (PUBLIC's CONNECT
/// revoked), no USAGE on a schema, expired, and one with a connection limit of 1. Password: the
/// lab password. Parameters: `database` (default labdata).
struct PostgresLowPrivilegePack: ContentPack {
    let name = "low-privilege"
    let version = 1
    let summary = "Roles that can only connect, only read, cannot connect, cannot use a schema, are expired, or are limited to one connection."

    func apply(to server: ServerEndpoint, recipe: Recipe, parameters: PackParameters, context: PackContext) async throws {
        let database = try parameters.string("database", default: PostgresDatabasePack.defaultName)
        let password = server.password
        try await PostgresSession.with(server, database: database) { client in
            let security = client.security
            for role in ["lab_connect_only", "lab_read_only", "lab_no_connect", "lab_no_schema"] {
                _ = try await security.createRole(name: role, password: password, login: true)
            }
            _ = try await security.createRole(name: "lab_expired", password: password, login: true, validUntil: "2000-01-01")
            _ = try await security.createRole(name: "lab_one_connection", password: password, login: true, connectionLimit: 1)
            _ = try await client.admin.createSchema(name: "restricted")
            _ = try await security.revokeDatabasePrivileges(privileges: [.connect], onDatabase: database, from: "PUBLIC")
            for role in ["lab_connect_only", "lab_read_only", "lab_no_schema", "lab_expired", "lab_one_connection"] {
                _ = try await security.grantDatabasePrivileges(privileges: [.connect], onDatabase: database, to: role)
            }
            // pg_read_all_data is PostgreSQL 14+; before that, SELECT on public's tables.
            if (Int(recipe.version) ?? 0) >= 14 {
                _ = try await security.grantRole(role: "pg_read_all_data", to: "lab_read_only")
            } else {
                _ = try await security.grantAllTablesPrivileges(privileges: [.select], inSchema: "public", to: "lab_read_only")
            }
            _ = try await security.revokeSchemaPrivileges(privileges: [.usage, .create], onSchema: "restricted", from: "PUBLIC")
        }
    }

    func verify(on server: ServerEndpoint, recipe: Recipe, parameters: PackParameters) async throws {
        let roles = try await PostgresSession.with(server) { try await $0.security.listRoles().map(\.name) }
        let expected: Set = ["lab_connect_only", "lab_read_only", "lab_no_connect", "lab_no_schema", "lab_expired", "lab_one_connection"]
        guard expected.isSubset(of: Set(roles)) else {
            throw ServerLabError.packCheckFailed(pack: name, reason: "roles \(roles.filter { $0.hasPrefix("lab_") })")
        }
    }
}

/// Edge cases: hostile names (Unicode, spaces, quotes, mixed case, reserved words, emoji), a
/// NULL-heavy table, an empty table and schema, a 20-view chain, and databases in other encodings
/// (LATIN1, EUC_JP, SQL_ASCII) and with an ICU collation.
struct PostgresEdgeCasesPack: ContentPack {
    let name = "edge-cases"
    let version = 1
    let summary = "Hostile names, NULL-heavy and empty tables, a 20-view chain, databases in LATIN1, EUC_JP, SQL_ASCII and ICU."
    static let hostileSchema = "Ünïcödé Schema 名前"
    static let hostileTable = "Table \"With\" 'Quotes' and Spaces"

    func apply(to server: ServerEndpoint, recipe: Recipe, parameters: PackParameters, context: PackContext) async throws {
        let database = try parameters.string("database", default: PostgresDatabasePack.defaultName)
        try await PostgresSession.with(server, database: database) { client in
            _ = try await client.admin.createSchema(name: Self.hostileSchema)
            _ = try await client.admin.createSchema(name: "empty_schema")
            _ = try await client.admin.createTable(name: Self.hostileTable, schema: Self.hostileSchema, columns: [
                PostgresColumnDefinition(name: "select", dataType: "integer", nullable: false, primaryKey: true),
                PostgresColumnDefinition(name: "Order", dataType: "text"),
                PostgresColumnDefinition(name: "with space", dataType: "integer"),
                PostgresColumnDefinition(name: "MixedCase", dataType: "integer"),
                PostgresColumnDefinition(name: "emoji 😀", dataType: "text"),
            ])
            _ = try await client.admin.createTable(name: "empty_table", columns: [
                PostgresColumnDefinition(name: "id", dataType: "integer", nullable: false, primaryKey: true),
            ])
            _ = try await client.admin.createTable(name: "mostly_null", columns: [PostgresColumnDefinition(name: "id", dataType: "integer", nullable: false, primaryKey: true)]
                + [("a", "integer"), ("b", "text"), ("c", "timestamptz"), ("d", "numeric(18,4)"), ("e", "uuid"), ("f", "bytea"), ("g", "boolean"),
                   ("h", "jsonb"), ("i", "integer[]")].map { PostgresColumnDefinition(name: $0.0, dataType: $0.1) })
            try await client.bulk.insert(into: Self.hostileTable, schema: Self.hostileSchema, columns: ["select", "Order", "with space", "MixedCase", "emoji 😀"],
                                         values: (1...5).map { [PostgresInsertValue($0), PostgresInsertValue("order \($0)"), PostgresInsertValue($0 * 2),
                                                               .null, PostgresInsertValue("😀\($0)")] })
            try await client.bulk.insert(into: "mostly_null", columns: ["id", "a"],
                                         values: (1...500).map { [PostgresInsertValue($0), $0 % 10 == 0 ? PostgresInsertValue($0) : .null] })
            _ = try await client.views.createView(name: "v_chain_01", query: "SELECT id, a FROM mostly_null")
            for level in 2...20 {
                _ = try await client.views.createView(name: String(format: "v_chain_%02d", level), query: String(format: "SELECT id, a FROM v_chain_%02d", level - 1))
            }
        }
        try await PostgresSession.with(server) { client in
            _ = try await client.admin.createDatabase(name: "lab_latin1", template: "template0", encoding: "LATIN1", lcCollate: "C", lcCtype: "C")
            _ = try await client.admin.createDatabase(name: "lab_euc_jp", template: "template0", encoding: "EUC_JP", lcCollate: "C", lcCtype: "C")
            _ = try await client.admin.createDatabase(name: "lab_sql_ascii", template: "template0", encoding: "SQL_ASCII", lcCollate: "C", lcCtype: "C")
            // ICU per database is PostgreSQL 15+.
            if (Int(recipe.version) ?? 0) >= 15 {
                _ = try await client.admin.createDatabase(name: "lab_icu", template: "template0", encoding: "UTF8", icuLocale: "de-DE", localeProvider: "icu")
            }
        }
    }

    func verify(on server: ServerEndpoint, recipe: Recipe, parameters: PackParameters) async throws {
        let database = try parameters.string("database", default: PostgresDatabasePack.defaultName)
        let rows = try await PostgresSession.with(server, database: database) {
            try await $0.metadata.exactRowCount(schema: Self.hostileSchema, table: Self.hostileTable)
        }
        let databases = try await PostgresSession.with(server) { try await $0.metadata.listDatabases() }
        let expected = ["lab_latin1", "lab_euc_jp", "lab_sql_ascii"] + ((Int(recipe.version) ?? 0) >= 15 ? ["lab_icu"] : [])
        guard rows == 5, Set(expected).isSubset(of: Set(databases)) else {
            throw ServerLabError.packCheckFailed(pack: name, reason: "\(rows) hostile rows, databases \(databases)")
        }
    }
}
