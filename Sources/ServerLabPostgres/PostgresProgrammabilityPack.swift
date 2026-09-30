import Foundation
import PostgresKit
import ServerLabKit

/// A small sales schema with every kind of programmable object on top of it: schemas, a view and a
/// materialized view, SQL and PL/pgSQL functions (scalar, set-returning, trigger), a row trigger, a
/// procedure, a sequence, an enum, a domain and a composite type.
///
/// Parameters: `database` (default `labdata`), `customers` (rows, default 50).
struct PostgresProgrammabilityPack: ContentPack {
    let name = "programmability"
    let version = 1
    let summary = "Schemas, view, materialized view, functions, trigger, procedure, sequence, enum, domain, composite type."

    func apply(to server: ServerEndpoint, recipe: Recipe, parameters: PackParameters, log: LabLog) async throws {
        let database = try parameters.string("database", default: PostgresDatabasePack.defaultName)
        let customers = max(try parameters.int("customers", default: 50), 1)
        try await PostgresSession.with(server, database: database) { client in
            _ = try await client.admin.createSchema(name: "sales")
            _ = try await client.admin.createSchema(name: "hr")
            try await Self.createTypes(client)
            try await Self.createTables(client, customers: customers)
            try await Self.createRoutines(client)
            _ = try await client.views.createView(
                name: "v_customer_orders", schema: "sales",
                query: "SELECT c.id AS customer_id, c.name, count(o.id) AS order_count, sum(o.total) AS revenue FROM sales.customers c LEFT JOIN sales.orders o ON o.customer_id = c.id GROUP BY c.id, c.name"
            )
            _ = try await client.views.createMaterializedView(
                name: "mv_revenue_by_state", schema: "sales",
                query: "SELECT state, count(*) AS orders, sum(total) AS revenue FROM sales.orders GROUP BY state"
            )
            _ = try await client.sequences.createSequence(name: "invoice_numbers", schema: "sales", startWith: 1, incrementBy: 10, maxValue: 1_000, cycle: true)
        }
        log("  schemas, tables, views, functions, trigger, procedure, sequence, enum, domain, composite type")
    }

    func verify(on server: ServerEndpoint, recipe: Recipe, parameters: PackParameters) async throws {
        let database = try parameters.string("database", default: PostgresDatabasePack.defaultName)
        let customers = max(try parameters.int("customers", default: 50), 1)
        let (objects, customerRows, orderRows, auditRows) = try await PostgresSession.with(server, database: database) { client in
            (
                Set(try await client.metadata.listTablesAndViews(schema: "sales").map(\.name)),
                try await client.metadata.exactRowCount(schema: "sales", table: "customers"),
                try await client.metadata.exactRowCount(schema: "sales", table: "orders"),
                try await client.metadata.exactRowCount(schema: "sales", table: "order_audit")
            )
        }
        for expected in ["customers", "orders", "order_audit", "v_customer_orders"] where !objects.contains(expected) {
            throw ServerLabError.packCheckFailed(pack: name, reason: "sales.\(expected) is missing")
        }
        guard customerRows == Int64(customers), orderRows == Int64(customers * 3) else {
            throw ServerLabError.packCheckFailed(pack: name, reason: "\(customerRows) customers and \(orderRows) orders")
        }
        // The audit trigger fired once per inserted order.
        guard auditRows == orderRows else {
            throw ServerLabError.packCheckFailed(pack: name, reason: "\(auditRows) audit rows for \(orderRows) orders")
        }
    }

    private static func createTypes(_ client: PostgresClient) async throws {
        _ = try await client.types.createEnum(name: "order_state", schema: "sales", values: ["new", "paid", "shipped", "cancelled"])
        _ = try await client.types.createDomain(name: "email", dataType: "text", checkExpression: "VALUE ~ '^[^@]+@[^@]+$'", schema: "sales")
        _ = try await client.types.createCompositeType(name: "address", attributes: [
            (name: "street", dataType: "text"), (name: "city", dataType: "text"), (name: "postcode", dataType: "varchar(10)"),
        ], schema: "sales")
    }

    private static func createTables(_ client: PostgresClient, customers: Int) async throws {
        _ = try await client.admin.createTable(name: "customers", schema: "sales", columns: [
            PostgresColumnDefinition(name: "id", dataType: "integer GENERATED ALWAYS AS IDENTITY", nullable: false, primaryKey: true),
            PostgresColumnDefinition(name: "name", dataType: "text", nullable: false),
            PostgresColumnDefinition(name: "email", dataType: "sales.email"),
            PostgresColumnDefinition(name: "address", dataType: "sales.address"),
            PostgresColumnDefinition(name: "created_at", dataType: "timestamptz", nullable: false, defaultValue: "now()"),
        ])
        _ = try await client.admin.createTable(name: "orders", schema: "sales", columns: [
            PostgresColumnDefinition(name: "id", dataType: "integer GENERATED ALWAYS AS IDENTITY", nullable: false, primaryKey: true),
            PostgresColumnDefinition(name: "customer_id", dataType: "integer", nullable: false),
            PostgresColumnDefinition(name: "total", dataType: "numeric(12,2)", nullable: false),
            PostgresColumnDefinition(name: "state", dataType: "sales.order_state", nullable: false, defaultValue: "'new'"),
        ])
        _ = try await client.admin.createTable(name: "order_audit", schema: "sales", columns: [
            PostgresColumnDefinition(name: "id", dataType: "bigint GENERATED ALWAYS AS IDENTITY", nullable: false, primaryKey: true),
            PostgresColumnDefinition(name: "order_id", dataType: "integer", nullable: false),
            PostgresColumnDefinition(name: "action", dataType: "text", nullable: false),
            PostgresColumnDefinition(name: "at", dataType: "timestamptz", nullable: false, defaultValue: "now()"),
        ])
        _ = try await client.bulk.insert(into: "customers", schema: "sales", columns: ["name", "email", "address"], values: (1...customers).map {
            [
                PostgresInsertValue("Customer \($0)"),
                $0 % 5 == 0 ? .null : PostgresInsertValue("customer\($0)@example.com"),
                .sql("ROW('Street \($0)', 'City \($0 % 7)', '\(1000 + $0)')::sales.address"),
            ]
        })
        // Orders go in after the audit trigger exists (createRoutines), so the trigger fires for each.
    }

    private static func createRoutines(_ client: PostgresClient) async throws {
        _ = try await client.routines.createFunction(
            name: "with_tax", schema: "sales",
            parameters: [PostgresFunctionParameter(name: "amount", dataType: "numeric")],
            returnType: "numeric", body: "SELECT amount * 1.25", language: .sql, security: .invoker, immutable: true
        )
        _ = try await client.routines.createFunction(
            name: "orders_for", schema: "sales",
            parameters: [PostgresFunctionParameter(name: "customer", dataType: "integer")],
            returnType: "TABLE(order_id integer, total numeric)",
            body: "BEGIN RETURN QUERY SELECT o.id, o.total FROM sales.orders o WHERE o.customer_id = customer; END",
            language: .plpgsql, security: .invoker, stable: true
        )
        _ = try await client.routines.createFunction(
            name: "audit_orders", schema: "sales", parameters: [], returnType: "trigger",
            body: """
            BEGIN
              INSERT INTO sales.order_audit (order_id, action) VALUES (COALESCE(NEW.id, OLD.id), lower(TG_OP));
              RETURN COALESCE(NEW, OLD);
            END
            """,
            language: .plpgsql, security: .invoker
        )
        _ = try await client.triggers.createTrigger(
            name: "orders_audit", table: "orders", schema: "sales", event: .after,
            operations: [.insert, .update, .delete], procedure: "sales.audit_orders()"
        )
        _ = try await client.routines.createProcedure(
            name: "mark_paid", schema: "sales",
            parameters: [PostgresFunctionParameter(name: "order_id", dataType: "integer")],
            body: "BEGIN UPDATE sales.orders SET state = 'paid' WHERE id = order_id; END"
        )
        let customers = try await client.metadata.exactRowCount(schema: "sales", table: "customers")
        _ = try await client.bulk.insert(into: "orders", schema: "sales", columns: ["customer_id", "total", "state"], values: (1...Int(customers) * 3).map {
            [
                PostgresInsertValue($0 % Int(customers) + 1),
                .sql("\($0 * 7).\($0 % 100)"),
                .sql("'\(["new", "paid", "shipped"][$0 % 3])'::sales.order_state"),
            ]
        })
    }
}
