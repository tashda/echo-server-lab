import Foundation

/// Microsoft's own client as a second opinion: sqlcmd (ODBC Driver 18) from the server's image.
/// Its traffic shows what Microsoft sends, and with optional encryption only the login is encrypted,
/// so the rest of a capture can be read and checked against MS-TDS.
public enum MicrosoftClientEncryption: String, Sendable {
    /// Only the login is encrypted (`-N o`).
    case optional = "o"
    /// The whole session (`-N m`).
    case mandatory = "m"
    /// TDS 8 strict (`-N s`).
    case strict = "s"
}

extension ServerLab {
    /// Runs `sql` with sqlcmd against the server (through the lab host's published port, so a
    /// capture sees it) and returns what sqlcmd printed.
    @discardableResult
    public func runMicrosoftClient(_ server: LabServer, sql: String, database: String = "master",
                                   encryption: MicrosoftClientEncryption = .optional) async throws -> String {
        guard server.engine == .sqlServer else { throw ServerLabError.unsupported("sqlcmd against \(server.engine.rawValue)") }
        let recipe = try recipes.recipe(named: server.recipe)
        let image = try engine(for: .sqlServer).containerSpec(for: recipe, password: server.password).image
        // The password goes through an env file (SQLCMDPASSWORD), not the command line.
        let envFile = FileManager.default.temporaryDirectory.appending(path: "serverlab-\(UUID().uuidString).env")
        try "SQLCMDPASSWORD=\(server.password)".write(to: envFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: envFile.path)
        defer { try? FileManager.default.removeItem(at: envFile) }
        return try await docker.run(
            ["run", "--rm", "--memory", "256m", "--env-file", envFile.path, "--entrypoint", "/opt/mssql-tools18/bin/sqlcmd", image,
             "-S", "\(server.host),\(server.port)", "-U", server.username, "-C", "-N", encryption.rawValue,
             "-d", database, "-h", "-1", "-W", "-b", "-Q", sql]
        )
    }
}
