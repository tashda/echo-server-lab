import Foundation
import ServerLabKit
import SQLServerKit

/// Server and database security: SQL logins (policy, disabled, sysadmin, a login that can see almost
/// nothing), a custom server role, server permissions, a certificate login, a credential; database
/// users (mapped and without login), nested database roles, an application role, grants, a
/// column-level deny, dynamic data masking and a row-level security policy.
///
/// Logins get the lab password. Parameters: `database` (default `LabData`).
struct SQLServerSecurityPack: ContentPack {
    let name = "security"
    let version = 1
    let summary = "Logins of every kind, server/database/application roles, grants and denies, masking, row-level security, certificate login."

    func apply(to server: ServerEndpoint, recipe: Recipe, parameters: PackParameters, context: PackContext) async throws {
        let database = try parameters.string("database", default: SQLServerDatabasePack.defaultName)
        try await SQLServerSession.with(server) { client in
            try await Self.serverLevel(client, password: server.password, database: database)
        }
        try await SQLServerSession.with(server, database: database) { client in
            try await Self.databaseLevel(client, password: server.password, database: database)
        }
        context.log("  \(Self.logins.count + 1) logins, server role, certificate login, users, roles, masking, row-level security")
    }

    func verify(on server: ServerEndpoint, recipe: Recipe, parameters: PackParameters) async throws {
        let database = try parameters.string("database", default: SQLServerDatabasePack.defaultName)
        let (logins, roleMembers, credentials) = try await SQLServerSession.with(server) { client in
            (
                Set(try await client.serverSecurity.listLogins().map(\.name)),
                try await client.serverSecurity.listServerRoleMembers(role: "LabOperators"),
                try await client.serverSecurity.listCredentials().count
            )
        }
        let (users, policies) = try await SQLServerSession.with(server, database: database) { client in
            (Set(try await client.security.listUsers().map(\.name)), try await client.security.listSecurityPolicies().count)
        }
        for login in Self.logins.map(\.name) + ["lab_cert_login"] where !logins.contains(login) {
            throw ServerLabError.packCheckFailed(pack: name, reason: "login \(login) is missing")
        }
        for user in ["reader", "writer", "auditor_nologin"] where !users.contains(user) {
            throw ServerLabError.packCheckFailed(pack: name, reason: "user \(user) is missing")
        }
        guard roleMembers.contains("lab_admin"), credentials >= 1, policies == 1 else {
            throw ServerLabError.packCheckFailed(pack: name, reason: "server role members \(roleMembers), \(credentials) credentials, \(policies) policies")
        }
    }

    private struct Login {
        var name: String
        var options: SQLServerServerSecurityClient.LoginOptions
        var enabled = true
    }

    private static let logins = [
        Login(name: "lab_reader", options: .init(checkPolicy: false)),
        Login(name: "lab_writer", options: .init(checkPolicy: false)),
        Login(name: "lab_admin", options: .init(checkPolicy: false)),
        Login(name: "lab_policy", options: .init(checkPolicy: true, checkExpiration: true)),
        Login(name: "lab_disabled", options: .init(checkPolicy: false), enabled: false),
        // Can connect but has no user in any lab database.
        Login(name: "lab_nobody", options: .init(checkPolicy: false)),
    ]

    private static func serverLevel(_ client: SQLServerClient, password: String, database: String) async throws {
        let serverSecurity = client.serverSecurity
        for login in logins {
            var options = login.options
            options.defaultDatabase = login.name == "lab_nobody" ? "master" : database
            try await serverSecurity.createSqlLogin(name: login.name, password: password, options: options)
            if !login.enabled { try await serverSecurity.enableLogin(name: login.name, enabled: false) }
        }
        try await serverSecurity.addMemberToServerRole(role: "sysadmin", principal: "lab_admin")
        try await serverSecurity.addMemberToServerRole(role: "dbcreator", principal: "lab_writer")
        try await serverSecurity.createServerRole(name: "LabOperators")
        try await serverSecurity.addMemberToServerRole(role: "LabOperators", principal: "lab_admin")
        try await serverSecurity.addMemberToServerRole(role: "LabOperators", principal: "lab_reader")
        try await serverSecurity.grant(permission: .viewServerState, to: "LabOperators")
        try await serverSecurity.deny(permission: .alterAnyLogin, to: "lab_writer")
        try await serverSecurity.createCredential(name: "LabCredential", identity: "lab_identity", secret: password)
        // A certificate in master, and a login mapped to it.
        try await client.security.createMasterKey(password: password)
        try await client.security.createCertificate(name: "LabLoginCertificate", subject: "Echo lab certificate login",
                                                    expiryDate: Date(timeIntervalSince1970: 1_893_456_000))
        try await serverSecurity.createCertificateLogin(name: "lab_cert_login", certificateName: "LabLoginCertificate")
    }

    private static func databaseLevel(_ client: SQLServerClient, password: String, database: String) async throws {
        let security = client.security
        try await security.createSchema(name: "secure")
        try await client.withConnection { connection in
            try await connection.createTable(name: "Salaries", columns: [
                SQLServerColumnDefinition(name: "Id", definition: .standard(.init(dataType: .int, isPrimaryKey: true))),
                SQLServerColumnDefinition(name: "Employee", definition: .standard(.init(dataType: .nvarchar(length: .length(100))))),
                SQLServerColumnDefinition(name: "Email", definition: .standard(.init(dataType: .varchar(length: .length(200))))),
                SQLServerColumnDefinition(name: "Salary", definition: .standard(.init(dataType: .decimal(precision: 12, scale: 2)))),
                SQLServerColumnDefinition(name: "Region", definition: .standard(.init(dataType: .varchar(length: .length(20))))),
            ], schema: "secure")
        }
        try await client.admin.scoped(to: database).insertRows(into: "Salaries", schema: "secure",
                                                                columns: ["Id", "Employee", "Email", "Salary", "Region"],
                                                                values: (1...40).map {
            [.int($0), .nString("Employee \($0)"), .string("employee\($0)@example.com"), .decimal("\(40_000 + $0 * 1_000).00"), .string(["north", "south", "east", "west"][$0 % 4])]
        })

        try await security.createUser(name: "reader", login: "lab_reader")
        try await security.createUser(name: "writer", login: "lab_writer", options: UserOptions(defaultSchema: "secure"))
        try await security.createUser(name: "admin_user", login: "lab_admin")
        try await security.createUser(name: "policy_user", login: "lab_policy")
        try await security.createUser(name: "auditor_nologin", login: nil)

        try await security.createRole(name: "app_readers")
        try await security.createRole(name: "app_auditors")
        try await security.addUserToRole(user: "reader", role: "app_readers")
        try await security.addUserToRole(user: "auditor_nologin", role: "app_auditors")
        // Nested: auditors are also readers.
        try await security.addUserToRole(user: "app_auditors", role: "app_readers")
        try await security.addUserToRole(user: "writer", role: "db_datareader")
        try await security.addUserToRole(user: "writer", role: "db_datawriter")
        try await security.createApplicationRole(name: "LabAppRole", password: password, defaultSchema: "secure")

        let salaries = ObjectIdentifier(schema: "secure", name: "Salaries", kind: .table)
        try await security.grant(permission: .select, on: .object(salaries), to: "app_readers")
        try await security.deny(permission: .select, on: .column(salaries, ["Salary"]), to: "reader")
        try await security.grant(permission: .update, on: .object(salaries), to: "writer", withGrantOption: true)
        try await security.grant(permission: .viewDefinition, on: .database(nil), to: "app_auditors")

        try await security.addMask(schema: "secure", table: "Salaries", column: "Email", function: .email)
        try await security.addMask(schema: "secure", table: "Salaries", column: "Employee", function: .partial(prefix: 2, padding: "XXXX", suffix: 0))

        // Row-level security: each user only sees the region named like their user, admins see all.
        try await client.routines.createInlineTableValuedFunction(
            name: "fn_RegionFilter",
            parameters: [FunctionParameter(name: "Region", dataType: .varchar(length: .length(20)))],
            query: "SELECT 1 AS Allowed WHERE @Region = USER_NAME() OR IS_MEMBER('db_owner') = 1 OR USER_NAME() = 'admin_user'",
            schema: "secure"
        )
        try await security.createSecurityPolicy(name: "RegionPolicy", schema: "secure", filterFunction: "fn_RegionFilter",
                                                filterFunctionSchema: "secure", targetTable: "Salaries", targetSchema: "secure",
                                                schemaBound: false)
    }
}
