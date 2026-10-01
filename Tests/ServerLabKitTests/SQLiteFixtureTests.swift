import Foundation
import ServerLabCatalog
import SQLiteNIO
import Testing

/// Builds the local fixtures (no lab host needed) and checks what they hold.
@Suite(.serialized) struct SQLiteFixtureTests {
    func rows(_ fixture: LabSQLiteFixture, _ sql: String) async throws -> [SQLiteRow] {
        let file = try await LabSQLite.freshCopy(fixture)
        defer { try? FileManager.default.removeItem(at: file) }
        let connection = try await SQLiteConnection.open(storage: .file(path: file.path))
        do {
            let result = try await connection.query(sql)
            try await connection.close()
            return result
        } catch {
            try? await connection.close()
            throw error
        }
    }

    @Test func allTypesHoldsExtremesAndAStrictTable() async throws {
        let counts = try await rows(.allTypes, "SELECT (SELECT COUNT(*) FROM all_types) AS rows, (SELECT COUNT(*) FROM strict_types) AS strict_rows, (SELECT MIN(integer_col) FROM all_types) AS smallest")
        #expect(counts.first?.column("rows")?.integer == 203)
        #expect(counts.first?.column("strict_rows")?.integer == 50)
        #expect(counts.first?.column("smallest")?.integer == Int.min)
    }

    @Test func programmabilityHoldsEveryKindOfObject() async throws {
        let objects = try await rows(.programmability, "SELECT type, COUNT(*) AS count FROM sqlite_schema GROUP BY type ORDER BY type")
        let byType = Dictionary(uniqueKeysWithValues: objects.compactMap { row in row.column("type")?.string.map { ($0, row.column("count")?.integer ?? 0) } })
        #expect((byType["trigger"] ?? 0) == 2)
        #expect((byType["view"] ?? 0) == 1)
        #expect((byType["index"] ?? 0) >= 5)
        let audit = try await rows(.programmability, "SELECT COUNT(*) AS count FROM audit_log")
        #expect(audit.first?.column("count")?.integer == 100)
    }

    @Test func walModeIsInTheHeader() async throws {
        #expect(try await rows(.wal, "PRAGMA journal_mode").first?.column("journal_mode")?.string == "wal")
    }

    @Test func edgeNamesAreReadable() async throws {
        let tables = try await rows(.edgeNames, "SELECT name FROM sqlite_schema WHERE type = 'table' ORDER BY name").compactMap { $0.column("name")?.string }
        #expect(tables.contains("Order Details") && tables.contains("Café ☕️ 数据") && tables.contains(#"it's "quoted""#))
        #expect(try await rows(.edgeNames, #"SELECT "émoji 🎉" AS value FROM "Café ☕️ 数据""#).first?.column("value")?.string == "🎉🎉")
    }

    @Test func wideTableHasTwoThousandColumns() async throws {
        #expect(try await rows(.wide, "SELECT COUNT(*) AS count FROM pragma_table_info('wide_table')").first?.column("count")?.integer == 2000)
    }

    @Test func largeTableHasAMillionRows() async throws {
        #expect(try await rows(.large, "SELECT COUNT(*) AS count FROM readings").first?.column("count")?.integer == 1_000_000)
    }

    @Test func emptyFileIsAnEmptyDatabase() async throws {
        #expect(try await rows(.empty, "SELECT COUNT(*) AS count FROM sqlite_schema").first?.column("count")?.integer == 0)
    }

    @Test func textFileIsNotADatabase() async throws {
        await #expect(throws: (any Error).self) { _ = try await rows(.notADatabase, "SELECT COUNT(*) FROM sqlite_schema") }
    }

    @Test func damagedFileFailsTheIntegrityCheck() async throws {
        let result = try? await rows(.corrupt, "PRAGMA integrity_check")
        #expect(result?.first?.column("integrity_check")?.string != "ok")
    }
}

