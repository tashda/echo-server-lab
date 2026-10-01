import Foundation
import ServerLabKit
import SQLServerKit

/// Database Mail: an account pointing at the lab's Mailpit part (`smtp`), a profile everyone may use,
/// and mail in every state. Mail sent while the image is built fails (no mail server then), which
/// leaves failed items; once the server runs with its `smtp` part, more mail is sent and delivered.
extension SQLServerEngine {
    static let mailRole = "smtp"
    static let mailProfile = "LabMail"
    /// Mailpit 1.x, pinned.
    static let mailServerPart = ServerPartSpec(
        role: mailRole,
        container: ContainerSpec(image: "axllent/mailpit@sha256:e22dce5b36f93c77082e204a3942fb6b283b7896e057458400a4c88344c3df68",
                                 internalPort: 1025, environment: ["MP_SMTP_AUTH_ACCEPT_ANY": "1", "MP_SMTP_AUTH_ALLOW_INSECURE": "1"],
                                 memoryMB: 128, extraPorts: [8025]),
        acceptsLogins: false
    )

    /// Sends mail that reaches Mailpit, and checks that it arrived through Mailpit's API.
    func deliverMail(_ server: LabServer) async throws {
        guard let mailpit = server.parts.first(where: { $0.role == Self.mailRole }), let apiPort = mailpit.controlPort else { return }
        try await SQLServerSession.with(server.endpoint, database: "msdb") { client in
            try await client.databaseMail.start()
            try await client.databaseMail.sendTestEmail(profileName: Self.mailProfile, recipients: "inbox@lab.test",
                                                       subject: "Delivered by the lab", body: "Database Mail reached Mailpit.")
        }
        try await retryUntilReady("mail in Mailpit", timeout: .seconds(120), every: .seconds(2)) {
            guard let url = URL(string: "http://\(server.host):\(apiPort)/api/v1/messages") else { return }
            let (data, _) = try await URLSession.shared.data(from: url)
            let total = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["total"] as? Int ?? 0
            guard total >= 1 else { throw ServerLabError.notReady("mail", lastError: "Mailpit has \(total) messages") }
        }
    }
}

/// Database Mail turned on with an account (the `smtp` part, port 1025), a public default profile
/// and failed mail from the build. SQL Server 2019+ (Database Mail on Linux).
struct SQLServerDatabaseMailPack: ContentPack {
    let name = "database-mail"
    let version = 1
    let summary = "Database Mail: account, public default profile, and failed mail (delivered mail once the smtp part runs)."

    func apply(to server: ServerEndpoint, recipe: Recipe, parameters: PackParameters, context: PackContext) async throws {
        guard (Int(recipe.version) ?? 0) >= 2019 else {
            throw ServerLabError.packRequirement(pack: name, reason: "Database Mail on Linux needs SQL Server 2019 or later")
        }
        try await SQLServerSession.with(server, database: "msdb") { client in
            let mail = client.databaseMail
            try await mail.enableFeature()
            let account = try await mail.createAccount(SQLServerMailAccountConfig(
                accountName: "LabSMTP", emailAddress: "sqlserver@lab.test", displayName: "Echo lab SQL Server",
                replyToAddress: "noreply@lab.test", description: "Mailpit part of the lab server",
                serverName: SQLServerEngine.mailRole, port: 1025, username: nil, password: nil, useDefaultCredentials: false, enableSSL: false
            ))
            let profile = try await mail.createProfile(name: SQLServerEngine.mailProfile, description: "Default lab profile")
            try await mail.addAccountToProfile(profileID: profile, accountID: account, sequenceNumber: 1)
            try await mail.grantProfileAccess(profileID: profile, principalName: "public", isDefault: true)
            for index in 1...3 {
                try await mail.sendTestEmail(profileName: SQLServerEngine.mailProfile, recipients: "someone\(index)@lab.test",
                                             subject: "Sent while building (no mail server yet)", body: "Mail \(index)")
            }
        }
        context.log("  account LabSMTP, profile LabMail, 3 mails queued without a mail server")
    }

    func verify(on server: ServerEndpoint, recipe: Recipe, parameters: PackParameters) async throws {
        let (profiles, queued) = try await SQLServerSession.with(server, database: "msdb") { client in
            (try await client.databaseMail.listProfiles().count, try await client.databaseMail.mailQueue().count)
        }
        guard profiles >= 1, queued >= 3 else {
            throw ServerLabError.packCheckFailed(pack: name, reason: "\(profiles) profiles, \(queued) mail items")
        }
    }
}
