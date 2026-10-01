import Foundation
import Synchronization

extension ServerLab {
    /// Hosts this process has reached already.
    private static let reachedHosts = Mutex<Set<String>>([])

    /// Fails within seconds, naming what to check, when the Docker host cannot be reached (testlab
    /// off, no LAN or Tailscale, SSH key missing), instead of letting the first Docker command wait
    /// out its timeout. Checked once per host per process.
    public func checkHostReachable(timeout: Duration = .seconds(20)) async throws {
        if Self.reachedHosts.withLock({ $0.contains(host.name) }) { return }
        let result = try await docker.runOnce(["version", "--format", "{{.Server.Version}}"], input: nil, timeout: timeout)
        guard result.status == 0, !result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let detail = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ServerLabError.hostUnreachable(host: host.name, address: host.address, detail: detail.isEmpty ? "no answer within \(timeout)" : detail)
        }
        _ = Self.reachedHosts.withLock { $0.insert(host.name) }
    }
}
