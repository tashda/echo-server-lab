import Foundation
import MySQLKit
import MySQLWire
import ServerLabKit

/// Customers and orders with a view, a procedure, a function, BEFORE and AFTER triggers (one
/// writes an audit log) and a scheduled event. Parameters: `database` (default `labdata`).
struct MySQLProgrammabilityPack: ContentPack {
    let name = "programmability"
    let version = 1
    let summary = "A view, procedure, function, triggers with an audit log, and a scheduled event."

    func apply(to server: ServerEndpoint, recipe: Recipe, parameters: PackParameters, context: PackContext) async throws {
        let database = try parameters.string("database", default: MySQLDatabasePack.defaultName)
        try await MySQLSession.with(server, database: database) { client in
            try await client.admin.createDatabase(name: database, ifNotExists: true)
            try await client.admin.createTable(schema: database, name: "customers", columns: [
                MySQLColumnDefinition(name: "id", dataType: "BIGINT UNSIGNED", isNullable: false, isAutoIncrement: true),
                MySQLColumnDefinition(name: "name", dataType: "VARCHAR(100)", isNullable: false),
                MySQLColumnDefinition(name: "is_active", dataType: "BOOLEAN", isNullable: false, defaultValue: .number("1")),
            ], primaryKey: ["id"])
            try await client.admin.createTable(schema: database, name: "orders", columns: [
                MySQLColumnDefinition(name: "id", dataType: "BIGINT UNSIGNED", isNullable: false, isAutoIncrement: true),
                MySQLColumnDefinition(name: "customer_id", dataType: "BIGINT UNSIGNED", isNullable: false),
                MySQLColumnDefinition(name: "amount", dataType: "DECIMAL(10,2)", isNullable: false),
                MySQLColumnDefinition(name: "created_at", dataType: "DATETIME(6)", isNullable: true),
            ], primaryKey: ["id"])
            try await client.admin.createTable(schema: database, name: "audit_log", columns: [
                MySQLColumnDefinition(name: "id", dataType: "BIGINT UNSIGNED", isNullable: false, isAutoIncrement: true),
                MySQLColumnDefinition(name: "action", dataType: "VARCHAR(20)", isNullable: false),
                MySQLColumnDefinition(name: "order_id", dataType: "BIGINT UNSIGNED"),
                MySQLColumnDefinition(name: "logged_at", dataType: "DATETIME(6)", isNullable: false, defaultValue: .currentTimestamp(precision: 6)),
            ], primaryKey: ["id"])
            try await client.constraints.addForeignKey(schema: database, table: "orders", name: "fk_orders_customer", columns: ["customer_id"],
                                                       referencedTable: "customers", referencedColumns: ["id"], onDelete: .cascade)

            try await client.triggers.createTrigger(schema: database, name: "orders_stamp", timing: .before, event: .insert, table: "orders",
                                                    bodySQL: "SET NEW.created_at = COALESCE(NEW.created_at, NOW(6))")
            try await client.triggers.createTrigger(schema: database, name: "orders_audit", timing: .after, event: .insert, table: "orders",
                                                    bodySQL: "INSERT INTO audit_log (action, order_id) VALUES ('insert', NEW.id)")
            try await client.views.createView(schema: database, name: "active_customers",
                                              definitionSQL: "SELECT id, name FROM customers WHERE is_active = 1")
            try await client.routines.createRoutine(
                schema: database, name: "customer_total", kind: .function, parametersSQL: "customer BIGINT UNSIGNED",
                returnsSQL: "DECIMAL(12,2)", characteristicsSQL: "DETERMINISTIC READS SQL DATA",
                bodySQL: "RETURN (SELECT COALESCE(SUM(amount), 0) FROM orders WHERE customer_id = customer)"
            )
            try await client.routines.createRoutine(
                schema: database, name: "add_order", kind: .procedure,
                parametersSQL: "IN customer BIGINT UNSIGNED, IN total DECIMAL(10,2), OUT order_id BIGINT UNSIGNED",
                bodySQL: "BEGIN INSERT INTO orders (customer_id, amount) VALUES (customer, total); SET order_id = LAST_INSERT_ID(); END"
            )
            try await client.events.createEvent(schema: database, name: "purge_audit_log", scheduleSQL: "EVERY 1 DAY",
                                                bodySQL: "DELETE FROM audit_log WHERE logged_at < NOW() - INTERVAL 30 DAY")

            try await client.bulk.insertValues(into: "customers", schema: database, columns: ["name", "is_active"],
                                               rows: (1...20).map { [.data(MySQLData(string: "Customer \($0)")), .data(MySQLData(int: $0 % 5 == 0 ? 0 : 1))] })
            try await client.bulk.insertValues(into: "orders", schema: database, columns: ["customer_id", "amount"],
                                               rows: (1...100).map { [.data(MySQLData(int: $0 % 20 + 1)), .data(MySQLData(string: "\($0).50"))] })
            context.log("  view, function, procedure, 2 triggers, event; 20 customers, 100 orders")
        }
    }

    func verify(on server: ServerEndpoint, recipe: Recipe, parameters: PackParameters) async throws {
        let database = try parameters.string("database", default: MySQLDatabasePack.defaultName)
        let (views, functions, procedures, triggers, events, audits) = try await MySQLSession.with(server, database: database) { client in
            (try await client.metadata.listViews(in: database).count, try await client.metadata.listFunctions(in: database).count,
             try await client.metadata.listProcedures(in: database).count, try await client.metadata.listTriggers(in: database).count,
             try await client.metadata.listEvents(in: database).count, try await client.metadata.exactRowCount(schema: database, table: "audit_log"))
        }
        guard views == 1, functions == 1, procedures == 1, triggers == 2, events == 1, audits == 100 else {
            throw ServerLabError.packCheckFailed(pack: name, reason: "views \(views), functions \(functions), procedures \(procedures), triggers \(triggers), events \(events), audit rows \(audits)")
        }
    }
}

/// Indexes of every kind and constraints: unique, composite with a descending column, prefix,
/// FULLTEXT, SPATIAL, invisible (MySQL), foreign key, CHECK. Parameters: `database`.
struct MySQLIndexesPack: ContentPack {
    let name = "indexes-constraints"
    let version = 1
    let summary = "Unique, composite, prefix, FULLTEXT, SPATIAL and invisible indexes; foreign key, CHECK and unique constraints."

    func apply(to server: ServerEndpoint, recipe: Recipe, parameters: PackParameters, context: PackContext) async throws {
        let database = try parameters.string("database", default: MySQLDatabasePack.defaultName)
        let mysql = recipe.engine == .mysql
        try await MySQLSession.with(server, database: database) { client in
            try await client.admin.createDatabase(name: database, ifNotExists: true)
            try await client.admin.createTable(schema: database, name: "categories", columns: [
                MySQLColumnDefinition(name: "id", dataType: "INT UNSIGNED", isNullable: false, isAutoIncrement: true),
                MySQLColumnDefinition(name: "name", dataType: "VARCHAR(50)", isNullable: false),
            ], primaryKey: ["id"])
            try await client.admin.createTable(schema: database, name: "products", columns: [
                MySQLColumnDefinition(name: "id", dataType: "INT UNSIGNED", isNullable: false, isAutoIncrement: true),
                MySQLColumnDefinition(name: "sku", dataType: "CHAR(12)", isNullable: false),
                MySQLColumnDefinition(name: "name", dataType: "VARCHAR(200)", isNullable: false),
                MySQLColumnDefinition(name: "description", dataType: "TEXT"),
                MySQLColumnDefinition(name: "price", dataType: "DECIMAL(10,2)", isNullable: false),
                MySQLColumnDefinition(name: "category_id", dataType: "INT UNSIGNED"),
                MySQLColumnDefinition(name: "location", dataType: "POINT", isNullable: false, srid: mysql ? 0 : nil),
            ], primaryKey: ["id"])
            try await client.indexes.createIndex(schema: database, table: "products", name: "ux_products_sku", columns: ["sku"], kind: .unique)
            try await client.indexes.createIndex(schema: database, table: "products", name: "ix_products_category_price",
                                                 columns: [MySQLIndexColumn("category_id"), MySQLIndexColumn("price", isDescending: true)])
            try await client.indexes.createIndex(schema: database, table: "products", name: "ix_products_name_prefix",
                                                 columns: [MySQLIndexColumn("name", prefixLength: 10)], comment: "first 10 characters")
            try await client.indexes.createIndex(schema: database, table: "products", name: "ft_products_text",
                                                 columns: ["name", "description"], kind: .fulltext)
            try await client.indexes.createIndex(schema: database, table: "products", name: "sx_products_location", columns: ["location"], kind: .spatial)
            if mysql {
                try await client.indexes.createIndex(schema: database, table: "products", name: "ix_products_price_invisible",
                                                     columns: ["price"], isInvisible: true)
            }
            try await client.constraints.addForeignKey(schema: database, table: "products", name: "fk_products_category", columns: ["category_id"],
                                                       referencedTable: "categories", referencedColumns: ["id"], onDelete: .setNull, onUpdate: .cascade)
            try await client.constraints.addCheck(schema: database, table: "products", name: "ck_products_price", expression: "price >= 0")
            try await client.constraints.addUnique(schema: database, table: "products", name: "uq_products_name_category", columns: ["name", "category_id"])

            try await client.bulk.insertValues(into: "categories", schema: database, columns: ["name"],
                                               rows: ["Books", "Music", "Tools"].map { [.data(MySQLData(string: $0))] })
            try await client.bulk.insertValues(into: "products", schema: database, columns: ["sku", "name", "description", "price", "category_id", "location"],
                                               rows: (1...60).map { index in [
                                                   .data(MySQLData(string: String(format: "SKU%09d", index))), .data(MySQLData(string: "Product \(index)")),
                                                   .data(MySQLData(string: "A useful product number \(index)")), .data(MySQLData(string: "\(index).99")),
                                                   .data(MySQLData(int: index % 3 + 1)), .geometry(wkt: "POINT(\(index % 90) \(index % 45))"),
                                               ] })
            context.log("  products with \(mysql ? 6 : 5) indexes, foreign key, check and unique constraints")
        }
    }

    func verify(on server: ServerEndpoint, recipe: Recipe, parameters: PackParameters) async throws {
        let database = try parameters.string("database", default: MySQLDatabasePack.defaultName)
        let structure = try await MySQLSession.with(server, database: database) { try await $0.metadata.tableStructure(for: "products", schema: database) }
        let names = Set(structure.indexes.map(\.name))
        let expected: Set = ["ux_products_sku", "ix_products_category_price", "ix_products_name_prefix", "ft_products_text", "sx_products_location", "uq_products_name_category"]
        guard expected.isSubset(of: names), structure.foreignKeys.count == 1 else {
            throw ServerLabError.packCheckFailed(pack: name, reason: "indexes \(names.sorted()), foreign keys \(structure.foreignKeys.count)")
        }
    }
}

/// Roles, users with different authentication and grants: `lab_reader` and `lab_writer` roles,
/// `lab_app` (role-based), `lab_readonly` (direct SELECT), `lab_admin` (everything on the database
/// with grant option), and a locked account. Passwords: the lab password. Parameters: `database`.
struct MySQLSecurityPack: ContentPack {
    let name = "security"
    let version = 1
    let summary = "Roles, users with grants (role-based, direct, admin with grant option) and a locked account."

    func apply(to server: ServerEndpoint, recipe: Recipe, parameters: PackParameters, context: PackContext) async throws {
        let database = try parameters.string("database", default: MySQLDatabasePack.defaultName)
        let password = server.password
        try await MySQLSession.with(server) { client in
            try await client.admin.createDatabase(name: database, ifNotExists: true)
            let security = client.security
            try await security.createRole(name: "lab_reader")
            try await security.createRole(name: "lab_writer")
            for user in ["lab_app", "lab_readonly", "lab_admin", "lab_locked"] {
                _ = try await security.createUser(username: user, host: "%", password: password)
            }
            _ = try await security.grant("SELECT", on: "`\(database)`.*", to: "lab_reader", host: nil)
            _ = try await security.grant("SELECT, INSERT, UPDATE, DELETE", on: "`\(database)`.*", to: "lab_writer", host: nil)
            try await security.grantRole("lab_writer", to: "lab_app", host: "%")
            _ = try await security.grant("SELECT", on: "`\(database)`.*", to: "lab_readonly", host: "%")
            _ = try await security.grant("ALL PRIVILEGES", on: "`\(database)`.*", to: "lab_admin", host: "%", withGrantOption: true)
            _ = try await security.lockUser(username: "lab_locked", host: "%")
            context.log("  roles lab_reader, lab_writer; users lab_app, lab_readonly, lab_admin, lab_locked")
        }
    }

    func verify(on server: ServerEndpoint, recipe: Recipe, parameters: PackParameters) async throws {
        let users = try await MySQLSession.with(server) { try await $0.security.listUsers() }
        let expected: Set = ["lab_app", "lab_readonly", "lab_admin", "lab_locked"]
        guard expected.isSubset(of: Set(users.map(\.username))), users.first(where: { $0.username == "lab_locked" })?.accountLocked == true else {
            throw ServerLabError.packCheckFailed(pack: name, reason: "users \(users.map { "\($0.username)\($0.accountLocked ? " (locked)" : "")" }.sorted())")
        }
    }
}
