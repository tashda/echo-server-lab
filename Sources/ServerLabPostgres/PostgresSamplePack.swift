import Foundation
import PostgresKit
import ServerLabKit

/// A well-known sample database loaded through the driver's script runner: pagila (plain pg_dump
/// with COPY data) or Chinook. Parameter: `sample` = pagila | chinook.
struct PostgresSamplePack: ContentPack {
    let name = "sample"
    let version = 1
    let summary = "pagila or Chinook, loaded through the driver's script runner."

    struct Sample {
        var files: [String]
        var database: String
        var checkTable: (schema: String, name: String, rows: Int64)
        /// First PostgreSQL version the files load on (pagila's current schema calls uuidv7(), new in 18).
        var minimumVersion = 13
    }

    static let samples: [String: Sample] = [
        "pagila": Sample(files: ["pagila-schema.sql", "pagila-data.sql"], database: "pagila", checkTable: ("public", "film", 1_000), minimumVersion: 18),
        "chinook": Sample(files: ["Chinook_PostgreSql.sql"], database: "chinook", checkTable: ("public", "track", 3_503)),
    ]

    func sample(_ parameters: PackParameters) throws -> Sample {
        let key = try parameters.string("sample", default: "")
        guard let sample = Self.samples[key] else {
            throw ServerLabError.invalidParameter("sample", expected: "one of \(Self.samples.keys.sorted().joined(separator: ", "))")
        }
        return sample
    }

    func requiredSamples(parameters: PackParameters) throws -> [String] {
        try sample(parameters).files
    }

    func apply(to server: ServerEndpoint, recipe: Recipe, parameters: PackParameters, context: PackContext) async throws {
        let sample = try sample(parameters)
        guard (Int(recipe.version) ?? 0) >= sample.minimumVersion else {
            throw ServerLabError.packRequirement(pack: name, reason: "\(sample.database) needs PostgreSQL \(sample.minimumVersion) or later")
        }
        var scripts: [String] = []
        for file in sample.files { scripts.append(try await context.sampleText(file)) }

        if sample.database == "chinook", let script = scripts.first {
            // The script creates its database, then switches with "\c chinook;" (a psql
            // meta-command): run the rest in that database.
            let lines = script.components(separatedBy: "\n")
            let switchLine = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("\\c ") } ?? 0
            try await PostgresSession.with(server) { client in
                _ = try await client.scripts.run(lines[..<switchLine].joined(separator: "\n"))
            }
            try await PostgresSession.with(server, database: sample.database) { client in
                _ = try await client.scripts.run(lines[(switchLine + 1)...].joined(separator: "\n"))
            }
        } else {
            try await PostgresSession.with(server) { client in
                _ = try await client.admin.createDatabase(name: sample.database)
            }
            try await PostgresSession.with(server, database: sample.database) { client in
                for script in scripts { try await client.scripts.run(script) }
            }
        }
        context.log("  \(sample.database) from \(sample.files.joined(separator: ", "))")
    }

    func verify(on server: ServerEndpoint, recipe: Recipe, parameters: PackParameters) async throws {
        let sample = try sample(parameters)
        let rows = try await PostgresSession.with(server, database: sample.database) { client in
            try await client.metadata.exactRowCount(schema: sample.checkTable.schema, table: sample.checkTable.name)
        }
        guard rows == sample.checkTable.rows else {
            throw ServerLabError.packCheckFailed(pack: name, reason: "\(sample.database).\(sample.checkTable.name) has \(rows) rows, expected \(sample.checkTable.rows)")
        }
    }
}
