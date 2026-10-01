import Foundation
import ServerLabKit
import SQLServerKit

/// Encryption objects: a database (default EncryptedLab) with a master key, certificates (one
/// valid, one expired), a symmetric key protected by a certificate and an asymmetric key; Always
/// Encrypted keys and a table with a deterministic and a randomized column (no rows: inserting
/// needs client-side encryption, and the key's value is a placeholder); and Transparent Data
/// Encryption on it with a certificate in master. Parameter: `database`.
struct SQLServerEncryptionPack: ContentPack {
    let name = "encryption"
    let version = 2
    let summary = "Master key, certificates (one expired), symmetric and asymmetric keys, and TDE on the database."

    static let serverCertificate = "LabTDECertificate"

    func apply(to server: ServerEndpoint, recipe: Recipe, parameters: PackParameters, context: PackContext) async throws {
        let database = try parameters.string("database", default: "EncryptedLab")
        try await SQLServerSession.with(server) { client in
            try await client.admin.createDatabase(name: database)
            try await client.security.createMasterKey(password: server.password)
            try await client.security.createCertificate(name: Self.serverCertificate, subject: "Lab TDE certificate")
        }
        try await SQLServerSession.with(server, database: database) { client in
            let security = client.security
            try await security.createMasterKey(password: server.password)
            try await security.createCertificate(name: "PayrollCertificate", subject: "Protects the payroll key",
                                                 expiryDate: Date(timeIntervalSinceNow: 5 * 365 * 86_400))
            try await security.createCertificate(name: "ExpiredCertificate", subject: "Expired on purpose",
                                                 startDate: Date(timeIntervalSince1970: 1_262_304_000),
                                                 expiryDate: Date(timeIntervalSince1970: 1_577_836_800))
            try await security.createSymmetricKey(name: "PayrollKey", algorithm: .aes256, encryptedByCertificate: "PayrollCertificate")
            try await security.createAsymmetricKey(name: "SigningKey", algorithm: .rsa2048)

            let alwaysEncrypted = client.alwaysEncrypted
            try await alwaysEncrypted.createColumnMasterKey(name: "LabColumnMasterKey", keyStoreProviderName: "MSSQL_CERTIFICATE_STORE",
                                                            keyPath: "CurrentUser/My/0123456789ABCDEF0123456789ABCDEF01234567")
            try await alwaysEncrypted.createColumnEncryptionKey(name: "LabColumnKey", cmkName: "LabColumnMasterKey", algorithm: "RSA_OAEP",
                                                                encryptedValue: "0x" + String(repeating: "AB", count: 256))
            try await client.admin.scoped(to: database).createTable(name: "Patients", columns: [
                SQLServerColumnDefinition(name: "Id", definition: .standard(.init(dataType: .int, isPrimaryKey: true))),
                SQLServerColumnDefinition(name: "SSN", definition: .standard(.init(
                    dataType: .nvarchar(length: .length(11)), collation: "Latin1_General_BIN2",
                    alwaysEncrypted: .init(columnEncryptionKey: "LabColumnKey", type: .deterministic)))),
                SQLServerColumnDefinition(name: "Salary", definition: .standard(.init(
                    dataType: .int, alwaysEncrypted: .init(columnEncryptionKey: "LabColumnKey", type: .randomized)))),
            ])
        }
        try await SQLServerSession.with(server) { client in
            try await client.security.createDatabaseEncryptionKey(database: database, serverCertificate: Self.serverCertificate)
            try await client.admin.alterDatabaseOption(name: database, option: .encryption(true))
        }
        context.log("  keys and certificates in \(database), TDE on")
    }

    func verify(on server: ServerEndpoint, recipe: Recipe, parameters: PackParameters) async throws {
        let database = try parameters.string("database", default: "EncryptedLab")
        let (certificates, symmetric, asymmetric) = try await SQLServerSession.with(server, database: database) { client in
            (try await client.security.listCertificates().map(\.name), try await client.security.listSymmetricKeys().map(\.name),
             try await client.security.listAsymmetricKeys().map(\.name))
        }
        let encryptedColumns = try await SQLServerSession.with(server, database: database) { try await $0.alwaysEncrypted.listEncryptedColumns() }
        guard Set(encryptedColumns.map(\.column)) == ["SSN", "Salary"] else {
            throw ServerLabError.packCheckFailed(pack: name, reason: "encrypted columns \(encryptedColumns.map(\.column))")
        }
        let tde = try await SQLServerSession.with(server) { client in
            try await client.security.listDatabaseEncryption().first { $0.database == database }
        }
        guard Set(certificates).isSuperset(of: ["PayrollCertificate", "ExpiredCertificate"]), symmetric.contains("PayrollKey"),
              asymmetric.contains("SigningKey"), tde?.certificate == Self.serverCertificate else {
            throw ServerLabError.packCheckFailed(pack: name, reason: "certificates \(certificates), keys \(symmetric) \(asymmetric), TDE \(String(describing: tde))")
        }
    }
}
