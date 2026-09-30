import Foundation
import PostgresKit
import ServerLabKit

/// Roles and privileges: group roles without login, login roles with every attribute (create db,
/// create role, bypass RLS, connection limit, expiry), nested membership, database, schema, table,
/// column and default privileges, and row-level security with permissive and restrictive policies.
///
/// Login roles get the lab password. Parameters: `database` (default `labdata`).
struct PostgresSecurityPack: ContentPack {
    let name = "security"
    let version = 1
    let summary = "Roles with every attribute, nested membership, database/schema/table/column/default privileges, row-level security."

    func apply(to server: ServerEndpoint, recipe: Recipe, parameters: PackParameters, context: PackContext) async throws {
        let database = try parameters.string("database", default: PostgresDatabasePack.defaultName)
        let password = server.password
        // Roles are cluster-wide; create them from the default database.
        try await PostgresSession.with(server) { client in
            let security = client.security
            _ = try await security.createRole(name: "lab_readonly")
            _ = try await security.createRole(name: "lab_readwrite")
            _ = try await security.createRole(name: "lab_app", password: password, login: true)
            _ = try await security.createRole(name: "lab_admin", password: password, createDatabase: true, createRole: true, login: true)
            _ = try await security.createRole(name: "lab_bypass", password: password, login: true, bypassRLS: true)
            _ = try await security.createRole(name: "lab_limited", password: password, login: true, connectionLimit: 2)
            _ = try await security.createRole(name: "lab_expiring", password: password, login: true, validUntil: "2030-01-01")
            _ = try await security.createRole(name: "lab_nobody", password: password, login: true)
            _ = try await security.grantRole(role: "lab_readonly", to: "lab_app")
            _ = try await security.grantRole(role: "lab_readonly", to: "lab_readwrite")
            _ = try await security.grantRole(role: "lab_readwrite", to: "lab_admin", admin: true)
            _ = try await security.grantDatabasePrivileges(privileges: [.connect, .temporary], onDatabase: database, to: "lab_app")
        }
        try await PostgresSession.with(server, database: database) { client in
            let security = client.security
            _ = try await client.admin.createSchema(name: Self.schema)
            _ = try await client.admin.createTable(name: "salaries", schema: Self.schema, columns: [
                PostgresColumnDefinition(name: "id", dataType: "integer", nullable: false, primaryKey: true),
                PostgresColumnDefinition(name: "employee", dataType: "text", nullable: false),
                PostgresColumnDefinition(name: "salary", dataType: "numeric(12,2)", nullable: false),
                PostgresColumnDefinition(name: "region", dataType: "text", nullable: false),
            ])
            _ = try await client.bulk.insert(into: "salaries", schema: Self.schema, columns: ["id", "employee", "salary", "region"],
                                             values: (1...40).map {
                [PostgresInsertValue($0), PostgresInsertValue("Employee \($0)"), .sql("\(40_000 + $0 * 1_000).00"),
                 PostgresInsertValue(["lab_app", "north", "south", "east"][$0 % 4])]
            })
            _ = try await security.grantSchemaPrivileges(privileges: [.usage], onSchema: Self.schema, to: "lab_readonly")
            _ = try await security.grantPrivileges(privileges: [.select], onTable: "salaries", schema: Self.schema, to: "lab_readonly")
            _ = try await security.grantPrivileges(privileges: [.insert, .update, .delete], onTable: "salaries", schema: Self.schema, to: "lab_readwrite")
            _ = try await security.grantPrivileges(privileges: [.update], onTable: "salaries", schema: Self.schema,
                                                   columns: ["region"], to: "lab_app", withGrantOption: true)
            _ = try await security.alterDefaultPrivileges(schema: Self.schema, grant: [.select], to: "lab_readonly")
            // Row-level security: a login sees rows whose region is its own name; salaries above
            // 70,000 are hidden from everyone but the owner and lab_bypass.
            _ = try await client.admin.alterTableRowLevelSecurity(table: "salaries", enable: true, schema: Self.schema)
            _ = try await security.createPolicy(name: "own_region", table: "salaries", schema: Self.schema, command: .select,
                                                to: ["lab_readonly"], using: "region = current_user")
            _ = try await security.createPolicy(name: "hide_high_salaries", table: "salaries", schema: Self.schema, command: .select,
                                                to: ["PUBLIC"], using: "salary <= 70000", permissive: false)
        }
        context.log("  8 roles, nested membership, privileges down to columns, 2 row-level security policies")
    }

    func verify(on server: ServerEndpoint, recipe: Recipe, parameters: PackParameters) async throws {
        let database = try parameters.string("database", default: PostgresDatabasePack.defaultName)
        let roles = Set(try await PostgresSession.with(server) { try await $0.security.listRoles().map(\.name) })
        let policies = try await PostgresSession.with(server, database: database) { client in
            try await client.metadata.listPolicies(schema: Self.schema, table: "salaries").count
        }
        for role in ["lab_readonly", "lab_readwrite", "lab_app", "lab_admin", "lab_bypass", "lab_limited", "lab_expiring", "lab_nobody"]
            where !roles.contains(role) {
            throw ServerLabError.packCheckFailed(pack: name, reason: "role \(role) is missing")
        }
        guard policies == 2 else {
            throw ServerLabError.packCheckFailed(pack: name, reason: "\(policies) policies, expected 2")
        }
    }

    static let schema = "secure"
}
