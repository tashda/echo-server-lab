import Foundation
import ServerLabKit
import SQLServerKit

/// Creates a user database. Parameters: `name` (default `LabData`), `collation` (server default).
struct SQLServerDatabasePack: ContentPack {
    let name = "database"
    let version = 1
    let summary = "A user database, optionally with its own collation."

    func apply(to server: ServerEndpoint, recipe: Recipe, parameters: PackParameters, context: PackContext) async throws {
        let database = try parameters.string("name", default: SQLServerDatabasePack.defaultName)
        let collation = try parameters.optionalString("collation")
        try await SQLServerSession.with(server) { client in
            let existing = try await client.metadata.listDatabases().map(\.name)
            guard !existing.contains(database) else { return }
            try await client.admin.createDatabase(name: database, options: .init(collation: collation))
        }
    }

    func verify(on server: ServerEndpoint, recipe: Recipe, parameters: PackParameters) async throws {
        let database = try parameters.string("name", default: SQLServerDatabasePack.defaultName)
        let names = try await SQLServerSession.with(server) { client in
            try await client.metadata.listDatabases().map(\.name)
        }
        guard names.contains(database) else {
            throw ServerLabError.packCheckFailed(pack: name, reason: "database \(database) is missing")
        }
    }

    static let defaultName = "LabData"
}
