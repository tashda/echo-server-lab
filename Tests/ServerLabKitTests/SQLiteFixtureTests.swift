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
        let result = try await connection.query(sql)
        try await connection.close()
        return result
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
}
