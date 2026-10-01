import Foundation
import PostgresKit
import ServerLabKit

/// Every third-party extension of the `extensions` image created in `database` (pg_cron,
/// pgaudit, TimescaleDB, pg_partman, PostGIS and pgRouting, AGE, h3, rum, …) and pgAgent in
/// `postgres`. Parameter: `database` (default labdata, which pg_cron is configured for).
struct PostgresThirdPartyExtensionsPack: ContentPack {
    let name = "third-party-extensions"
    let version = 1
    let summary = "pg_cron, pgaudit, TimescaleDB, pg_partman, PostGIS, pgRouting, AGE and 20 more extensions (extensions image)."

    func apply(to server: ServerEndpoint, recipe: Recipe, parameters: PackParameters, context: PackContext) async throws {
        guard recipe.settings.imageVariant == PostgresEngine.extensionsVariant else {
            throw ServerLabError.packRequirement(pack: name, reason: "needs imageVariant \"\(PostgresEngine.extensionsVariant)\"")
        }
        let database = try parameters.string("database", default: PostgresDatabasePack.defaultName)
        try await PostgresSession.with(server) { client in
            _ = try await client.admin.createDatabase(name: database, ifNotExists: true)
            _ = try await client.maintenance.createExtension("pgagent", cascade: true)
        }
        try await PostgresSession.with(server, database: database) { client in
            for extensionName in PostgresEngine.thirdPartyExtensions {
                _ = try await client.maintenance.createExtension(extensionName, cascade: true)
            }
        }
        context.log("  \(PostgresEngine.thirdPartyExtensions.count) extensions in \(database), pgagent in postgres")
    }

    func verify(on server: ServerEndpoint, recipe: Recipe, parameters: PackParameters) async throws {
        let database = try parameters.string("database", default: PostgresDatabasePack.defaultName)
        let installed = try await PostgresSession.with(server, database: database) { client in
            Set(try await client.metadata.listExtensions().map(\.name))
        }
        let missing = PostgresEngine.thirdPartyExtensions.filter { !installed.contains($0) }
        guard missing.isEmpty else { throw ServerLabError.packCheckFailed(pack: name, reason: "missing \(missing)") }
    }
}
