import Foundation
import ServerLabKit
import SQLServerKit

/// One database in every state Echo has to show or refuse to open: offline, read-only, single-user,
/// restricted-user, emergency, auto-close, restoring (NORECOVERY), standby, detached and attached
/// again, owned by a disabled login, restored from a backup whose owner login no longer exists
/// (its `dbo` user maps to no login, as after a restore from another server), and a database
/// snapshot of a database whose table has a disabled index.
struct SQLServerDatabaseStatesPack: ContentPack {
    let name = "database-states"
    let version = 2
    let summary = "Databases offline, read-only, single-user, restricted, emergency, auto-close, restoring, standby, re-attached, with orphaned owners."

    static let dataDirectory = "/var/opt/mssql/data"

    /// The database, and the state and user access `sys.databases` must report for it.
    static let expected: [(database: String, state: String, access: String, readOnly: Bool)] = [
        ("StateOffline", "OFFLINE", "MULTI_USER", false),
        ("StateReadOnly", "ONLINE", "MULTI_USER", true),
        ("StateSingleUser", "ONLINE", "SINGLE_USER", false),
        ("StateRestrictedUser", "ONLINE", "RESTRICTED_USER", false),
        ("StateEmergency", "EMERGENCY", "MULTI_USER", false),
        ("StateAutoClose", "ONLINE", "MULTI_USER", false),
        ("StateRestoring", "RESTORING", "MULTI_USER", false),
        ("StateStandby", "ONLINE", "MULTI_USER", true),
        ("StateReattached", "ONLINE", "MULTI_USER", false),
        ("StateDisabledOwner", "ONLINE", "MULTI_USER", false),
        ("StateOrphanedOwner", "ONLINE", "MULTI_USER", false),
        ("StateSnapshotSource", "ONLINE", "MULTI_USER", false),
        ("StateSnapshot", "ONLINE", "MULTI_USER", true),
    ]

    func apply(to server: ServerEndpoint, recipe: Recipe, parameters: PackParameters, context: PackContext) async throws {
        try await SQLServerSession.with(server) { client in
            let admin = client.admin
            for database in Self.expected.map(\.database) where !["StateRestoring", "StateStandby", "StateOrphanedOwner", "StateSnapshot"].contains(database) {
                try await admin.createDatabase(name: database)
                try await admin.scoped(to: database).createTable(name: "Notes", columns: [
                    SQLServerColumnDefinition(name: "Id", definition: .standard(.init(dataType: .int, isPrimaryKey: true, identity: (1, 1)))),
                    SQLServerColumnDefinition(name: "Body", definition: .standard(.init(dataType: .nvarchar(length: .length(100))))),
                ])
                try await admin.scoped(to: database).insertRows(into: "Notes", columns: ["Body"], values: [[.nString("written in \(database)")]])
            }
            try await admin.takeDatabaseOffline(name: "StateOffline")
            try await admin.alterDatabaseOption(name: "StateReadOnly", option: .readOnly(true))
            try await admin.setDatabaseSingleUser(name: "StateSingleUser")
            try await admin.alterDatabaseOption(name: "StateRestrictedUser", option: .userAccess(.restrictedUser))
            try await admin.alterDatabaseOption(name: "StateEmergency", option: .databaseState(.emergency))
            try await admin.alterDatabaseOption(name: "StateAutoClose", option: .autoClose(true))

            // Detached and attached again from its files.
            let files = try await client.backupRestore.listDatabaseFiles(database: "StateReattached").map(\.physicalName)
            try await admin.detachDatabase(name: "StateReattached")
            try await admin.attachDatabase(name: "StateReattached", files: files)

            // Owned by a login that is disabled.
            try await client.serverSecurity.createSqlLogin(name: "lab_disabled_owner", password: server.password, options: .init(checkPolicy: false))
            try await admin.setDatabaseOwner(name: "StateDisabledOwner", login: "lab_disabled_owner")
            try await client.serverSecurity.enableLogin(name: "lab_disabled_owner", enabled: false)

            // Restoring and standby copies of one backup.
            let backup = "\(Self.dataDirectory)/StateSource.bak"
            try await admin.createDatabase(name: "StateSource")
            try await client.backupRestore.backup(options: SQLServerBackupOptions(database: "StateSource", destinations: [.disk(path: backup)], initMedia: true))
            try await restore(client, backup: backup, as: "StateRestoring", mode: .noRecovery)
            try await restore(client, backup: backup, as: "StateStandby", mode: .standby, standbyFile: "\(Self.dataDirectory)/StateStandby_undo.dat")

            // Owned by a login that no longer exists: back up a database it owns, drop both, restore.
            // The restore makes the restoring login the owner; dbo inside keeps the dropped login's SID.
            let orphanBackup = "\(Self.dataDirectory)/StateOrphanedOwner.bak"
            try await admin.createDatabase(name: "StateOrphanedOwner")
            try await client.serverSecurity.createSqlLogin(name: "lab_departed_owner", password: server.password, options: .init(checkPolicy: false))
            try await admin.setDatabaseOwner(name: "StateOrphanedOwner", login: "lab_departed_owner")
            try await client.backupRestore.backup(options: SQLServerBackupOptions(database: "StateOrphanedOwner", destinations: [.disk(path: orphanBackup)], initMedia: true))
            try await admin.dropDatabase(name: "StateOrphanedOwner")
            try await client.serverSecurity.dropLogin(name: "lab_departed_owner")
            try await restore(client, backup: orphanBackup, as: "StateOrphanedOwner", mode: .recovery)
            try await admin.dropDatabase(name: "StateSource")
        }
        // A disabled index, then a snapshot of its database.
        try await SQLServerSession.with(server, database: "StateSnapshotSource") { client in
            try await client.indexes.createIndex(name: "IX_Notes_Body", table: "Notes", columns: [IndexColumn(name: "Body")])
            try await client.indexes.disableIndex(name: "IX_Notes_Body", table: "Notes")
        }
        try await SQLServerSession.with(server) { client in
            try await client.admin.createSnapshot(name: "StateSnapshot", sourceDatabase: "StateSnapshotSource")
        }
        context.log("  \(Self.expected.count) databases in different states")
    }

    private func restore(_ client: SQLServerClient, backup: String, as database: String,
                         mode: SQLServerRestoreRecoveryMode, standbyFile: String? = nil) async throws {
        let relocations = try await client.backupRestore.listBackupFiles(diskPath: backup).map { file in
            SQLServerRestoreOptions.FileRelocation(
                logicalName: file.logicalName,
                physicalPath: "\(Self.dataDirectory)/\(database)_\(file.logicalName)\(file.type.uppercased() == "L" ? ".ldf" : ".mdf")"
            )
        }
        try await client.backupRestore.restore(options: SQLServerRestoreOptions(
            database: database, diskPath: backup, recoveryMode: mode, relocateFiles: relocations, standbyFile: standbyFile
        ))
    }

    func verify(on server: ServerEndpoint, recipe: Recipe, parameters: PackParameters) async throws {
        var problems = try await SQLServerSession.with(server) { client in
            var problems: [String] = []
            for expected in Self.expected {
                let properties = try await client.admin.getDatabaseProperties(name: expected.database)
                let found = (properties.stateDescription, properties.userAccessDescription, properties.isReadOnly)
                if found != (expected.state, expected.access, expected.readOnly) {
                    problems.append("\(expected.database) is \(found)")
                }
            }
            return problems
        }
        let dbo = try await SQLServerSession.with(server, database: "StateOrphanedOwner") { client in
            try await client.security.listUsers().first { $0.name == "dbo" }
        }
        let disabled = try await SQLServerSession.with(server, database: "StateSnapshotSource") { client in
            try await client.indexes.getIndexInfo(name: "IX_Notes_Body", table: "Notes")?.isDisabled
        }
        if disabled != true { problems.append("IX_Notes_Body is not disabled") }
        if dbo == nil || dbo?.loginName != nil { problems.append("StateOrphanedOwner dbo maps to \(dbo?.loginName ?? "nothing listed")") }
        guard problems.isEmpty else { throw ServerLabError.packCheckFailed(pack: name, reason: problems.joined(separator: "; ")) }
    }
}
