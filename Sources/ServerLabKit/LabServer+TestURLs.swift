import Foundation

/// The drivers' test-server convention: a driver's tests find a server through one URL variable
/// per setup, so they run the same against a local `docker run`, a CI service container or a lab
/// server. The lab fills them in for every server it starts (`serverlab up --env`, `serverlab run`).
///
/// | Variable | Setup |
/// |---|---|
/// | `SQLSERVER_TEST_URL`, `POSTGRES_TEST_URL`, `MYSQL_TEST_URL` | a plain server (MariaDB too) |
/// | `<ENGINE>_TEST_TLS_URL` | a server that requires TLS; the URL carries the mode and CA |
/// | `<ENGINE>_TEST_KERBEROS_URL` | Kerberos logins; `krb5Config` names the Kerberos settings |
/// | `POSTGRES_TEST_STANDBY_URL`, `MYSQL_TEST_REPLICA_URL` | the second server of a pair |
/// | `SQLSERVER_TEST_AG_URLS` | availability group replicas, primary first, comma-separated |
/// | `<ENGINE>_TEST_PROXY_URL`, `<ENGINE>_TEST_PROXY_CONTROL` | through a Toxiproxy fault proxy, and its API |
///
/// URL forms, with percent-encoded user and password:
/// `sqlserver://user:password@host:port/master?encrypt=mandatory&trustServerCertificate=true&caFile=…`,
/// `postgres://user:password@host:port/postgres?sslmode=require&sslrootcert=…&sslcert=…&sslkey=…` (libpq),
/// `mysql://user:password@host:port/?ssl-mode=REQUIRED&ssl-ca=…&ssl-cert=…&ssl-key=…` (mysql client).
extension LabServer {
    public var testURLVariables: [String: String] {
        let prefix = Self.testURLPrefix(engine)
        var variables: [String: String] = [:]
        let main = testURL(port: port)
        if kerberos != nil {
            variables["\(prefix)_TEST_KERBEROS_URL"] = main
        } else if tls != nil {
            variables["\(prefix)_TEST_TLS_URL"] = main
        } else {
            variables["\(prefix)_TEST_URL"] = main
        }
        for part in parts.dropFirst() {
            switch part.role {
            case "standby": variables["POSTGRES_TEST_STANDBY_URL"] = testURL(port: part.port)
            case "replica": variables["MYSQL_TEST_REPLICA_URL"] = testURL(port: part.port)
            case "proxy":
                variables["\(prefix)_TEST_PROXY_URL"] = testURL(port: part.port)
                if let control = part.controlPort { variables["\(prefix)_TEST_PROXY_CONTROL"] = "http://\(host):\(control)" }
            default: break
            }
        }
        if engine == .sqlServer, parts.count > 1, parts.allSatisfy({ $0.role == "primary" || $0.role.hasPrefix("secondary") }) {
            variables["SQLSERVER_TEST_AG_URLS"] = parts.map { testURL(port: $0.port) }.joined(separator: ",")
        }
        return variables
    }

    static func testURLPrefix(_ engine: EngineKind) -> String {
        switch engine {
        case .sqlServer: "SQLSERVER"
        case .postgres: "POSTGRES"
        case .mysql, .mariadb: "MYSQL"
        }
    }

    func testURL(port: Int) -> String {
        var components = URLComponents()
        components.host = host
        components.port = port
        // A Kerberos login names the domain user and no password: the ticket is the credential.
        if let kerberos {
            components.user = kerberos.userPrincipal
        } else {
            components.user = username
            components.password = password
        }
        var query: [URLQueryItem] = []
        switch engine {
        case .sqlServer:
            components.scheme = "sqlserver"
            components.path = "/master"
            let encrypt = switch tls?.mode {
            case .strict?: "strict"
            case .optional?: "optional"
            default: "mandatory"
            }
            query.append(URLQueryItem(name: "encrypt", value: encrypt))
            query.append(URLQueryItem(name: "trustServerCertificate", value: tls == nil ? "true" : "false"))
        case .postgres:
            components.scheme = "postgres"
            components.path = "/postgres"
            query.append(URLQueryItem(name: "sslmode", value: tls == nil ? "disable" : tls?.mode == .optional ? "prefer" : "verify-full"))
        case .mysql, .mariadb:
            components.scheme = "mysql"
            components.path = "/"
            query.append(URLQueryItem(name: "ssl-mode", value: tls == nil ? "PREFERRED" : tls?.mode == .optional ? "PREFERRED" : "VERIFY_IDENTITY"))
        }
        if let tls {
            switch engine {
            case .sqlServer: query.append(URLQueryItem(name: "caFile", value: tls.caPath))
            case .postgres:
                query.append(URLQueryItem(name: "sslrootcert", value: tls.caPath))
                if let certificate = tls.clientCertificatePath { query.append(URLQueryItem(name: "sslcert", value: certificate)) }
                if let key = tls.clientKeyPath { query.append(URLQueryItem(name: "sslkey", value: key)) }
            case .mysql, .mariadb:
                query.append(URLQueryItem(name: "ssl-ca", value: tls.caPath))
                if let certificate = tls.clientCertificatePath { query.append(URLQueryItem(name: "ssl-cert", value: certificate)) }
                if let key = tls.clientKeyPath { query.append(URLQueryItem(name: "ssl-key", value: key)) }
            }
        }
        if let kerberos {
            query.append(URLQueryItem(name: "authentication", value: "kerberos"))
            query.append(URLQueryItem(name: "serviceHost", value: kerberos.serviceHost))
            query.append(URLQueryItem(name: "krb5Config", value: kerberos.configurationPath))
        }
        components.queryItems = query
        // URLComponents leaves some characters a URL parser reads as delimiters in user info.
        components.percentEncodedUser = components.user.map(Self.encodeUserInfo)
        components.percentEncodedPassword = components.password.map(Self.encodeUserInfo)
        return components.string ?? ""
    }

    static func encodeUserInfo(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? text
    }
}
