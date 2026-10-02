import Foundation
@testable import ServerLabKit
import SwiftASN1
import Testing
import X509

@Suite struct LabCertificateTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: "serverlab-ca-\(UUID().uuidString)")

    @Test func caIsMadeOnceAndReused() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try LabCertificateAuthority.load(directory: directory)
        let second = try LabCertificateAuthority.load(directory: directory)
        #expect(first.certificatePEM == second.certificatePEM)
        let keyMode = try FileManager.default.attributesOfItem(atPath: directory.appending(path: "lab-ca.key").path)[.posixPermissions] as? Int
        #expect(keyMode == 0o600)
    }

    @Test(arguments: LabCertificateKind.allCases)
    func serverCertificateHasTheKindAsked(_ kind: LabCertificateKind) throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let ca = try LabCertificateAuthority.load(directory: directory)
        let issued = try ca.issueServer(kind, dnsNames: ["lab", "primary"], ipAddresses: ["192.0.2.10"])
        let certificate = try Certificate(pemEncoded: issued.certificatePEM)
        #expect(issued.keyPEM.hasPrefix("-----BEGIN PRIVATE KEY-----"))

        let names = try #require(try certificate.extensions.subjectAlternativeNames)
        let expectsHost = kind != .wrongHost
        #expect(names.contains(.dnsName("lab")) == expectsHost)
        #expect(names.contains(.ipAddress(ASN1OctetString(contentBytes: [192, 0, 2, 10]))) == expectsHost)
        #expect((certificate.notValidAfter < Date()) == (kind == .expired))
        #expect((certificate.issuer == ca.certificate.subject) == (kind != .selfSigned))
    }

    @Test func clientCertificateNamesTheUser() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let issued = try LabCertificateAuthority.load(directory: directory).issueClient(user: "postgres")
        let certificate = try Certificate(pemEncoded: issued.certificatePEM)
        #expect(certificate.subject.description.contains("CN=postgres"))
    }
}

@Suite struct TarArchiveTests {
    @Test func keepsOwnerModeAndContents() throws {
        let archive = TarArchive.make(["/labconf/server.key": ContainerFile("secret", mode: 0o600, owner: 999)])
        #expect(archive.count == 512 + 512 + 1024)
        let header = [UInt8](archive.prefix(512))
        func field(_ offset: Int, _ length: Int) -> String {
            String(decoding: header[offset..<offset + length].prefix { $0 != 0 }, as: UTF8.self)
        }
        #expect(field(0, 100) == "labconf/server.key")
        #expect(field(100, 8) == "0000600")
        #expect(field(108, 8) == "0001747")
        #expect(Int(field(124, 12), radix: 8) == 6)
        // The checksum is the byte sum with its own field read as spaces.
        var blank = header
        for index in 148..<156 { blank[index] = 0x20 }
        #expect(Int(field(148, 6), radix: 8) == blank.reduce(0) { $0 + Int($1) })
        #expect(String(decoding: archive[512..<518], as: UTF8.self) == "secret")
    }

    @Test func directoryIsAnEntryWithNoContents() {
        let archive = TarArchive.make(["/labdata/tablespaces/fast": .directory(owner: 999)])
        #expect(archive.count == 512 + 1024)
        let header = [UInt8](archive.prefix(512))
        #expect(String(decoding: header[0..<100].prefix { $0 != 0 }, as: UTF8.self) == "labdata/tablespaces/fast/")
        #expect(String(decoding: header[100..<107], as: UTF8.self) == "0000700")
        #expect(header[156] == UInt8(ascii: "5"))
    }
}
