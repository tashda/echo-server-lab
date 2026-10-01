import Foundation
import MySQLKit
import ServerLabKit

/// One account per login plugin the server offers, each with the server's password, named
/// `lab_auth_<plugin>`: `caching_sha2_password`, `sha256_password` and `mysql_native_password`
/// (MySQL, when the server has it loaded); `mysql_native_password`, `ed25519` and `parsec`
/// (MariaDB, installing the plugin library when the server ships it).
struct MySQLAuthenticationPack: ContentPack {
    let name = "auth-plugins"
    let version = 1
    let summary = "An account for every login plugin: caching_sha2, sha256, native, ed25519, parsec."

    static let mysqlPlugins = ["caching_sha2_password", "sha256_password", "mysql_native_password"]
    /// MariaDB plugins and the library each comes from (nil: built in).
    static let mariaDBPlugins: [(name: String, library: String?)] = [
        ("mysql_native_password", nil), ("ed25519", "auth_ed25519"), ("parsec", "auth_parsec"),
    ]

    static func account(for plugin: String) -> String { "lab_auth_\(plugin.replacingOccurrences(of: "_password", with: ""))" }

    /// The plugins this server will get accounts for (the same answer at build and check).
    static func plugins(on client: MySQLClient, engine: EngineKind) async throws -> [String] {
        let active = Set(try await client.metadata.listPlugins().filter { $0.status == "ACTIVE" }.map(\.name))
        switch engine {
        case .mariadb: return mariaDBPlugins.map(\.name).filter(active.contains)
        default: return mysqlPlugins.filter(active.contains)
        }
    }

    func apply(to server: ServerEndpoint, recipe: Recipe, parameters: PackParameters, context: PackContext) async throws {
        let created = try await MySQLSession.with(server) { client in
            if recipe.engine == .mariadb {
                let installed = Set(try await client.metadata.listPlugins().map(\.name))
                for plugin in Self.mariaDBPlugins where !installed.contains(plugin.name) {
                    guard let library = plugin.library else { continue }
                    // parsec ships from 11.6 on; an older server has no such library.
                    do { try await client.security.installPlugin(name: plugin.name, library: library) } catch {
                        context.log("  \(plugin.name) not available: \(error)")
                    }
                }
            }
            let plugins = try await Self.plugins(on: client, engine: recipe.engine)
            for plugin in plugins {
                _ = try await client.security.createUser(username: Self.account(for: plugin), host: "%",
                                                         password: server.password, authenticationPlugin: plugin)
            }
            return plugins
        }
        context.log("  accounts for \(created.joined(separator: ", "))")
    }

    func verify(on server: ServerEndpoint, recipe: Recipe, parameters: PackParameters) async throws {
        let (plugins, accounts) = try await MySQLSession.with(server) { client in
            (try await Self.plugins(on: client, engine: recipe.engine), try await client.security.listUsers())
        }
        let found = Dictionary(accounts.map { ($0.username, $0.authenticationPlugin ?? "") }, uniquingKeysWith: { first, _ in first })
        let wrong = plugins.filter { found[Self.account(for: $0)] != $0 }
        guard !plugins.isEmpty, wrong.isEmpty else {
            throw ServerLabError.packCheckFailed(pack: name, reason: "accounts missing or on another plugin: \(wrong), plugins \(plugins)")
        }
    }
}
