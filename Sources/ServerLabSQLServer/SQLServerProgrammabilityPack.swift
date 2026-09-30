import Foundation
import ServerLabKit
import SQLServerKit

/// A small sales schema with every kind of programmable object on top of it: schemas, views (plain,
/// schema-bound, indexed), procedures (input/output parameters, recompile, execute as), scalar,
/// inline and multi-statement functions, DML and DDL triggers, sequences, synonyms, alias and
/// table types.
///
/// Parameters: `database` (default `LabData`), `customers` (rows, default 50).
struct SQLServerProgrammabilityPack: ContentPack {
    let name = "programmability"
    let version = 1
    let summary = "Schemas, views, indexed view, procedures, scalar/inline/multi-statement functions, triggers, sequences, synonyms, types."

    func apply(to server: ServerEndpoint, recipe: Recipe, parameters: PackParameters, log: LabLog) async throws {
        let database = try parameters.string("database", default: SQLServerDatabasePack.defaultName)
        let customers = try parameters.int("customers", default: 50)
        try await SQLServerSession.with(server, database: database) { client in
            for schema in ["sales", "hr"] {
                try await client.security.createSchema(name: schema)
            }
            try await Self.createTables(client, database: database, customers: customers)
            try await Self.createViews(client)
            try await Self.createRoutines(client)
            try await Self.createTriggers(client, database: database)
            try await Self.createSequencesSynonymsAndTypes(client, database: database)
        }
        log("  schemas, tables, views, procedures, functions, triggers, sequences, synonyms, types")
    }

    func verify(on server: ServerEndpoint, recipe: Recipe, parameters: PackParameters) async throws {
        let database = try parameters.string("database", default: SQLServerDatabasePack.defaultName)
        let counts = try await SQLServerSession.with(server, database: database) { client in
            [
                "procedures": try await client.metadata.listProcedures(database: database, schema: "sales").count,
                "functions": try await client.metadata.listFunctions(database: database).filter { $0.schema != "sys" }.count,
                "triggers": try await client.metadata.listTriggers(database: database, schema: "sales").count,
                "sequences": try await client.metadata.listSequences(database: database).count,
                "synonyms": try await client.metadata.listSynonyms(database: database).count,
                "user types": try await client.metadata.listUserTypes(database: database).count,
                "views": try await client.metadata.listTables(database: database).filter { $0.type.uppercased().contains("VIEW") }.count,
            ]
        }
        let expected = ["procedures": 2, "functions": 3, "triggers": 1, "sequences": 2, "synonyms": 1, "user types": 2, "views": 3]
        for (kind, count) in expected where (counts[kind] ?? 0) < count {
            throw ServerLabError.packCheckFailed(pack: name, reason: "found \(counts[kind] ?? 0) \(kind), expected \(count)")
        }
    }

    private static func column(_ name: String, _ type: SQLDataType, nullable: Bool = false, key: Bool = false,
                               identity: Bool = false, defaultValue: String? = nil) -> SQLServerColumnDefinition {
        SQLServerColumnDefinition(name: name, definition: .standard(.init(
            dataType: type, isNullable: nullable, isPrimaryKey: key, identity: identity ? (1, 1) : nil, defaultValue: defaultValue
        )))
    }

    private static func createTables(_ client: SQLServerClient, database: String, customers: Int) async throws {
        try await client.withConnection { connection in
            try await connection.createTable(name: "Customers", columns: [
                column("Id", .int, key: true, identity: true),
                column("Name", .nvarchar(length: .length(100))),
                column("Email", .varchar(length: .length(200)), nullable: true),
                column("CreatedAt", .datetime2(precision: 3), defaultValue: "SYSUTCDATETIME()"),
            ], schema: "sales")
            try await connection.createTable(name: "Orders", columns: [
                column("Id", .int, key: true, identity: true),
                column("CustomerId", .int),
                column("Total", .decimal(precision: 12, scale: 2)),
                column("Status", .varchar(length: .length(20)), defaultValue: "'new'"),
            ], schema: "sales")
            try await connection.createTable(name: "OrderAudit", columns: [
                column("Id", .int, key: true, identity: true),
                column("OrderId", .int),
                column("Action", .varchar(length: .length(10))),
                column("At", .datetime2(precision: 3), defaultValue: "SYSUTCDATETIME()"),
            ], schema: "sales")
            try await connection.createTable(name: "SchemaChanges", columns: [
                column("Id", .int, key: true, identity: true),
                column("EventType", .nvarchar(length: .length(100))),
                column("ObjectName", .nvarchar(length: .length(256)), nullable: true),
                column("At", .datetime2(precision: 3), defaultValue: "SYSUTCDATETIME()"),
            ], schema: "hr")
        }
        let admin = client.admin.scoped(to: database)
        try await admin.insertRows(into: "Customers", schema: "sales", columns: ["Name", "Email"], values: (1...max(customers, 1)).map {
            [.nString("Customer \($0)"), $0 % 5 == 0 ? .null : .string("customer\($0)@example.com")]
        })
        try await admin.insertRows(into: "Orders", schema: "sales", columns: ["CustomerId", "Total", "Status"], values: (1...max(customers, 1) * 3).map {
            [.int($0 % max(customers, 1) + 1), .decimal("\($0 * 7).\($0 % 100)"), .string(["new", "paid", "shipped"][$0 % 3])]
        })
    }

    private static func createViews(_ client: SQLServerClient) async throws {
        try await client.views.createView(
            name: "vCustomerOrders",
            query: "SELECT c.Id AS CustomerId, c.Name, COUNT(o.Id) AS OrderCount, SUM(o.Total) AS Revenue FROM sales.Customers c LEFT JOIN sales.Orders o ON o.CustomerId = c.Id GROUP BY c.Id, c.Name",
            schema: "sales"
        )
        try await client.views.createView(
            name: "vPaidOrders",
            query: "SELECT Id, CustomerId, Total FROM sales.Orders WHERE Status = 'paid'",
            schema: "sales",
            options: ViewOptions(schema: "sales", withSchemaBinding: true, withCheckOption: true)
        )
        try await client.views.createIndexedView(
            name: "vOrderTotalsByStatus",
            query: "SELECT Status, COUNT_BIG(*) AS Orders, SUM(Total) AS Revenue FROM sales.Orders GROUP BY Status",
            indexName: "IX_vOrderTotalsByStatus",
            indexColumns: ["Status"],
            schema: "sales",
            options: ViewOptions(schema: "sales", withSchemaBinding: true)
        )
    }

    private static func createRoutines(_ client: SQLServerClient) async throws {
        try await client.routines.createStoredProcedure(
            name: "usp_GetCustomerOrders",
            parameters: [ProcedureParameter(name: "CustomerId", dataType: .int)],
            body: "SET NOCOUNT ON; SELECT Id, Total, Status FROM sales.Orders WHERE CustomerId = @CustomerId ORDER BY Id;",
            schema: "sales",
            options: RoutineOptions(schema: "sales", withRecompile: true)
        )
        try await client.routines.createStoredProcedure(
            name: "usp_AddOrder",
            parameters: [
                ProcedureParameter(name: "CustomerId", dataType: .int),
                ProcedureParameter(name: "Total", dataType: .decimal(precision: 12, scale: 2), defaultValue: "0"),
                ProcedureParameter(name: "NewId", dataType: .int, direction: .output),
            ],
            body: "SET NOCOUNT ON; INSERT INTO sales.Orders (CustomerId, Total) VALUES (@CustomerId, @Total); SET @NewId = SCOPE_IDENTITY();",
            schema: "sales",
            options: RoutineOptions(schema: "sales", executeAs: "OWNER")
        )
        try await client.routines.createFunction(
            name: "fn_WithTax",
            parameters: [FunctionParameter(name: "Amount", dataType: .decimal(precision: 12, scale: 2))],
            returnType: .decimal(precision: 12, scale: 2),
            body: "BEGIN RETURN @Amount * 1.25; END"
        )
        try await client.routines.createInlineTableValuedFunction(
            name: "fn_OrdersFor",
            parameters: [FunctionParameter(name: "CustomerId", dataType: .int)],
            query: "SELECT Id, Total, Status FROM sales.Orders WHERE CustomerId = @CustomerId",
            schema: "sales"
        )
        try await client.routines.createTableValuedFunction(
            name: "fn_TopCustomers",
            parameters: [FunctionParameter(name: "Top", dataType: .int, defaultValue: "5")],
            tableDefinition: [
                TableValuedFunctionColumn(name: "CustomerId", dataType: .int),
                TableValuedFunctionColumn(name: "Revenue", dataType: .decimal(precision: 14, scale: 2)),
            ],
            body: "BEGIN INSERT INTO @result_table SELECT TOP (@Top) CustomerId, SUM(Total) FROM sales.Orders GROUP BY CustomerId ORDER BY SUM(Total) DESC; RETURN; END",
            schema: "sales"
        )
    }

    private static func createTriggers(_ client: SQLServerClient, database: String) async throws {
        try await client.triggers.createTrigger(
            name: "trg_Orders_Audit",
            table: "Orders",
            timing: .after,
            events: [.insert, .update, .delete],
            body: """
            SET NOCOUNT ON;
            INSERT INTO sales.OrderAudit (OrderId, Action) SELECT Id, 'insert' FROM inserted WHERE Id NOT IN (SELECT Id FROM deleted);
            INSERT INTO sales.OrderAudit (OrderId, Action) SELECT Id, 'delete' FROM deleted WHERE Id NOT IN (SELECT Id FROM inserted);
            INSERT INTO sales.OrderAudit (OrderId, Action) SELECT Id, 'update' FROM inserted WHERE Id IN (SELECT Id FROM deleted);
            """,
            schema: "sales",
            options: TriggerOptions(schema: "sales")
        )
        try await client.triggers.createDatabaseDDLTrigger(
            name: "trg_LogSchemaChanges",
            database: database,
            events: ["DDL_TABLE_EVENTS"],
            body: """
            SET NOCOUNT ON;
            DECLARE @e XML = EVENTDATA();
            INSERT INTO hr.SchemaChanges (EventType, ObjectName)
            VALUES (@e.value('(/EVENT_INSTANCE/EventType)[1]', 'nvarchar(100)'), @e.value('(/EVENT_INSTANCE/ObjectName)[1]', 'nvarchar(256)'));
            """
        )
    }

    private static func createSequencesSynonymsAndTypes(_ client: SQLServerClient, database: String) async throws {
        let admin = client.admin.scoped(to: database)
        try await admin.createSequence(name: "OrderNumbers", type: .int, start: 1000, increment: 1)
        try await admin.createSequence(name: "InvoiceNumbers", schema: "sales", start: 1, increment: 10, minValue: 1, maxValue: 1_000, cycle: true, cache: .size(20))
        try await admin.createSynonym(name: "Customers", target: SQLServerObjectName(database: database, schema: "sales", object: "Customers"))
        try await client.types.createAliasType(name: "PhoneNumber", baseType: .varchar(length: .length(20)), isNullable: false)
        try await client.types.createUserDefinedTableType(UserDefinedTableTypeDefinition(name: "OrderLineList", columns: [
            UserDefinedTableTypeColumn(name: "Sku", dataType: .varchar(length: .length(20)), isNullable: false),
            UserDefinedTableTypeColumn(name: "Quantity", dataType: .int, isNullable: false),
        ]))
    }
}
