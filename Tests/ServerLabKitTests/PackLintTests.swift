import Foundation
import Testing

/// Packs fill servers through the drivers' typed APIs only; the raw-SQL escape hatches are not
/// allowed in pack sources (catalog/driver-gaps.md). Bodies of routines, views and triggers are SQL
/// by nature and pass through typed calls; this only looks for the hatches themselves.
@Suite struct PackLintTests {
    static let forbidden = [".sql(", ".raw(", "simpleQuery(", "client.execute(", "client.query(", "executeDDL(", "connection.query(",
                            "connection.execute("]
    static let packFolders = ["ServerLabSQLServer", "ServerLabPostgres", "ServerLabMySQL"]

    @Test func packsUseNoRawSQL() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources")
        var findings: [String] = []
        for folder in Self.packFolders {
            let directory = sources.appending(path: folder)
            for file in try FileManager.default.contentsOfDirectory(atPath: directory.path) where file.hasSuffix(".swift") {
                let lines = try String(contentsOf: directory.appending(path: file), encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
                for (number, line) in lines.enumerated() where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                    for hatch in Self.forbidden where line.contains(hatch) {
                        findings.append("\(folder)/\(file):\(number + 1) uses \(hatch)")
                    }
                }
            }
        }
        #expect(findings.isEmpty, "\(findings.joined(separator: "\n"))")
    }
}
