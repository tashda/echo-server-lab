import Foundation
import MySQLKit
import MySQLWire
import ServerLabKit
import ServerLabTesting
import Testing

/// Logs in through mysql-wire as `account` and reads the current user back.
func mysqlLogin(_ server: LabServer, account: String, _ mode: MySQLWireTLSMode) async -> Result<String, any Error> {
    let client = MySQLClient(configuration: MySQLConfiguration(host: server.host, port: server.port, username: account,
                                                               password: server.password, tlsMode: mode))
    defer { Task { await client.close() } }
    do {
        // Any account may list the databases it can see (information_schema at least).
        return .success(try await client.metadata.listDatabases().joined(separator: ", "))
    } catch {
        return .failure(error)
    }
}

/// What mysql-wire can and cannot log in with, per plugin and TLS. Each known gap is in
/// catalog/driver-gaps.md; when the driver closes one, its `withKnownIssue` fails and is removed.
func expectLogins(_ server: LabServer, works: [(String, MySQLWireTLSMode)], gaps: [(String, MySQLWireTLSMode, String)]) async {
    for (account, mode) in works {
        let result = await mysqlLogin(server, account: account, mode)
        #expect(throws: Never.self, "\(account) over \(mode)") { _ = try result.get() }
    }
    for (account, mode, gap) in gaps {
        await withKnownIssue("\(gap): \(account) over \(mode)") {
            _ = try await mysqlLogin(server, account: account, mode).get()
        }
    }
}

@Suite(.enabled(if: integrationEnabled), .server("mysql-8.4-auth-plugins"))
struct MySQLAuthenticationServerTests {
    @Test func everyPluginLogsIn() async throws {
        let server = try #require(LabServer.current)
        await expectLogins(server, works: [
            ("lab_auth_caching_sha2", .required), ("lab_auth_mysql_native", .required), ("lab_auth_mysql_native", .disabled),
        ], gaps: [
            ("lab_auth_caching_sha2", .disabled, "caching_sha2_password without TLS"),
            ("lab_auth_sha256", .required, "sha256_password"),
            ("lab_auth_sha256", .disabled, "sha256_password"),
        ])
    }
}

@Suite(.enabled(if: integrationEnabled), .server("mariadb-11.8-auth-plugins"))
struct MariaDBAuthenticationServerTests {
    @Test func everyPluginLogsIn() async throws {
        let server = try #require(LabServer.current)
        await expectLogins(server, works: [
            ("lab_auth_mysql_native", .required), ("lab_auth_mysql_native", .disabled),
        ], gaps: [
            ("lab_auth_ed25519", .required, "client_ed25519"),
            ("lab_auth_parsec", .required, "parsec"),
        ])
    }
}

/// `client-certificate`: root logs in only with the lab-signed certificate.
func expectClientCertificateLogin(_ server: LabServer) async throws {
    let tls = try #require(server.tls)
    let withCertificate = MySQLClient(configuration: MySQLConfiguration(
        host: server.host, port: server.port, username: server.username, password: server.password,
        tlsMode: .verifyCA(caCertificatePath: tls.caPath),
        clientCertificatePath: tls.clientCertificatePath, clientKeyPath: tls.clientKeyPath))
    #expect(try await withCertificate.metadata.listDatabases().contains("labdata"))
    await withCertificate.close()
    let withoutCertificate = mysqlClient(server, .verifyCA(caCertificatePath: tls.caPath))
    await #expect(throws: (any Error).self) { _ = try await withoutCertificate.metadata.listDatabases() }
    await withoutCertificate.close()
}

@Suite(.enabled(if: integrationEnabled), .server("mysql-8.4-tls-client-certificate"))
struct MySQLClientCertificateTests {
    @Test func onlyACertificateLogsIn() async throws { try await expectClientCertificateLogin(try #require(LabServer.current)) }
}

@Suite(.enabled(if: integrationEnabled), .server("mariadb-11.4-tls-client-certificate"))
struct MariaDBClientCertificateTests {
    @Test func onlyACertificateLogsIn() async throws { try await expectClientCertificateLogin(try #require(LabServer.current)) }
}
