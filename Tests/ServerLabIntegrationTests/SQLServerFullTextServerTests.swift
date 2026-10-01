import ServerLabKit
import ServerLabTesting
import SQLServerKit
import Testing

/// The fulltext image variant: full-text search is installed and the seeded catalogs and indexes
/// survive the image.
@Suite(.enabled(if: integrationEnabled), .server("mssql-2022-full-text"))
struct SQLServerFullTextServerTests {
    @Test func catalogsAndIndexesAreThere() async throws {
        let server = try #require(LabServer.current)
        let client = try await SQLServerClient.connect(
            hostname: server.host, port: server.port, database: "FullTextLab",
            authentication: .sqlPassword(username: server.username, password: server.password),
            tlsEnabled: true, trustServerCertificate: true, encryptionMode: .optional
        )
        defer { Task { try? await client.shutdownGracefully() } }
        let catalogs = try await client.fullText.listCatalogs()
        #expect(catalogs.first { $0.name == "LabCatalog" }?.isDefault == true)
        #expect(catalogs.first { $0.name == "LabAccentInsensitive" }?.isAccentSensitive == false)
        #expect(Set(try await client.fullText.listIndexes().map(\.tableName)) == ["Articles", "Notes"])
    }
}
