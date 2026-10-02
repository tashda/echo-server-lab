import Foundation
import Testing
@testable import ServerLabKit

/// The drivers' test URL variables the lab fills in for every server.
@Suite struct TestURLTests {
    func server(_ engine: EngineKind, tls: EndpointTLS? = nil, parts: [String] = ["server"], password: String = "p@ss:w/rd") -> LabServer {
        LabServer(recipe: "r", engine: engine, version: "1", host: "192.0.2.10", port: 20001, username: "sa",
                  password: password, containerID: "id", containerName: "serverlab-r-1", expires: .distantFuture,
                  parts: parts.enumerated().map { index, role in
                      LabServerPart(role: role, containerID: "c\(index)", containerName: "n\(index)", port: 20001 + index,
                                    controlPort: role == "proxy" ? 30000 : nil)
                  },
                  tls: tls)
    }

    @Test func plainServersGetTheBaseVariable() throws {
        let variables = server(.postgres).testURLVariables
        let url = try #require(variables["POSTGRES_TEST_URL"])
        #expect(url == "postgres://sa:p%40ss%3Aw%2Frd@192.0.2.10:20001/postgres?sslmode=disable")
        #expect(URLComponents(string: url)?.password == "p@ss:w/rd")
        #expect(server(.mariadb).testURLVariables["MYSQL_TEST_URL"]?.hasPrefix("mysql://sa:") == true)
        #expect(server(.sqlServer).testURLVariables["SQLSERVER_TEST_URL"]?.contains("encrypt=mandatory&trustServerCertificate=true") == true)
    }

    @Test func tlsServersGetTheTLSVariableWithTheCA() throws {
        let tls = EndpointTLS(mode: .required, certificate: .valid, caPath: "/ca.pem")
        let variables = server(.postgres, tls: tls).testURLVariables
        #expect(variables["POSTGRES_TEST_URL"] == nil)
        #expect(variables["POSTGRES_TEST_TLS_URL"]?.contains("sslmode=verify-full&sslrootcert=/ca.pem") == true)
        #expect(server(.sqlServer, tls: EndpointTLS(mode: .strict, certificate: .valid, caPath: "/ca.pem")).testURLVariables["SQLSERVER_TEST_TLS_URL"]?
            .contains("encrypt=strict&trustServerCertificate=false&caFile=/ca.pem") == true)
    }

    @Test func partsGetTheirOwnVariables() {
        let pair = server(.postgres, parts: ["primary", "standby"]).testURLVariables
        #expect(pair["POSTGRES_TEST_STANDBY_URL"]?.contains(":20002/") == true)
        let group = server(.sqlServer, parts: ["primary", "secondary", "secondary2"]).testURLVariables
        #expect(group["SQLSERVER_TEST_AG_URLS"]?.split(separator: ",").count == 3)
        let proxied = server(.mysql, parts: ["server", "proxy"]).testURLVariables
        #expect(proxied["MYSQL_TEST_PROXY_URL"]?.contains(":20002/") == true)
        #expect(proxied["MYSQL_TEST_PROXY_CONTROL"] == "http://192.0.2.10:30000")
    }
}
