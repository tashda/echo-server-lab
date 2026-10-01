import CryptoKit
import Foundation
import Logging
import ServerLabKit
import SQLiteNIO

/// SQLite database files for tests, made through sqlite-nio (SQLite has no server): built once per
/// fixture version in `~/.echo-testlab/sqlite`, handed out as fresh copies a test may change.
public enum LabSQLiteFixture: String, Sendable, CaseIterable, Codable {
    /// Every declared type and affinity, a STRICT table, min/max/NULL rows and generated ones.
    case allTypes = "all-types"
    /// Foreign keys, CHECK, generated columns, AUTOINCREMENT, WITHOUT ROWID, unique/partial/
    /// expression indexes, views, BEFORE/AFTER triggers, FTS5, and R*Tree when compiled in.
    case programmability
    /// The Chinook sample database.
    case chinook

    var version: Int { 1 }

    public var summary: String {
        switch self {
        case .allTypes: "Every declared type and affinity, a STRICT table, minimum, maximum and NULL values."
        case .programmability: "Foreign keys, CHECK, generated columns, AUTOINCREMENT, WITHOUT ROWID, partial and expression indexes, views, triggers, FTS5."
        case .chinook: "The Chinook sample database (music store)."
        }
    }
}

public enum LabSQLite {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".echo-testlab/sqlite")
    }

    /// The built fixture (read it, do not change it); built the first time.
    public static func file(_ fixture: LabSQLiteFixture, log: LabLog = { _ in }) async throws -> URL {
        let file = directory.appending(path: "\(fixture.rawValue)-v\(fixture.version).sqlite")
        if FileManager.default.fileExists(atPath: file.path) { return file }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let building = directory.appending(path: "\(fixture.rawValue)-\(UUID().uuidString.prefix(8)).building")
        defer { try? FileManager.default.removeItem(at: building) }
        log("Building SQLite fixture \(fixture.rawValue)")
        let connection = try await SQLiteConnection.open(storage: .file(path: building.path), logger: driverLogger("serverlab.sqlite"))
        do {
            switch fixture {
            case .allTypes: try await SQLiteFixtures.allTypes(connection)
            case .programmability: try await SQLiteFixtures.programmability(connection)
            case .chinook: try await SQLiteFixtures.run(script: try await localSample("Chinook_Sqlite.sql", log: log), on: connection)
            }
            try await connection.close()
        } catch {
            try? await connection.close()
            throw error
        }
        // Another process may have built it meanwhile; either copy is the same.
        if !FileManager.default.fileExists(atPath: file.path) { try FileManager.default.moveItem(at: building, to: file) }
        return file
    }

    /// A copy of the fixture of its own, for a test that changes it. Remove it when done.
    public static func freshCopy(_ fixture: LabSQLiteFixture, log: LabLog = { _ in }) async throws -> URL {
        let source = try await file(fixture, log: log)
        let copy = FileManager.default.temporaryDirectory.appending(path: "serverlab-\(fixture.rawValue)-\(UUID().uuidString.prefix(8)).sqlite")
        try FileManager.default.copyItem(at: source, to: copy)
        return copy
    }

    /// A sample file on this machine, downloaded from the lab's mirror and checked once.
    static func localSample(_ name: String, log: LabLog) async throws -> String {
        let sample = try LabSamples.sample(named: name)
        let folder = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".echo-testlab/samples")
        let file = folder.appending(path: name)
        func checksum(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        if let data = try? Data(contentsOf: file), checksum(data) == sample.sha256 {
            return String(decoding: data, as: UTF8.self)
        }
        log("Downloading sample \(name)")
        let (data, _) = try await URLSession.shared.data(from: sample.source)
        guard checksum(data) == sample.sha256 else {
            throw ServerLabError.packRequirement(pack: "sqlite", reason: "\(name) does not match its checksum")
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: file)
        return String(decoding: data, as: UTF8.self)
    }
}
