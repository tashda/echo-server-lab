import Foundation

extension ServerLab {
    /// Makes sure every sample is on the lab host with the right checksum, downloading it from its
    /// source otherwise. Runs in small alpine containers, so it needs nothing on the host but Docker.
    public func ensureSamples(_ files: [String], log: LabLog) async throws {
        guard !files.isEmpty else { return }
        if host.dockerHost == nil {
            try FileManager.default.createDirectory(atPath: host.samplesDirectory, withIntermediateDirectories: true)
        }
        for file in Set(files).sorted() {
            let sample = try LabSamples.sample(named: file)
            if try await sampleChecksum(file) == sample.sha256 { continue }
            log("Downloading sample \(file) (\(sample.bytes / 1_048_576) MB)")
            try await docker.run([
                "run", "--rm", "--volume", "\(host.samplesDirectory):/s", "alpine",
                "sh", "-c", "wget -q -O /s/\(file).part '\(sample.source.absoluteString)' && mv /s/\(file).part /s/\(file) && chmod 644 /s/\(file)",
            ])
            guard try await sampleChecksum(file) == sample.sha256 else {
                throw ServerLabError.packRequirement(pack: "samples", reason: "\(file) does not match its checksum")
            }
        }
    }

    /// The text of a sample file on the lab host.
    public func sampleText(_ file: String) async throws -> String {
        _ = try LabSamples.sample(named: file)
        return try await docker.run(["run", "--rm", "--volume", "\(host.samplesDirectory):/s:ro", "alpine", "cat", "/s/\(file)"])
    }

    func sampleChecksum(_ file: String) async throws -> String? {
        let result = try await docker.runAllowingFailure([
            "run", "--rm", "--volume", "\(host.samplesDirectory):/s:ro", "alpine", "sh", "-c", "test -f /s/\(file) && sha256sum /s/\(file)",
        ])
        guard result.status == 0 else { return nil }
        return result.standardOutput.split(separator: " ").first.map(String.init)
    }
}
