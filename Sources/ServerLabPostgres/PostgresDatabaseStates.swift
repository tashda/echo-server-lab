import Foundation
import PostgresKit
import ServerLabKit

/// Databases and objects in the states Echo has to show or refuse: a database that takes no
/// connections, one with a connection limit of 0, a template, one read-only by default, one on its
/// own tablespace, LATIN1 / SQL_ASCII / EUC_JP databases, an empty tablespace, and inside
/// `database`: an unpopulated materialized view, a sequence at its maximum, a NOT VALID check
/// constraint and a disabled trigger. Parameter: `database` (default labdata).
struct PostgresDatabaseStatesPack: ContentPack {
    let name = "database-states"
    let version = 1
    let summary = "No-connection, limit-0, template, read-only and other-encoding databases, tablespaces, and objects in odd states."

    /// Database, encoding, allows connections, connection limit, template, tablespace.
    static let databases: [(name: String, encoding: String, allowConnections: Bool, limit: Int, template: Bool, tablespace: String)] = [
        ("states_no_connections", "UTF8", false, -1, false, "pg_default"),
        ("states_limit_zero", "UTF8", true, 0, false, "pg_default"),
        ("states_template", "UTF8", true, -1, true, "pg_default"),
        ("states_read_only", "UTF8", true, -1, false, "pg_default"),
        ("states_on_tablespace", "UTF8", true, -1, false, "ts_fast"),
        ("enc_latin1", "LATIN1", true, -1, false, "pg_default"),
        ("enc_sql_ascii", "SQL_ASCII", true, -1, false, "pg_default"),
        ("enc_euc_jp", "EUC_JP", true, -1, false, "pg_default"),
    ]

    static let tablespaces = ["ts_fast": PostgresEngine.tablespaceLocations[0], "ts_archive": PostgresEngine.tablespaceLocations[1]]

    func apply(to server: ServerEndpoint, recipe: Recipe, parameters: PackParameters, context: PackContext) async throws {
        let database = try parameters.string("database", default: PostgresDatabasePack.defaultName)
        try await PostgresSession.with(server) { client in
            for (name, location) in Self.tablespaces.sorted(by: { $0.key < $1.key }) {
                _ = try await client.admin.createTablespace(name: name, location: location)
            }
            for spec in Self.databases {
                // Other encodings need template0 and the C locale.
                let other = spec.encoding != "UTF8"
                _ = try await client.admin.createDatabase(
                    name: spec.name, template: other ? "template0" : nil, encoding: spec.encoding,
                    lcCollate: other ? "C" : nil, lcCtype: other ? "C" : nil,
                    tablespace: spec.tablespace == "pg_default" ? nil : spec.tablespace
                )
            }
            try await client.admin.alterDatabaseSet(name: "states_read_only", parameter: "default_transaction_read_only", value: "on")
            try await client.admin.alterDatabaseConnectionLimit(name: "states_limit_zero", limit: 0)
            try await client.admin.alterDatabaseIsTemplate(name: "states_template", isTemplate: true)
            try await client.admin.alterDatabaseAllowConnections(name: "states_no_connections", allow: false)
            _ = try await client.admin.createDatabase(name: database, ifNotExists: true)
        }
        try await PostgresSession.with(server, database: database) { client in
            _ = try await client.admin.createTable(name: "state_readings", schema: "public", columns: [
                PostgresColumnDefinition(name: "id", dataType: "integer", nullable: false, primaryKey: true),
                PostgresColumnDefinition(name: "reading", dataType: "integer"),
            ])
            _ = try await client.bulk.insert(into: "state_readings", schema: "public", columns: ["id", "reading"],
                                             values: [[.bind(1), .bind(-5)], [.bind(2), .bind(7)]])
            // Existing rows break the rule; NOT VALID leaves them unchecked.
            _ = try await client.constraints.addCheckConstraintNotValid(table: "state_readings", condition: "reading >= 0",
                                                                        constraintName: "reading_not_negative", schema: "public")
            _ = try await client.views.createMaterializedView(name: "pending_report", schema: "public",
                                                              query: "SELECT id, reading FROM public.state_readings", withData: false)
            _ = try await client.sequences.createSequence(name: "exhausted_ids", schema: "public", minValue: 1, maxValue: 3)
            _ = try await client.sequences.setval("public.exhausted_ids", value: 3)
            _ = try await client.routines.createFunction(name: "keep_row", schema: "public", parameters: [], returnType: "trigger",
                                                         body: "BEGIN RETURN NEW; END", language: .plpgsql, security: .invoker)
            _ = try await client.triggers.createTrigger(name: "paused_trigger", table: "state_readings", schema: "public", event: .before,
                                                        operations: [.insert], procedure: "public.keep_row()")
            _ = try await client.triggers.alterTrigger(name: "paused_trigger", table: "state_readings", enabled: false)
        }
        context.log("  \(Self.databases.count) databases, \(Self.tablespaces.count) tablespaces, objects in odd states in \(database)")
    }

    func verify(on server: ServerEndpoint, recipe: Recipe, parameters: PackParameters) async throws {
        let database = try parameters.string("database", default: PostgresDatabasePack.defaultName)
        var problems = try await PostgresSession.with(server) { client in
            var problems: [String] = []
            for spec in Self.databases {
                let found = try await client.metadata.fetchDatabaseProperties(name: spec.name)
                let wanted = (spec.encoding, spec.allowConnections, spec.limit, spec.template, spec.tablespace)
                let actual = (found.encoding, found.allowConnections, found.connectionLimit, found.isTemplate, found.tablespace)
                if actual != wanted { problems.append("\(spec.name) is \(actual)") }
            }
            let readOnly = try await client.metadata.fetchDatabaseParameters(
                databaseOid: client.metadata.fetchDatabaseProperties(name: "states_read_only").oid)
            if !readOnly.contains(where: { $0.name == "default_transaction_read_only" && $0.value == "on" }) {
                problems.append("states_read_only has \(readOnly.map { "\($0.name)=\($0.value)" })")
            }
            let tablespaces: [PostgresTablespaceInfo] = try await client.metadata.listTablespaces()
            for (name, location) in Self.tablespaces where !tablespaces.contains(where: { $0.name == name && $0.location == location }) {
                problems.append("tablespace \(name) missing")
            }
            return problems
        }
        try await PostgresSession.with(server, database: database) { client in
            let view = try await client.metadata.materializedViewDetails(schema: "public", view: "pending_report")
            if view?.isPopulated != false { problems.append("pending_report populated: \(String(describing: view?.isPopulated))") }
            let triggers = try await client.metadata.listTriggers(schema: "public", table: "state_readings")
            if triggers.first(where: { $0.name == "paused_trigger" })?.isEnabled != false { problems.append("paused_trigger is not disabled") }
        }
        guard problems.isEmpty else { throw ServerLabError.packCheckFailed(pack: name, reason: problems.joined(separator: "; ")) }
    }
}
