import Foundation
import PostgresKit
import ServerLabKit

/// Every third-party extension of the `extensions` image created in `database` (pg_cron,
/// pgaudit, TimescaleDB, pg_partman, PostGIS and pgRouting, AGE, h3, rum, …) and pgAgent in
/// `postgres`, pg_cron jobs (nightly, every minute, one paused, one in another database) and
/// pgAgent jobs (two steps with schedules, one disabled). Parameter: `database` (default labdata, which pg_cron is configured for).
struct PostgresThirdPartyExtensionsPack: ContentPack {
    let name = "third-party-extensions"
    let version = 3
    let summary = "pg_cron, pgaudit, TimescaleDB, pg_partman, PostGIS, pgRouting, AGE and 20 more extensions (extensions image)."

    func apply(to server: ServerEndpoint, recipe: Recipe, parameters: PackParameters, context: PackContext) async throws {
        guard recipe.settings.imageVariant == PostgresEngine.extensionsVariant else {
            throw ServerLabError.packRequirement(pack: name, reason: "needs imageVariant \"\(PostgresEngine.extensionsVariant)\"")
        }
        let database = try parameters.string("database", default: PostgresDatabasePack.defaultName)
        try await PostgresSession.with(server) { client in
            _ = try await client.admin.createDatabase(name: database, ifNotExists: true)
            _ = try await client.maintenance.createExtension("pgagent", cascade: true)
            try await client.pgAgent.createJob(PgAgentJobDefinition(
                name: "Nightly maintenance", description: "Vacuum, then report",
                steps: [.init(name: "vacuum", code: "VACUUM ANALYZE", database: database),
                        .init(name: "report", kind: .batch, code: "echo maintenance done", onError: .ignore)],
                schedules: [.init(name: "nightly", minutes: [30], hours: [2]),
                            .init(name: "sunday morning", minutes: [0], hours: [6], weekdays: [0])]))
            try await client.pgAgent.createJob(PgAgentJobDefinition(
                name: "Monthly report", jobClass: "Data Summarisation", isEnabled: false,
                steps: [.init(name: "summarise", code: "SELECT 1", database: database)],
                schedules: [.init(name: "first of the month", minutes: [0], hours: [7], monthDays: [1])]))
        }
        try await PostgresSession.with(server, database: database) { client in
            for extensionName in PostgresEngine.thirdPartyExtensions {
                _ = try await client.maintenance.createExtension(extensionName, cascade: true)
            }
            let cron = client.cron
            try await cron.schedule(name: "nightly_vacuum", schedule: "0 3 * * *", command: "VACUUM ANALYZE")
            try await cron.schedule(name: "minute_heartbeat", schedule: "* * * * *", command: "SELECT now()")
            try await cron.schedule(name: "postgres_cleanup", schedule: "30 4 * * 0", command: "SELECT 1", database: "postgres")
            let paused = try await cron.schedule(name: "paused_report", schedule: "0 9 1 * *", command: "SELECT 1")
            try await cron.setActive(jobID: paused, active: false)
        }
        context.log("  \(PostgresEngine.thirdPartyExtensions.count) extensions in \(database), pgagent in postgres")
    }

    func verify(on server: ServerEndpoint, recipe: Recipe, parameters: PackParameters) async throws {
        let database = try parameters.string("database", default: PostgresDatabasePack.defaultName)
        let (installed, jobs) = try await PostgresSession.with(server, database: database) { client in
            (Set(try await client.metadata.listExtensions().map(\.name)), try await client.cron.listJobs())
        }
        let agentJobs = try await PostgresSession.with(server) { try await $0.pgAgent.listJobs() }
        guard agentJobs.map(\.name) == ["Nightly maintenance", "Monthly report"], agentJobs.map(\.isEnabled) == [true, false] else {
            throw ServerLabError.packCheckFailed(pack: name, reason: "pgAgent jobs \(agentJobs.map(\.name))")
        }
        let missing = PostgresEngine.thirdPartyExtensions.filter { !installed.contains($0) }
        guard missing.isEmpty else { throw ServerLabError.packCheckFailed(pack: name, reason: "missing \(missing)") }
        guard jobs.count == 4, jobs.filter({ !$0.isActive }).map(\.name) == ["paused_report"] else {
            throw ServerLabError.packCheckFailed(pack: name, reason: "cron jobs \(jobs.map { "\($0.name ?? "?") \($0.isActive)" })")
        }
    }
}
