import Foundation
import Testing
@testable import ServerLabKit

@Suite struct LabSampleDownloadTests {
    @Test func plainFilesAreDownloadedAsTheyAre() throws {
        let sample = try LabSamples.sample(named: "Chinook_MySql.sql")
        let command = ServerLab.downloadCommand(for: sample)
        #expect(command.hasPrefix("wget -q -O /s/Chinook_MySql.sql.part "))
        #expect(!command.contains("tar "))
    }

    @Test func archiveMembersAreExtracted() throws {
        let sample = try LabSamples.sample(named: "world.sql")
        let command = ServerLab.downloadCommand(for: sample)
        #expect(command.contains("https://downloads.mysql.com/docs/world-db.tar.gz"))
        #expect(command.contains("tar -xzOf /s/world.sql.tgz 'world-db/world.sql' > /s/world.sql.part"))
        #expect(command.hasSuffix("mv /s/world.sql.part /s/world.sql && chmod 644 /s/world.sql"))
    }

    @Test func noSampleComesFromThisRepositoryExceptSakila() {
        let mirrored = LabSamples.all.filter { $0.source.absoluteString.contains("echo-server-lab/releases") }.map(\.file)
        #expect(mirrored.sorted() == ["sakila-data.sql", "sakila-schema.sql"])
    }
}
