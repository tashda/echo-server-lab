import ServerLabKit
import ServerLabTesting
import SQLServerKit
import Testing

/// A UTF-8, case-sensitive server: LabData inherits the collation, and the legacy text/ntext
/// columns exist with a collation they accept.
@Suite(.enabled(if: integrationEnabled), .server("mssql-2022-case-sensitive"))
struct SQLServerCaseSensitiveServerTests {
    @Test func databaseIsUTF8AndCaseSensitive() async throws {
        let client = try await sqlServer(try #require(LabServer.current), trust: true, mode: .optional)
        defer { Task { try? await client.shutdownGracefully() } }
        let properties = try await client.admin.getDatabaseProperties(name: "LabData")
        #expect(properties.collationName == "Latin1_General_100_CS_AS_SC_UTF8")
        let rows = try await client.metadata.tableProperties(database: "LabData", schema: "dbo", table: "AllTypes").rowCount
        #expect(rows > 0)
    }
}
