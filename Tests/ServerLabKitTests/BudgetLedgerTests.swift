import Foundation
import Testing
@testable import ServerLabKit

struct BudgetLedgerTests {
    let host = LabHost(name: "ledger-test-\(UUID().uuidString.prefix(8))", dockerHost: "ssh://lab-host-that-does-not-exist.invalid",
                       address: "203.0.113.1", memoryBudgetMB: 1024, isDedicated: false, samplesDirectory: "/tmp")

    @Test func holdsCountUntilReleased() throws {
        let ledger = BudgetLedger(host: host)
        defer { try? FileManager.default.removeItem(at: ledger.directory) }
        let first = try ledger.hold(300)
        let second = try ledger.hold(200)
        #expect(ledger.heldMB() == 500)
        first.release()
        #expect(ledger.heldMB() == 200)
        second.release()
        #expect(ledger.heldMB() == 0)
    }

    @Test func holdsOfEndedProcessesAreIgnored() throws {
        let ledger = BudgetLedger(host: host)
        defer { try? FileManager.default.removeItem(at: ledger.directory) }
        _ = try ledger.hold(100)
        // No process has this id (above the macOS maximum).
        let stale = ledger.directory.appending(path: "99999999-stale.mb")
        try "4096".write(to: stale, atomically: true, encoding: .utf8)
        #expect(ledger.heldMB() == 100)
        #expect(!FileManager.default.fileExists(atPath: stale.path))
    }

    @Test func checkLockIsExclusiveAcrossOpenFiles() async throws {
        let ledger = BudgetLedger(host: host)
        defer { try? FileManager.default.removeItem(at: ledger.directory) }
        let held = try await ledger.lockChecks()
        // flock locks belong to the open file, so a second open (as another process would) waits.
        let other = open(ledger.directory.appending(path: ".lock").path, O_RDWR)
        defer { close(other) }
        #expect(flock(other, LOCK_EX | LOCK_NB) != 0)
        ledger.unlockChecks(held)
        #expect(flock(other, LOCK_EX | LOCK_NB) == 0)
    }

    @Test func anUnreachableHostFailsFastWithWhatToCheck() async throws {
        let lab = try ServerLab(host: host, engines: [], recipes: RecipeCatalog(recipes: []))
        let started = ContinuousClock.now
        await #expect {
            try await lab.checkHostReachable(timeout: .seconds(15))
        } throws: { error in
            guard case ServerLabError.hostUnreachable = error else { return false }
            return "\(error)".contains("SERVERLAB_HOST=local")
        }
        #expect(ContinuousClock.now - started < .seconds(20))
    }
}
