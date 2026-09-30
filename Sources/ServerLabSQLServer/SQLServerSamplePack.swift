import Foundation
import ServerLabKit
import SQLServerKit

/// A well-known sample database: AdventureWorks (OLTP, LT, DW) and WideWorldImporters through the
/// driver's typed restore, Northwind and pubs through its script runner.
///
/// Parameter: `sample` = AdventureWorks | AdventureWorksLT | AdventureWorksDW | WideWorldImporters |
/// Northwind | pubs. Use the pack several times in a recipe for several samples.
struct SQLServerSamplePack: ContentPack {
    let name = "sample"
    let version = 1
    let summary = "AdventureWorks (OLTP/LT/DW), WideWorldImporters, Northwind or pubs, loaded through the driver."

    struct Sample {
        enum Load { case backup, scriptInNewDatabase, scriptCreatingItsDatabase }
        var file: String
        var database: String
        var load: Load
        /// A table the check counts rows in, and how many it must have.
        var checkTable: (schema: String, name: String, minimumRows: Int64)
    }

    static let samples: [String: Sample] = [
        "AdventureWorks": Sample(file: "AdventureWorks2017.bak", database: "AdventureWorks", load: .backup,
                                 checkTable: ("Sales", "SalesOrderHeader", 31_000)),
        "AdventureWorksLT": Sample(file: "AdventureWorksLT2017.bak", database: "AdventureWorksLT", load: .backup,
                                   checkTable: ("SalesLT", "Product", 290)),
        "AdventureWorksDW": Sample(file: "AdventureWorksDW2017.bak", database: "AdventureWorksDW", load: .backup,
                                   checkTable: ("dbo", "FactInternetSales", 60_000)),
        "WideWorldImporters": Sample(file: "WideWorldImporters-Full.bak", database: "WideWorldImporters", load: .backup,
                                     checkTable: ("Sales", "Orders", 70_000)),
        "Northwind": Sample(file: "instnwnd.sql", database: "Northwind", load: .scriptInNewDatabase,
                            checkTable: ("dbo", "Orders", 830)),
        "pubs": Sample(file: "instpubs.sql", database: "pubs", load: .scriptCreatingItsDatabase,
                       checkTable: ("dbo", "titles", 18)),
    ]

    func sample(_ parameters: PackParameters) throws -> Sample {
        let key = try parameters.string("sample", default: "")
        guard let sample = Self.samples[key] else {
            throw ServerLabError.invalidParameter("sample", expected: "one of \(Self.samples.keys.sorted().joined(separator: ", "))")
        }
        return sample
    }

    func requiredSamples(parameters: PackParameters) throws -> [String] {
        [try sample(parameters).file]
    }

    func apply(to server: ServerEndpoint, recipe: Recipe, parameters: PackParameters, context: PackContext) async throws {
        let sample = try sample(parameters)
        switch sample.load {
        case .backup:
            let path = "\(LabSamples.containerDirectory)/\(sample.file)"
            try await SQLServerSession.with(server) { client in
                let files = try await client.backupRestore.listBackupFiles(diskPath: path)
                var dataFiles = 0
                let relocations = files.map { file -> SQLServerRestoreOptions.FileRelocation in
                    let suffix: String
                    switch file.type.uppercased() {
                    case "L": suffix = ".ldf"
                    case "S": suffix = ""  // FILESTREAM or memory-optimized container: a directory.
                    default:
                        dataFiles += 1
                        suffix = dataFiles == 1 ? ".mdf" : ".ndf"
                    }
                    return .init(logicalName: file.logicalName, physicalPath: "/var/opt/mssql/data/\(sample.database)_\(file.logicalName)\(suffix)")
                }
                _ = try await client.backupRestore.restore(options: SQLServerRestoreOptions(
                    database: sample.database, diskPath: path, replace: true, relocateFiles: relocations
                ))
            }
        case .scriptInNewDatabase:
            let script = try await context.sampleText(sample.file)
            try await SQLServerSession.with(server) { client in
                try await client.admin.createDatabase(name: sample.database)
                try await client.scripts.run(script, database: sample.database)
            }
        case .scriptCreatingItsDatabase:
            let script = try await context.sampleText(sample.file)
            try await SQLServerSession.with(server) { client in
                _ = try await client.scripts.run(script)
            }
        }
        context.log("  \(sample.database) from \(sample.file)")
    }

    func verify(on server: ServerEndpoint, recipe: Recipe, parameters: PackParameters) async throws {
        let sample = try sample(parameters)
        let rows = try await SQLServerSession.with(server, database: sample.database) { client in
            try await client.metadata.tableProperties(database: sample.database, schema: sample.checkTable.schema, table: sample.checkTable.name).rowCount
        }
        guard rows >= sample.checkTable.minimumRows else {
            throw ServerLabError.packCheckFailed(pack: name, reason: "\(sample.database) \(sample.checkTable.schema).\(sample.checkTable.name) has \(rows) rows")
        }
    }
}
