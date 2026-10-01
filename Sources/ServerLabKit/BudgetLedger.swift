import Foundation

/// Memory promised to servers that are starting but not yet running, shared by every process on
/// this Mac (Echo's test suites each run their own `serverlab`): one file per start in
/// `~/.echo-testlab/budget/<host>/`, named after the process, so a crashed process's holds are
/// ignored. Starts on other machines (CI) are not counted until their containers exist.
struct BudgetLedger: Sendable {
    /// One budget check at a time in this process; `lockChecks()` extends it to other processes.
    static let checks = DockerGate(limit: 1)

    let directory: URL

    init(host: LabHost) {
        directory = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".echo-testlab/budget/\(host.name)")
    }

    /// A start's memory, held until `release()`.
    struct Hold: Sendable {
        let file: URL
        func release() { try? FileManager.default.removeItem(at: file) }
    }

    func hold(_ megabytes: Int) throws -> Hold {
        try createDirectory()
        let file = directory.appending(path: "\(getpid())-\(UUID().uuidString).mb")
        try String(megabytes).write(to: file, atomically: true, encoding: .utf8)
        return Hold(file: file)
    }

    /// What live processes hold; files left by processes that ended are removed.
    func heldMB() -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var total = 0
        for file in files where file.pathExtension == "mb" {
            guard let pid = Int32(file.lastPathComponent.split(separator: "-").first ?? ""), Self.isRunning(pid) else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            total += Int((try? String(contentsOf: file, encoding: .utf8)) ?? "") ?? 0
        }
        return total
    }

    /// Takes the cross-process check lock (an `flock` on `.lock`), polling so no thread blocks.
    func lockChecks() async throws -> Int32 {
        try createDirectory()
        let descriptor = open(directory.appending(path: ".lock").path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch {
                close(descriptor)
                throw error
            }
        }
        return descriptor
    }

    func unlockChecks(_ descriptor: Int32) {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    private func createDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    static func isRunning(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}
