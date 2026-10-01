import Foundation
import ServerLabKit
import SQLServerKit

/// Sets the database compatibility level of master and model (so databases made later get it
/// too), to test how a newer server behaves for an older version's databases (100 = 2008,
/// 110 = 2012, 120 = 2014, 130 = 2016, …). Parameter: `level`.
struct SQLServerCompatibilityLevelPack: ContentPack {
    let name = "compatibility-level"
    let version = 1
    let summary = "master and model at an older database compatibility level."

    static let databases = ["master", "model"]

    func apply(to server: ServerEndpoint, recipe: Recipe, parameters: PackParameters, context: PackContext) async throws {
        let level = try parameters.int("level", default: 100)
        try await SQLServerSession.with(server) { client in
            for database in Self.databases {
                _ = try await client.admin.alterDatabaseOption(name: database, option: .compatibilityLevel(level))
            }
        }
        context.log("  master and model at compatibility level \(level)")
    }

    func verify(on server: ServerEndpoint, recipe: Recipe, parameters: PackParameters) async throws {
        let level = try parameters.int("level", default: 100)
        for database in Self.databases {
            let health = try await SQLServerSession.with(server) { try await $0.maintenance.getDatabaseHealth(database: database) }
            guard health.compatibilityLevel == level else {
                throw ServerLabError.packCheckFailed(pack: name, reason: "\(database) is at \(health.compatibilityLevel), not \(level)")
            }
        }
    }
}
