import Foundation
import ServerLabKit
import SQLServerKit

private func column(_ name: String, _ type: SQLDataType, nullable: Bool = false, key: Bool = false, identity: Bool = false) -> SQLServerColumnDefinition {
    SQLServerColumnDefinition(name: name, definition: .standard(.init(dataType: type, isNullable: nullable, isPrimaryKey: key, identity: identity ? (1, 1) : nil)))
}

/// Change Tracking on the database and a table, and Change Data Capture on another table (needs
/// Agent), each with changes made after it was turned on. Parameter: `database` (default LabData).
struct SQLServerChangeTrackingPack: ContentPack {
    let name = "change-tracking"
    let version = 1
    let summary = "Change Tracking and Change Data Capture on tables, with changes."

    func apply(to server: ServerEndpoint, recipe: Recipe, parameters: PackParameters, context: PackContext) async throws {
        let database = try parameters.string("database", default: SQLServerDatabasePack.defaultName)
        try await SQLServerSession.with(server, database: database) { client in
            try await client.withConnection { connection in
                try await connection.createTable(name: "TrackedOrders", columns: [column("Id", .int, key: true, identity: true),
                                                                                  column("Status", .nvarchar(length: .length(20)))], schema: "dbo")
                try await connection.createTable(name: "CapturedPayments", columns: [column("Id", .int, key: true, identity: true),
                                                                                     column("Amount", .decimal(precision: 10, scale: 2))], schema: "dbo")
            }
            try await client.changeTracking.enableChangeTracking(database: database)
            try await client.changeTracking.enableTableChangeTracking(schema: "dbo", table: "TrackedOrders")
            try await client.changeTracking.enableDatabaseCDC()
            try await client.changeTracking.enableCDC(schema: "dbo", table: "CapturedPayments")
            let admin = client.admin.scoped(to: database)
            try await admin.insertRows(into: "TrackedOrders", columns: ["Status"], values: (1...20).map { [.nString(["new", "paid"][$0 % 2])] })
            try await admin.insertRows(into: "CapturedPayments", columns: ["Amount"], values: (1...20).map { [.decimal("\($0).99")] })
        }
        context.log("  Change Tracking on TrackedOrders, CDC on CapturedPayments")
    }

    func verify(on server: ServerEndpoint, recipe: Recipe, parameters: PackParameters) async throws {
        let database = try parameters.string("database", default: SQLServerDatabasePack.defaultName)
        let (tracked, captured) = try await SQLServerSession.with(server, database: database) { client in
            (try await client.changeTracking.listChangeTrackingTables().count, try await client.changeTracking.listCDCTables().count)
        }
        guard tracked >= 1, captured >= 1 else {
            throw ServerLabError.packCheckFailed(pack: name, reason: "\(tracked) tracked, \(captured) captured tables")
        }
    }
}

/// Extended properties (MS_Description and custom ones) on a table, its columns, a view and an index.
struct SQLServerExtendedPropertiesPack: ContentPack {
    let name = "extended-properties"
    let version = 1
    let summary = "Extended properties on a table, columns, a view and an index."

    func apply(to server: ServerEndpoint, recipe: Recipe, parameters: PackParameters, context: PackContext) async throws {
        let database = try parameters.string("database", default: SQLServerDatabasePack.defaultName)
        try await SQLServerSession.with(server, database: database) { client in
            try await client.withConnection { connection in
                try await connection.createTable(name: "DescribedItems", columns: [column("Id", .int, key: true), column("Title", .nvarchar(length: .length(100)))], schema: "dbo")
            }
            try await client.views.createView(name: "vDescribedItems", query: "SELECT Id, Title FROM dbo.DescribedItems", schema: "dbo")
            let properties = client.extendedProperties
            try await properties.add(name: "MS_Description", value: "Items with descriptions everywhere", target: .table(schema: "dbo", name: "DescribedItems"))
            try await properties.add(name: "Owner", value: "Echo lab", target: .table(schema: "dbo", name: "DescribedItems"))
            try await properties.add(name: "MS_Description", value: "The key", target: .column(schema: "dbo", table: "DescribedItems", column: "Id"))
            try await properties.add(name: "MS_Description", value: "Shown to users (ünïcode ✓)", target: .column(schema: "dbo", table: "DescribedItems", column: "Title"))
            try await properties.add(name: "MS_Description", value: "Every item", target: .view(schema: "dbo", name: "vDescribedItems"))
        }
    }

    func verify(on server: ServerEndpoint, recipe: Recipe, parameters: PackParameters) async throws {
        let database = try parameters.string("database", default: SQLServerDatabasePack.defaultName)
        let count = try await SQLServerSession.with(server, database: database) {
            try await $0.extendedProperties.list(target: .table(schema: "dbo", name: "DescribedItems")).count
        }
        guard count == 2 else { throw ServerLabError.packCheckFailed(pack: name, reason: "\(count) table properties") }
    }
}

/// Extended Events sessions: one running with a ring buffer, one stopped writing to a file.
struct SQLServerExtendedEventsPack: ContentPack {
    let name = "extended-events"
    let version = 1
    let summary = "A running ring-buffer XE session and a stopped event-file session."

    func apply(to server: ServerEndpoint, recipe: Recipe, parameters: PackParameters, context: PackContext) async throws {
        try await SQLServerSession.with(server) { client in
            let events = client.extendedEvents
            try await events.createSession(SQLServerXESessionConfiguration(
                name: "lab_errors",
                events: [.init(eventName: "sqlserver.error_reported", actions: ["sqlserver.sql_text", "sqlserver.username"], predicate: "severity >= 11")],
                target: .ringBuffer(maxMemoryKB: 4096)
            ))
            try await events.startSession(name: "lab_errors")
            try await events.createSession(SQLServerXESessionConfiguration(
                name: "lab_logins",
                events: [.init(eventName: "sqlserver.login"), .init(eventName: "sqlserver.logout")],
                target: .eventFile(filename: "/var/opt/mssql/log/lab_logins.xel", maxFileSizeMB: 16)
            ))
        }
    }

    func verify(on server: ServerEndpoint, recipe: Recipe, parameters: PackParameters) async throws {
        let names = try await SQLServerSession.with(server) { try await $0.extendedEvents.listSessions().map(\.name) }
        guard Set(["lab_errors", "lab_logins"]).isSubset(of: Set(names)) else {
            throw ServerLabError.packCheckFailed(pack: name, reason: "sessions \(names)")
        }
    }
}

/// Resource Governor: a capped pool, a workload group in it, reconfigured.
struct SQLServerResourceGovernorPack: ContentPack {
    let name = "resource-governor"
    let version = 1
    let summary = "A resource pool capped at 50% CPU with a workload group, Resource Governor on."

    func apply(to server: ServerEndpoint, recipe: Recipe, parameters: PackParameters, context: PackContext) async throws {
        try await SQLServerSession.with(server) { client in
            let governor = client.resourceGovernor
            try await governor.createResourcePool(name: "lab_reporting", maxCpuPercent: 50, maxMemoryPercent: 40)
            try await governor.createWorkloadGroup(name: "lab_reports", poolName: "lab_reporting", importance: "LOW", maxDop: 2)
            try await governor.reconfigure()
        }
    }

    func verify(on server: ServerEndpoint, recipe: Recipe, parameters: PackParameters) async throws {
        let pools = try await SQLServerSession.with(server) { try await $0.resourceGovernor.listResourcePools().map(\.name) }
        guard pools.contains("lab_reporting") else { throw ServerLabError.packCheckFailed(pack: name, reason: "pools \(pools)") }
    }
}

/// Central Management Server groups and registered servers.
struct SQLServerCentralManagementPack: ContentPack {
    let name = "central-management"
    let version = 1
    let summary = "CMS groups (nested) with registered servers."

    func apply(to server: ServerEndpoint, recipe: Recipe, parameters: PackParameters, context: PackContext) async throws {
        try await SQLServerSession.with(server, database: "msdb") { client in
            try await client.cms.addGroup(name: "Production", description: "Live servers")
            try await client.cms.addGroup(name: "Test", description: "Lab servers")
            let groups = try await client.cms.listGroups()
            if let production = groups.first(where: { $0.name == "Production" }) {
                try await client.cms.addGroup(name: "Reporting", parentId: production.groupId)
                try await client.cms.addServer(serverName: "sql-prod-01.lab.test", groupId: production.groupId, description: "Primary")
                try await client.cms.addServer(serverName: "sql-prod-02.lab.test", groupId: production.groupId)
            }
            if let test = groups.first(where: { $0.name == "Test" }) {
                try await client.cms.addServer(serverName: "sql-test-01.lab.test", groupId: test.groupId)
            }
        }
    }

    func verify(on server: ServerEndpoint, recipe: Recipe, parameters: PackParameters) async throws {
        let (groups, servers) = try await SQLServerSession.with(server, database: "msdb") { client in
            (try await client.cms.listGroups().map(\.name), try await client.cms.listServers().count)
        }
        guard Set(["Production", "Test", "Reporting"]).isSubset(of: Set(groups)), servers == 3 else {
            throw ServerLabError.packCheckFailed(pack: name, reason: "groups \(groups), \(servers) servers")
        }
    }
}

/// Logins with little permission, for the "what does Echo show when it may not see this" cases:
/// connect only, read only, VIEW DEFINITION denied, Agent reader in msdb. Password: the lab password.
struct SQLServerLowPrivilegePack: ContentPack {
    let name = "low-privilege"
    let version = 1
    let summary = "Logins that can only connect, only read, cannot see definitions, or only read Agent."

    func apply(to server: ServerEndpoint, recipe: Recipe, parameters: PackParameters, context: PackContext) async throws {
        let database = try parameters.string("database", default: SQLServerDatabasePack.defaultName)
        let logins = ["lab_connect_only", "lab_read_only", "lab_no_definitions", "lab_agent_reader"]
        try await SQLServerSession.with(server) { client in
            for login in logins {
                try await client.serverSecurity.createSqlLogin(name: login, password: server.password, options: .init(defaultDatabase: database, checkPolicy: false))
            }
        }
        try await SQLServerSession.with(server, database: database) { client in
            let security = client.security
            for login in logins.prefix(3) { try await security.createUser(name: login, login: login) }
            try await security.addUserToRole(user: "lab_read_only", role: "db_datareader")
            try await security.addUserToRole(user: "lab_no_definitions", role: "db_datareader")
            try await security.deny(permission: .viewDefinition, on: .database(nil), to: "lab_no_definitions")
        }
        try await SQLServerSession.with(server, database: "msdb") { client in
            try await client.security.createUser(name: "lab_agent_reader", login: "lab_agent_reader")
            try await client.security.addUserToRole(user: "lab_agent_reader", role: "SQLAgentReaderRole")
        }
    }

    func verify(on server: ServerEndpoint, recipe: Recipe, parameters: PackParameters) async throws {
        let names = try await SQLServerSession.with(server) { try await $0.serverSecurity.listLogins().map(\.name) }
        guard Set(["lab_connect_only", "lab_read_only", "lab_no_definitions", "lab_agent_reader"]).isSubset(of: Set(names)) else {
            throw ServerLabError.packCheckFailed(pack: name, reason: "logins \(names.filter { $0.hasPrefix("lab_") })")
        }
    }
}

/// Edge cases: hostile names at every level (Unicode, spaces, brackets, quotes, reserved words),
/// a NULL-heavy table, empty tables and schema, and a 20-view dependency chain.
struct SQLServerEdgeCasesPack: ContentPack {
    let name = "edge-cases"
    let version = 1
    let summary = "Hostile names, NULL-heavy and empty tables, a 20-level view dependency chain."
    static let hostileSchema = "Ünïcödé Schema 名前"
    static let hostileTable = "Table [With] \"Quotes\" 'and' spaces"

    func apply(to server: ServerEndpoint, recipe: Recipe, parameters: PackParameters, context: PackContext) async throws {
        let database = try parameters.string("database", default: SQLServerDatabasePack.defaultName)
        try await SQLServerSession.with(server, database: database) { client in
            try await client.security.createSchema(name: Self.hostileSchema)
            try await client.security.createSchema(name: "empty_schema")
            try await client.withConnection { connection in
                try await connection.createTable(name: Self.hostileTable, columns: [
                    column("select", .int, key: true), column("Order", .nvarchar(length: .length(50)), nullable: true),
                    column("with space", .int, nullable: true), column("a]b", .int, nullable: true), column("emoji 😀", .nvarchar(length: .length(10)), nullable: true),
                ], schema: Self.hostileSchema)
                try await connection.createTable(name: "EmptyTable", columns: [column("Id", .int, key: true), column("Value", .int, nullable: true)], schema: "dbo")
                try await connection.createTable(name: "MostlyNull", columns: [column("Id", .int, key: true)]
                    + [("A", SQLDataType.int), ("B", .nvarchar(length: .max)), ("C", .datetime2(precision: 7)), ("D", .decimal(precision: 18, scale: 4)),
                       ("E", .uniqueidentifier), ("F", .varbinary(length: .max)), ("G", .bit), ("H", .float(mantissa: 53))].map { column($0.0, $0.1, nullable: true) },
                    schema: "dbo")
            }
            let admin = client.admin.scoped(to: database)
            try await admin.insertRows(into: Self.hostileTable, schema: Self.hostileSchema, columns: ["select", "Order", "with space", "a]b", "emoji 😀"],
                                       values: (1...5).map { [.int($0), .nString("order \($0)"), .int($0 * 2), .null, .nString("😀\($0)")] })
            try await admin.insertRows(into: "MostlyNull", columns: ["Id", "A"],
                                       values: (1...500).map { [.int($0), $0 % 10 == 0 ? .int($0) : .null] })
            try await client.views.createView(name: "vChain01", query: "SELECT Id, A FROM dbo.MostlyNull", schema: "dbo")
            for level in 2...20 {
                try await client.views.createView(name: String(format: "vChain%02d", level),
                                                  query: String(format: "SELECT Id, A FROM dbo.vChain%02d", level - 1), schema: "dbo")
            }
        }
    }

    func verify(on server: ServerEndpoint, recipe: Recipe, parameters: PackParameters) async throws {
        let database = try parameters.string("database", default: SQLServerDatabasePack.defaultName)
        let (hostileRows, views) = try await SQLServerSession.with(server, database: database) { client in
            (try await client.metadata.tableProperties(database: database, schema: Self.hostileSchema, table: Self.hostileTable).rowCount,
             try await client.views.listViews(database: database, schema: "dbo").filter { $0.name.hasPrefix("vChain") }.count)
        }
        guard hostileRows == 5, views == 20 else {
            throw ServerLabError.packCheckFailed(pack: name, reason: "\(hostileRows) rows under the hostile name, \(views) chained views")
        }
    }
}
