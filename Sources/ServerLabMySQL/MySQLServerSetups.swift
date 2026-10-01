import Foundation
import MySQLKit
import ServerLabKit

/// TLS for MySQL and MariaDB: the lab's certificate, `require_secure_transport` for `required` and
/// `strict`, and TLS 1.3 only for `strict`.
extension MySQLEngine {
    public func topology(for recipe: Recipe, setup: ServerSetup) throws -> ServerTopology {
        guard recipe.settings.topology == nil else {
            throw ServerLabError.unsupported("Topology '\(recipe.settings.topology ?? "")' on \(kind.displayName)")
        }
        guard setup.kerberos == nil, recipe.settings.kerberos != true else {
            throw ServerLabError.unsupported("Kerberos on \(kind.displayName)")
        }
        guard let tls = setup.tls else { return .single }
        if tls.mode == .clientCertificate {
            // mysql-wire cannot present a client certificate yet (catalog/driver-gaps.md).
            throw ServerLabError.unsupported("Client-certificate login on \(kind.displayName)")
        }
        var arguments = ["--ssl-ca=/labconf/ca.pem", "--ssl-cert=/labconf/server.pem", "--ssl-key=/labconf/server.key"]
        if tls.mode != .optional { arguments.append("--require-secure-transport=ON") }
        if tls.mode == .strict { arguments.append("--tls-version=TLSv1.3") }
        // The images run the server as uid 999 (mysql).
        return ServerTopology(mainRole: "server", mainFiles: [
            "/labconf/ca.pem": ContainerFile(tls.caPEM),
            "/labconf/server.pem": ContainerFile(tls.server.certificatePEM),
            "/labconf/server.key": ContainerFile(tls.server.keyPEM, mode: 0o600, owner: 999),
        ], mainArguments: arguments)
    }
}
