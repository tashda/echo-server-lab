import ServerLabKit
import ServerLabTesting
import SQLServerKit
import Testing

/// TDE and the keys survive the seeded image: the database comes back encrypted.
@Suite(.enabled(if: integrationEnabled), .server("mssql-2022-encryption"))
struct SQLServerEncryptionServerTests {
    @Test func databaseIsEncryptedAndKeysAreThere() async throws {
        let server = try #require(LabServer.current)
        let client = try await sqlServer(server, trust: true, mode: .optional)
        defer { Task { try? await client.shutdownGracefully() } }
        let tde = try await client.security.listDatabaseEncryption().first { $0.database == "EncryptedLab" }
        #expect(tde?.state == "ENCRYPTED")
        #expect(tde?.certificate == "LabTDECertificate")

        let inDatabase = try await SQLServerClient.connect(
            hostname: server.host, port: server.port, database: "EncryptedLab",
            authentication: .sqlPassword(username: server.username, password: server.password),
            tlsEnabled: true, trustServerCertificate: true, encryptionMode: .optional
        )
        defer { Task { try? await inDatabase.shutdownGracefully() } }
        #expect(try await inDatabase.security.listSymmetricKeys().map(\.name).contains("PayrollKey"))
        #expect(Set(try await inDatabase.security.listCertificates().map(\.name)).isSuperset(of: ["PayrollCertificate", "ExpiredCertificate"]))
    }
}
