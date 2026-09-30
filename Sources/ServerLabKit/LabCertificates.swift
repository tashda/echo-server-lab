import Crypto
import CryptoExtras
import Foundation
import SwiftASN1
import X509

/// Which certificate a TLS server gets. Everything but `valid` is for tests of certificate checks.
public enum LabCertificateKind: String, Codable, Sendable, Hashable, CaseIterable {
    /// Signed by the lab CA, names the lab host, valid now.
    case valid
    /// Signed by the lab CA, but its validity ended yesterday.
    case expired
    /// Signed by the lab CA, but names `wrong-host.invalid` only.
    case wrongHost = "wrong-host"
    /// Names the lab host, but signed by itself, not the lab CA.
    case selfSigned = "self-signed"
}

/// A certificate and its private key, PEM encoded.
public struct IssuedCertificate: Sendable, Hashable {
    public var certificatePEM: String
    /// PKCS#8 (`BEGIN PRIVATE KEY`), which PostgreSQL and SQL Server both read.
    public var keyPEM: String
}

/// This machine's lab CA: made on first use and kept in `~/.echo-testlab/ca`, so it can be trusted
/// once (e.g. in Echo) and every TLS server the lab starts from here is signed by it.
public struct LabCertificateAuthority: Sendable {
    let certificate: Certificate
    let key: Certificate.PrivateKey
    public let certificatePEM: String
    /// The CA certificate on disk, for a driver's `caCertificatePath` / `sslRootCertPath`.
    public let certificatePath: String

    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".echo-testlab/ca")
    }

    public static func load(directory: URL = defaultDirectory) throws -> LabCertificateAuthority {
        let certificateFile = directory.appending(path: "lab-ca.pem")
        let keyFile = directory.appending(path: "lab-ca.key")
        if let certificatePEM = try? String(contentsOf: certificateFile, encoding: .utf8),
           let keyPEM = try? String(contentsOf: keyFile, encoding: .utf8) {
            let certificate = try Certificate(pemEncoded: certificatePEM)
            let key = Certificate.PrivateKey(try _RSA.Signing.PrivateKey(pemRepresentation: keyPEM))
            return LabCertificateAuthority(certificate: certificate, key: key, certificatePEM: certificatePEM, certificatePath: certificateFile.path)
        }
        let rsa = try _RSA.Signing.PrivateKey(keySize: .bits2048)
        let key = Certificate.PrivateKey(rsa)
        let name = try DistinguishedName {
            OrganizationName("Echo")
            CommonName("Echo Server Lab CA (\(ProcessInfo.processInfo.hostName))")
        }
        let now = Date()
        let certificate = try Certificate(
            version: .v3, serialNumber: .init(), publicKey: key.publicKey,
            notValidBefore: now.addingTimeInterval(-3600), notValidAfter: now.addingTimeInterval(20 * 365 * 86_400),
            issuer: name, subject: name, signatureAlgorithm: .sha256WithRSAEncryption,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.isCertificateAuthority(maxPathLength: 0))
                Critical(KeyUsage(keyCertSign: true, cRLSign: true))
                SubjectKeyIdentifier(hash: key.publicKey)
            },
            issuerPrivateKey: key
        )
        let certificatePEM = try certificate.serializeAsPEM().pemString
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try rsa.pkcs8PEMRepresentation.write(to: keyFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)
        try certificatePEM.write(to: certificateFile, atomically: true, encoding: .utf8)
        return LabCertificateAuthority(certificate: certificate, key: key, certificatePEM: certificatePEM, certificatePath: certificateFile.path)
    }

    /// A server certificate for `dnsNames` and `ipAddresses` (IPv4), of the given kind.
    public func issueServer(_ kind: LabCertificateKind, dnsNames: [String], ipAddresses: [String]) throws -> IssuedCertificate {
        let names = kind == .wrongHost ? ["wrong-host.invalid"] : dnsNames
        var alternatives: [GeneralName] = names.map { .dnsName($0) }
        if kind != .wrongHost {
            alternatives += ipAddresses.compactMap(Self.ipv4Bytes).map { .ipAddress(ASN1OctetString(contentBytes: $0[...])) }
        }
        let now = Date()
        let (notBefore, notAfter) = kind == .expired
            ? (now.addingTimeInterval(-30 * 86_400), now.addingTimeInterval(-86_400))
            : (now.addingTimeInterval(-3600), now.addingTimeInterval(30 * 86_400))
        return try issue(commonName: names.first ?? "lab", alternatives: alternatives, usage: .serverAuth,
                         notBefore: notBefore, notAfter: notAfter, selfSigned: kind == .selfSigned)
    }

    /// A client certificate for certificate login (PostgreSQL `cert`): the common name is the user.
    public func issueClient(user: String) throws -> IssuedCertificate {
        let now = Date()
        return try issue(commonName: user, alternatives: [], usage: .clientAuth,
                         notBefore: now.addingTimeInterval(-3600), notAfter: now.addingTimeInterval(30 * 86_400), selfSigned: false)
    }

    private func issue(commonName: String, alternatives: [GeneralName], usage: ExtendedKeyUsage.Usage,
                       notBefore: Date, notAfter: Date, selfSigned: Bool) throws -> IssuedCertificate {
        let rsa = try _RSA.Signing.PrivateKey(keySize: .bits2048)
        let key = Certificate.PrivateKey(rsa)
        let subject = try DistinguishedName {
            OrganizationName("Echo Server Lab")
            CommonName(commonName)
        }
        let certificate = try Certificate(
            version: .v3, serialNumber: .init(), publicKey: key.publicKey,
            notValidBefore: notBefore, notValidAfter: notAfter,
            issuer: selfSigned ? subject : certificate.subject, subject: subject,
            signatureAlgorithm: .sha256WithRSAEncryption,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                Critical(KeyUsage(digitalSignature: true, keyEncipherment: true))
                try ExtendedKeyUsage([usage])
                SubjectKeyIdentifier(hash: key.publicKey)
                if !alternatives.isEmpty { SubjectAlternativeNames(alternatives) }
            },
            issuerPrivateKey: selfSigned ? key : self.key
        )
        return IssuedCertificate(certificatePEM: try certificate.serializeAsPEM().pemString, keyPEM: rsa.pkcs8PEMRepresentation)
    }

    static func ipv4Bytes(_ address: String) -> [UInt8]? {
        let parts = address.split(separator: ".").compactMap { UInt8($0) }
        return parts.count == 4 ? parts : nil
    }
}
