import Foundation
import ServerLabCatalog
@testable import ServerLabKit
import Testing

@Suite struct ContainerSpecTests {
    private func engine(_ kind: EngineKind) throws -> any LabEngine {
        try #require(ServerLab.standardEngines.first { $0.kind == kind })
    }

    @Test func sqlServerSettingsReachTheContainer() throws {
        let recipe = Recipe(name: "r", engine: .sqlServer, version: "2019",
                            settings: .init(agent: true, collation: "Latin1_General_CS_AS", memoryMB: 4_096))
        let spec = try engine(.sqlServer).containerSpec(for: recipe, password: "pw")
        #expect(spec.image == "mcr.microsoft.com/mssql/server:2019-latest")
        #expect(spec.internalPort == 1433)
        #expect(spec.memoryMB == 4_096)
        #expect(spec.environment["MSSQL_AGENT_ENABLED"] == "true")
        #expect(spec.environment["MSSQL_COLLATION"] == "Latin1_General_CS_AS")
        #expect(spec.environment["MSSQL_MEMORY_LIMIT_MB"] == "3584")
        #expect(spec.environment["MSSQL_SA_PASSWORD"] == "pw")
    }

    @Test func sqlServerAgentIsOffUnlessAsked() throws {
        let spec = try engine(.sqlServer).containerSpec(for: Recipe(name: "r", engine: .sqlServer, version: "2022"), password: "pw")
        #expect(spec.environment["MSSQL_AGENT_ENABLED"] == "false")
        #expect(spec.environment["MSSQL_COLLATION"] == nil)
    }

    /// Data inside a declared image volume is lost on `docker commit`.
    @Test(arguments: ["13", "17", "18"])
    func postgresDataLivesOutsideTheImageVolumes(version: String) throws {
        let spec = try engine(.postgres).containerSpec(for: Recipe(name: "r", engine: .postgres, version: version), password: "pw")
        let dataDirectory = try #require(spec.environment["PGDATA"])
        #expect(!dataDirectory.hasPrefix("/var/lib/postgresql"))
        #expect(spec.image == "postgres:\(version)")
    }

    @Test func serverOptionsGoOnTheCommandLine() throws {
        let options = ["sql_mode": "ANSI_QUOTES", "general_log": "ON"]
        let mysql = try engine(.mysql).containerSpec(
            for: Recipe(name: "r", engine: .mysql, version: "8.4", settings: .init(serverOptions: options)), password: "pw")
        #expect(mysql.command.suffix(2) == ["--general_log=ON", "--sql_mode=ANSI_QUOTES"])
        let postgres = try engine(.postgres).containerSpec(
            for: Recipe(name: "r", engine: .postgres, version: "17", settings: .init(serverOptions: ["log_statement": "all"])), password: "pw")
        #expect(postgres.command.suffix(2) == ["-c", "log_statement=all"])
        #expect(throws: ServerLabError.self) {
            try engine(.sqlServer).containerSpec(
                for: Recipe(name: "r", engine: .sqlServer, version: "2022", settings: .init(serverOptions: ["x": "y"])), password: "pw")
        }
    }

    @Test func unsupportedVersionIsRejected() throws {
        #expect(throws: ServerLabError.self) {
            try engine(.postgres).containerSpec(for: Recipe(name: "r", engine: .postgres, version: "9.6"), password: "pw")
        }
    }
}

@Suite struct FingerprintTests {
    private let recipe = Recipe(name: "r", engine: .sqlServer, version: "2022", packs: [PackUse("database")])

    @Test func sameInputsGiveTheSameFingerprint() throws {
        let first = try RecipeFingerprint.compute(recipe: recipe, packVersions: ["database": 1], baseImageID: "sha256:a", password: "pw")
        let second = try RecipeFingerprint.compute(recipe: recipe, packVersions: ["database": 1], baseImageID: "sha256:a", password: "pw")
        #expect(first == second)
        #expect(RecipeFingerprint.imageTag(recipe: "r", fingerprint: first) == "serverlab/r:\(first.prefix(12))")
    }

    @Test func anyChangeGivesANewFingerprint() throws {
        let base = try RecipeFingerprint.compute(recipe: recipe, packVersions: ["database": 1], baseImageID: "sha256:a", password: "pw")
        var changedRecipe = recipe
        changedRecipe.packs.append(PackUse("column-types", params: .init(["rows": 5])))
        let variants = [
            try RecipeFingerprint.compute(recipe: changedRecipe, packVersions: ["database": 1], baseImageID: "sha256:a", password: "pw"),
            try RecipeFingerprint.compute(recipe: recipe, packVersions: ["database": 2], baseImageID: "sha256:a", password: "pw"),
            try RecipeFingerprint.compute(recipe: recipe, packVersions: ["database": 1], baseImageID: "sha256:b", password: "pw"),
            try RecipeFingerprint.compute(recipe: recipe, packVersions: ["database": 1], baseImageID: "sha256:a", password: "other"),
        ]
        #expect(!variants.contains(base))
        #expect(Set(variants).count == variants.count)
    }
}

@Suite struct LabServerEnvironmentTests {
    private func server(_ engine: EngineKind) -> LabServer {
        LabServer(recipe: "r", engine: engine, version: "1", host: "10.0.0.1", port: 32768, username: "u", password: "p",
                  containerID: "id", containerName: "serverlab-r-1", expires: Date())
    }

    @Test func sqlServerExportsDriverTestVariables() {
        let variables = server(.sqlServer).environment
        #expect(variables["TDS_HOSTNAME"] == "10.0.0.1")
        #expect(variables["TDS_PORT"] == "32768")
        #expect(variables["SERVERLAB_CONTAINER"] == "serverlab-r-1")
        #expect(variables["POSTGRES_HOST"] == nil)
    }

    @Test func postgresExportsDriverTestVariables() {
        let variables = server(.postgres).environment
        #expect(variables["POSTGRES_HOST"] == "10.0.0.1")
        #expect(variables["POSTGRES_DATABASE"] == "postgres")
        #expect(variables["TDS_HOSTNAME"] == nil)
    }
}

@Suite struct DockerStatsParsingTests {
    @Test func memoryUsageUnits() {
        #expect(ServerLab.megabytes("1.5GiB") == 1536)
        #expect(ServerLab.megabytes("512MiB") == 512)
        #expect(ServerLab.megabytes("2048KiB") == 2)
        #expect(ServerLab.megabytes("garbage") == 0)
    }
}

@Suite struct ImageVariantTests {
    @Test func postgresVariantsUseTheirProjectsImages() throws {
        let engine = try #require(ServerLab.standardEngines.first { $0.kind == .postgres })
        func image(_ variant: String?) throws -> String {
            try engine.containerSpec(for: Recipe(name: "r", engine: .postgres, version: "18", settings: .init(imageVariant: variant)), password: "p").image
        }
        #expect(try image(nil) == "postgres:18")
        #expect(try image("pgvector") == "pgvector/pgvector:pg18")
        #expect(throws: ServerLabError.self) { try image("nope") }
    }
}
