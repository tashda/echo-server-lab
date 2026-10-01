import Foundation
import MySQLKit
import ServerLabKit

/// A well-known sample database loaded through mysql-wire's script runner: Sakila (MySQL's DVD
/// rental, with views, procedures, functions and triggers), world, or Chinook.
///
/// Parameter: `sample` = sakila | world | chinook. Use the pack several times for several samples.
struct MySQLSamplePack: ContentPack {
    let name = "sample"
    let version = 1
    let summary = "Sakila, world or Chinook, loaded through the driver's script runner."

    struct Sample {
        var files: [String]
        var database: String
        var checkTable: (name: String, minimumRows: Int)
    }

    static let samples: [String: Sample] = [
        "sakila": Sample(files: ["sakila-schema.sql", "sakila-data.sql"], database: "sakila", checkTable: ("rental", 16_000)),
        "world": Sample(files: ["world.sql"], database: "world", checkTable: ("city", 4_000)),
        "chinook": Sample(files: ["Chinook_MySql.sql"], database: "Chinook", checkTable: ("Track", 3_500)),
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
        for file in sample.files {
            let script = try await context.sampleText(file)
            let count = try await MySQLSession.with(server) { try await $0.scripts.run(script) }
            context.log("  \(file): \(count) statements")
        }
    }

    func verify(on server: ServerEndpoint, recipe: Recipe, parameters: PackParameters) async throws {
        let sample = try sample(parameters)
        let rows = try await MySQLSession.with(server) {
            try await $0.metadata.exactRowCount(schema: sample.database, table: sample.checkTable.name)
        }
        guard rows >= sample.checkTable.minimumRows else {
            throw ServerLabError.packCheckFailed(pack: name, reason: "\(sample.database).\(sample.checkTable.name) has \(rows) rows")
        }
    }
}
