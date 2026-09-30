import Foundation

/// The certificates the lab issued for one server, handed to the engine to put into its containers.
public struct ServerTLS: Sendable, Hashable {
    public var mode: TLSMode
    public var certificateKind: LabCertificateKind
    public var caPEM: String
    public var server: IssuedCertificate
    /// Only for `client-certificate`: the admin user's certificate.
    public var client: IssuedCertificate?
}

extension ServerLab {
    /// Directory for a server's local files (client certificate and key); removed with the server.
    static func localFilesDirectory(forServer name: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".echo-testlab/servers/\(name)")
    }

    /// Issues the certificates a recipe's `tls` setting asks for, and writes the files a client
    /// needs next to the lab CA. Nil when the recipe has no TLS setup.
    func issueTLS(for recipe: Recipe, serverName: String, adminUsername: String) throws -> (ServerTLS, EndpointTLS)? {
        guard let settings = recipe.settings.tls else { return nil }
        let ca = try LabCertificateAuthority.load()
        let hostNames = ["localhost", host.name, "\(host.name).lan"] + (LabCertificateAuthority.ipv4Bytes(host.address) == nil ? [host.address] : [])
        let server = try ca.issueServer(
            settings.certificate,
            dnsNames: hostNames + ["primary", "standby", "secondary"],
            ipAddresses: [host.address, "127.0.0.1"]
        )
        var endpoint = EndpointTLS(mode: settings.mode, certificate: settings.certificate, caPath: ca.certificatePath)
        var client: IssuedCertificate?
        if settings.mode == .clientCertificate {
            let issued = try ca.issueClient(user: adminUsername)
            let directory = Self.localFilesDirectory(forServer: serverName)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let certificateFile = directory.appending(path: "client.pem"), keyFile = directory.appending(path: "client.key")
            try issued.certificatePEM.write(to: certificateFile, atomically: true, encoding: .utf8)
            try issued.keyPEM.write(to: keyFile, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)
            endpoint.clientCertificatePath = certificateFile.path
            endpoint.clientKeyPath = keyFile.path
            client = issued
        }
        return (ServerTLS(mode: settings.mode, certificateKind: settings.certificate, caPEM: ca.certificatePEM, server: server, client: client), endpoint)
    }
}
