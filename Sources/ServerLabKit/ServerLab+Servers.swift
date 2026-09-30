import Foundation

extension ServerLab {
    /// Starts a fresh server from the recipe's seeded image (building it first if needed).
    /// The server is removed by `stop(_:)`, or by `reapExpired()` once `lease` has passed.
    public func start(
        _ recipe: Recipe,
        owner: String,
        lease: Duration = .seconds(2 * 3600),
        log: @escaping LabLog = { _ in }
    ) async throws -> LabServer {
        _ = try? await reapExpired()
        let image = try await seededImage(for: recipe, log: log)
        let engine = try engine(for: recipe.engine)
        let password = try LabPassword.resolve()
        let spec = try engine.containerSpec(for: recipe, password: password)
        try await waitForBudget(neededMB: spec.memoryMB, log: log)

        // The seeded image already carries the environment and command it was built with.
        let started = try await startContainer(
            image: image, spec: spec, role: .server, recipe: recipe, owner: owner, lease: lease,
            fingerprint: nil, environment: [:], command: []
        )
        let server = LabServer(
            recipe: recipe.name, engine: recipe.engine, version: recipe.version,
            host: host.address, port: started.port,
            username: engine.adminUsername, password: password,
            containerID: started.id, containerName: started.name,
            expires: Date().addingTimeInterval(TimeInterval(lease.components.seconds))
        )
        do {
            log("Waiting for \(started.name) on \(host.address):\(started.port)")
            try await engine.waitUntilReady(server.endpoint, timeout: .seconds(180))
        } catch {
            log("Start failed; last lines of the server log:\n\(await tailLog(started.id))")
            try? await stop(server)
            throw error
        }
        return server
    }

    public func start(recipeNamed name: String, owner: String, lease: Duration = .seconds(2 * 3600), log: @escaping LabLog = { _ in }) async throws -> LabServer {
        try await start(recipes.recipe(named: name), owner: owner, lease: lease, log: log)
    }

    public func stop(_ server: LabServer) async throws {
        try await stopCapture(of: server)
        try await remove(containerID: server.containerID)
    }

    /// Removes a lab container and its anonymous volumes.
    public func remove(containerID: String) async throws {
        try await docker.run(["rm", "--force", "--volumes", containerID])
    }

    /// Removes a lab server by container name, with its capture container if it has one.
    public func remove(serverNamed name: String) async throws {
        if name.hasPrefix("serverlab-"), !name.hasPrefix("serverlab-capture-") {
            _ = try await docker.runAllowingFailure(["rm", "--force", "serverlab-capture-\(name.dropFirst("serverlab-".count))"])
        }
        try await docker.run(["rm", "--force", "--volumes", name])
    }

    /// Lab containers (servers and builders) on this host.
    public func running() async throws -> [RunningServer] {
        let format = [
            "{{.ID}}", "{{.Names}}", "{{.Status}}",
            "{{.Label \"\(LabLabels.role)\"}}", "{{.Label \"\(LabLabels.recipe)\"}}",
            "{{.Label \"\(LabLabels.owner)\"}}", "{{.Label \"\(LabLabels.expires)\"}}",
        ].joined(separator: "\t")
        let output = try await docker.run(["ps", "--all", "--filter", "label=\(LabLabels.managed)=true", "--format", format])
        return output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 7 else { return nil }
            return RunningServer(
                id: fields[0], name: fields[1], status: fields[2], role: fields[3], recipe: fields[4], owner: fields[5],
                expires: Date(timeIntervalSince1970: TimeInterval(fields[6]) ?? 0)
            )
        }
    }

    /// Removes servers and builders whose lease has passed. Returns how many were removed. On a
    /// dedicated host it also removes volumes no container uses (never on a shared Docker).
    @discardableResult
    public func reapExpired(now: Date = Date()) async throws -> Int {
        let expired = try await running().filter { $0.role != LabLabels.Role.seeded.rawValue && $0.expires < now }
        for server in expired {
            _ = try await docker.runAllowingFailure(["rm", "--force", "--volumes", server.id])
        }
        if host.isDedicated {
            _ = try await docker.runAllowingFailure(["volume", "prune", "--force"])
            try? await pruneCaptures()
        }
        return expired.count
    }

    /// Memory taken on the host, in MB: the limits of running lab containers plus what every other
    /// container actually uses (other tools share the host, e.g. sqlserver-nio's nio-lab fixtures).
    public func reservedMemoryMB() async throws -> Int {
        let labIDs = Set(try await docker.run(["ps", "--quiet", "--no-trunc", "--filter", "label=\(LabLabels.managed)=true"])
            .split(separator: "\n").map(String.init))
        var reserved = 0
        if !labIDs.isEmpty {
            let limits = try await docker.run(["inspect", "--format", "{{.HostConfig.Memory}}"] + labIDs.sorted())
            reserved += limits.split(separator: "\n").compactMap { Int($0) }.reduce(0, +) / (1024 * 1024)
        }
        let usage = try await docker.run(["stats", "--no-stream", "--format", "{{.ID}}\t{{.MemUsage}}"])
        for line in usage.split(separator: "\n") {
            let fields = line.split(separator: "\t")
            guard fields.count == 2, !labIDs.contains(where: { $0.hasPrefix(fields[0]) }) else { continue }
            reserved += Self.megabytes(String(fields[1].split(separator: "/").first ?? ""))
        }
        return reserved
    }

    /// "1.089GiB" or "512MiB" (docker stats) in MB.
    static func megabytes(_ text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let units: [(String, Double)] = [("GiB", 1024), ("MiB", 1), ("KiB", 1.0 / 1024), ("GB", 1000), ("MB", 1), ("kB", 1.0 / 1000), ("B", 1.0 / 1_048_576)]
        for (unit, factor) in units where trimmed.hasSuffix(unit) {
            return Int((Double(trimmed.dropLast(unit.count)) ?? 0) * factor)
        }
        return 0
    }

    func waitForBudget(neededMB: Int, log: LabLog) async throws {
        if try await reservedMemoryMB() + neededMB <= host.memoryBudgetMB { return }
        log("Waiting for \(neededMB) MB within \(host.name)'s \(host.memoryBudgetMB) MB budget")
        try await retryUntilReady("memory budget", timeout: .seconds(900), every: .seconds(5)) {
            guard try await reservedMemoryMB() + neededMB <= host.memoryBudgetMB else {
                throw ServerLabError.budgetTimeout(neededMB: neededMB, budgetMB: host.memoryBudgetMB)
            }
        }
    }

    struct StartedContainer {
        var id: String
        var name: String
        var port: Int
    }

    func startContainer(
        image: String,
        spec: ContainerSpec,
        role: LabLabels.Role,
        recipe: Recipe,
        owner: String,
        lease: Duration,
        fingerprint: String?,
        environment: [String: String],
        command: [String],
        extraArguments: [String] = []
    ) async throws -> StartedContainer {
        let name = "serverlab-\(recipe.name)-\(UUID().uuidString.prefix(8).lowercased())"
        var labels = [
            LabLabels.managed: "true",
            LabLabels.role: role.rawValue,
            LabLabels.recipe: recipe.name,
            LabLabels.engine: recipe.engine.rawValue,
            LabLabels.version: recipe.version,
            LabLabels.owner: owner,
            LabLabels.expires: String(Int(Date().timeIntervalSince1970) + Int(lease.components.seconds)),
        ]
        if let fingerprint { labels[LabLabels.fingerprint] = fingerprint }

        // Secrets go through an env file (read by the local docker tool), not the command line.
        let envFile = FileManager.default.temporaryDirectory.appending(path: "serverlab-\(UUID().uuidString).env")
        try environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
            .write(to: envFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: envFile.path)
        defer { try? FileManager.default.removeItem(at: envFile) }

        let id = try await docker.run(
            ["run", "--detach", "--name", name, "--env-file", envFile.path,
             "--publish", String(spec.internalPort),
             "--memory", "\(spec.memoryMB)m", "--memory-swap", "\(spec.memoryMB)m"]
            + LabLabels.arguments(labels)
            + extraArguments
            + [image] + command
        )
        let mapping = try await docker.run(["port", id, "\(spec.internalPort)/tcp"])
        guard let port = mapping.split(separator: "\n").compactMap({ $0.split(separator: ":").last.flatMap { Int($0) } }).first else {
            throw ServerLabError.noPublishedPort(container: name)
        }
        return StartedContainer(id: id, name: name, port: port)
    }
}

public struct RunningServer: Sendable, Hashable {
    public var id: String
    public var name: String
    public var status: String
    public var role: String
    public var recipe: String
    public var owner: String
    public var expires: Date
}

extension ServerLab {
    /// Seeded images on this host: one per recipe fingerprint.
    public func seededImages() async throws -> [SeededImage] {
        // `docker images` has no label field in its format; the recipe is the name after `serverlab/`.
        let format = "{{.Repository}}\t{{.Tag}}\t{{.Size}}\t{{.CreatedSince}}"
        let output = try await docker.run(["images", "--filter", "label=\(LabLabels.role)=\(LabLabels.Role.seeded.rawValue)", "--format", format])
        return output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 4, fields[0].hasPrefix("serverlab/") else { return nil }
            return SeededImage(tag: "\(fields[0]):\(fields[1])", size: fields[2], created: fields[3],
                               recipe: String(fields[0].dropFirst("serverlab/".count)))
        }
    }
}

public struct SeededImage: Sendable, Hashable {
    public var tag: String
    public var size: String
    public var created: String
    public var recipe: String
}
