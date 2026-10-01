import Synchronization
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
        try await checkHostReachable()
        _ = try? await reapExpired()
        let engine = try engine(for: recipe.engine)
        let password = try LabPassword.resolve()
        let spec = try engine.containerSpec(for: recipe, password: password)
        let name = "serverlab-\(recipe.name)-\(UUID().uuidString.prefix(8).lowercased())"
        let tls = try issueTLS(for: recipe, serverName: name, adminUsername: engine.adminUsername)
        // Before anything starts, so a setting the engine cannot do fails without a build.
        var setup = ServerSetup(password: password, tls: tls?.0)
        var topology = try engine.topology(for: recipe, setup: setup)
        let kerberos = recipe.settings.kerberos == true
        if kerberos, !topology.parts.isEmpty { throw ServerLabError.unsupported("Kerberos on a server with several parts") }
        let mainPort = Int.random(in: Self.hostPorts)
        let serverID = String(name.suffix(8))
        if kerberos { _ = try engine.kerberosService(for: recipe, serverID: serverID, hostPort: mainPort) }
        let image = try await seededImage(for: recipe, log: log)
        for part in topology.parts { _ = try await baseImageID(part.container, log: log) }
        let held = try await waitForBudget(neededMB: spec.memoryMB + topology.parts.map { $0.container.memoryMB }.reduce(0, +), log: log)
        // Until its containers run (and count themselves), this start's memory is held in the ledger.
        defer { held.release() }

        // Kerberos servers join the lab domain's network; servers with several parts get their own.
        let network = kerberos ? Self.domainNetwork : topology.parts.isEmpty ? nil : try await createNetwork(forServer: name)
        let tlsLabel = tls.map { ["--label", "\(LabLabels.tls)=\($0.1.mode.rawValue)/\($0.1.certificate.rawValue)"] } ?? []
        var domainArguments: [String] = []
        func networkArguments(_ role: String, hostname: String?) -> [String] {
            let domain = role == topology.mainRole ? domainArguments : []
            // Kerberos sets the host name itself (the service name).
            let name = domain.isEmpty ? hostname.map { ["--hostname", $0] } ?? [] : []
            return tlsLabel + domain + name + (network.map { ["--network", $0, "--network-alias", role] } ?? [])
        }

        // Kerberos: the service's account, SPNs and keytab exist in the domain before it starts.
        var kerberosInfo: LabKerberosInfo?
        if kerberos {
            let controller = try await ensureDomainController(password: password, log: log)
            let service = try engine.kerberosService(for: recipe, serverID: serverID, hostPort: mainPort)
            let keytab = try await prepareDomain(service: service, password: password)
            setup.kerberos = ServerKerberos(service: service, keytab: keytab, controllerAddress: controller)
            topology = try engine.topology(for: recipe, setup: setup)
            domainArguments = ["--dns", controller, "--dns-search", LabDomain.dnsName,
                               "--add-host", "\(LabDomain.controller):\(controller)",
                               "--add-host", "\(LabDomain.dnsName):\(controller)",
                               // SQL Server resolves the NetBIOS domain name to find the DC for LDAP.
                               "--add-host", "\(LabDomain.netbiosName.lowercased()):\(controller)",
                               "--hostname", service.hostName,
                               "--label", "\(LabLabels.kerberos)=\(service.hostName)|\(service.account)"]
            kerberosInfo = self.kerberosInfo(serviceHost: service.hostName)
        }

        // The seeded image already carries the environment and command it was built with.
        var mainSpec = spec
        mainSpec.files.merge(topology.mainFiles) { $1 }
        let main: StartedContainer
        do {
            main = try await startContainer(
                image: image, spec: mainSpec, role: .server, recipe: recipe, owner: owner, lease: lease,
                fingerprint: nil, environment: topology.mainEnvironment,
                command: topology.mainArguments.isEmpty ? [] : spec.command + topology.mainArguments,
                name: name, server: name, part: topology.mainRole, port: kerberos ? mainPort : nil,
                extraArguments: networkArguments(topology.mainRole, hostname: spec.hostname)
            )
        } catch {
            try? await remove(serverNamed: name)
            throw error
        }
        var server = LabServer(
            recipe: recipe.name, engine: recipe.engine, version: recipe.version,
            host: host.address, port: main.port,
            username: engine.adminUsername, password: password,
            containerID: main.id, containerName: main.name,
            expires: Date().addingTimeInterval(TimeInterval(lease.components.seconds)),
            parts: [LabServerPart(role: topology.mainRole, containerID: main.id, containerName: main.name, port: main.port)],
            tls: tls?.1,
            kerberos: kerberosInfo
        )
        var current = main.id
        do {
            log("Waiting for \(main.name) on \(host.address):\(main.port)")
            try await engine.waitUntilReady(server.endpoint, timeout: .seconds(180))
            for part in topology.parts {
                let started = try await startContainer(
                    image: part.container.image, spec: part.container, role: .server, recipe: recipe, owner: owner, lease: lease,
                    fingerprint: nil, environment: part.container.environment, command: part.container.command,
                    name: "\(name)-\(part.role)", server: name, part: part.role,
                    extraArguments: networkArguments(part.role, hostname: part.container.hostname)
                )
                current = started.id
                server.parts.append(LabServerPart(role: part.role, containerID: started.id, containerName: started.name, port: started.port,
                                                  controlPort: started.extraPorts.sorted { $0.key < $1.key }.first?.value))
                if part.acceptsLogins {
                    log("Waiting for \(part.role) \(started.name) on \(host.address):\(started.port)")
                    try await engine.waitUntilReady(try server.endpoint(of: part.role), timeout: .seconds(300))
                }
            }
            if !topology.parts.isEmpty {
                log("Waiting for \(server.parts.map { $0.role }.joined(separator: ", ")) to work together")
                try await engine.waitUntilTopologyReady(server, files: PartFileCopier(lab: self, server: server))
            }
            try await engine.configure(server)
        } catch {
            log("Start failed; last lines of the log:\n\(await tailLog(current))")
            if ProcessInfo.processInfo.environment["SERVERLAB_KEEP_FAILED"] == "1" {
                log("Kept \(server.containerName) for debugging (SERVERLAB_KEEP_FAILED=1); remove it with serverlab down")
            } else {
                try? await stop(server)
            }
            throw error
        }
        return server
    }

    public func start(recipeNamed name: String, owner: String, lease: Duration = .seconds(2 * 3600), log: @escaping LabLog = { _ in }) async throws -> LabServer {
        try await start(recipes.recipe(named: name), owner: owner, lease: lease, log: log)
    }

    /// Removes the server: every part, its network and its capture.
    public func stop(_ server: LabServer) async throws {
        try await remove(serverNamed: server.containerName)
    }

    /// Removes a lab container and its anonymous volumes.
    public func remove(containerID: String) async throws {
        try await docker.run(["rm", "--force", "--volumes", containerID])
    }

    /// Removes a lab server by its main container's name: every part, its network and its capture.
    public func remove(serverNamed name: String) async throws {
        if name.hasPrefix("serverlab-"), !name.hasPrefix("serverlab-capture-") {
            _ = try await docker.runAllowingFailure(["rm", "--force", "serverlab-capture-\(name.dropFirst("serverlab-".count))"])
        }
        let domainLabel = try await docker.runAllowingFailure(["inspect", "--format", "{{index .Config.Labels \"\(LabLabels.kerberos)\"}}", name])
        let account = domainLabel.status == 0 ? domainLabel.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "|").dropFirst().first.map(String.init) : nil
        let parts = try await docker.run(["ps", "--all", "--format", "{{.Names}}", "--filter", "label=\(LabLabels.server)=\(name)"])
            .split(separator: "\n").map(String.init)
        try await docker.run(["rm", "--force", "--volumes"] + Set(parts + [name]).sorted())
        let networks = try await docker.run(["network", "ls", "--quiet", "--filter", "label=\(LabLabels.server)=\(name)"])
            .split(separator: "\n").map(String.init)
        if !networks.isEmpty { _ = try await docker.runAllowingFailure(["network", "rm"] + networks) }
        try? FileManager.default.removeItem(at: Self.localFilesDirectory(forServer: name))
        if account != nil { try await releaseDomain(account: account) }
    }

    /// Lab containers (servers and builders) on this host.
    public func running() async throws -> [RunningServer] {
        let format = [
            "{{.ID}}", "{{.Names}}", "{{.Status}}",
            "{{.Label \"\(LabLabels.role)\"}}", "{{.Label \"\(LabLabels.recipe)\"}}",
            "{{.Label \"\(LabLabels.owner)\"}}", "{{.Label \"\(LabLabels.expires)\"}}",
            "{{.Label \"\(LabLabels.server)\"}}", "{{.Label \"\(LabLabels.part)\"}}",
        ].joined(separator: "\t")
        let output = try await docker.run(["ps", "--all", "--filter", "label=\(LabLabels.managed)=true", "--format", format])
        return output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 9 else { return nil }
            return RunningServer(
                id: fields[0], name: fields[1], status: fields[2], role: fields[3], recipe: fields[4], owner: fields[5],
                expires: Date(timeIntervalSince1970: TimeInterval(fields[6]) ?? 0),
                server: fields[7].isEmpty ? fields[1] : fields[7], part: fields[8]
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
        // The domain goes once no Kerberos server is left.
        if try await docker.runAllowingFailure(["inspect", Self.domainContainer]).status == 0 {
            try? await releaseDomain(account: nil)
        }
        // Only lab networks, and only those no container uses any more.
        _ = try await docker.runAllowingFailure(["network", "prune", "--force", "--filter", "label=\(LabLabels.managed)=true"])
        if host.isDedicated {
            _ = try await docker.runAllowingFailure(["volume", "prune", "--force"])
            if CapturePruning.claim() { try? await pruneCaptures() }
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
            // Other suites remove servers meanwhile: inspect still prints the ones that exist.
            let limits = try await docker.runAllowingFailure(["inspect", "--format", "{{.HostConfig.Memory}}"] + labIDs.sorted()).standardOutput
            reserved += limits.split(separator: "\n").compactMap { Int($0) }.reduce(0, +) / (1024 * 1024)
        }
        let usage = try await docker.runAllowingFailure(["stats", "--no-stream", "--format", "{{.ID}}\t{{.MemUsage}}"]).standardOutput
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

    /// Waits until `neededMB` fits in the host's budget, counting starts on this Mac that are still
    /// on their way (in any process), and holds it in the ledger until released. One start on this
    /// Mac checks at a time, so suites starting together do not all see the same free memory.
    func waitForBudget(neededMB: Int, log: LabLog) async throws -> BudgetLedger.Hold {
        let ledger = BudgetLedger(host: host)
        await BudgetLedger.checks.enter()
        defer { Task { await BudgetLedger.checks.leave() } }
        let lock = try await ledger.lockChecks()
        defer { ledger.unlockChecks(lock) }
        @Sendable func fits() async throws -> Bool {
            try await reservedMemoryMB() + ledger.heldMB() + neededMB <= host.memoryBudgetMB
        }
        if try await !fits() {
            log("Waiting for \(neededMB) MB within \(host.name)'s \(host.memoryBudgetMB) MB budget")
            try await retryUntilReady("memory budget", timeout: .seconds(45 * 60), every: .seconds(5)) {
                guard try await fits() else { throw ServerLabError.budgetTimeout(neededMB: neededMB, budgetMB: host.memoryBudgetMB) }
            }
        }
        return try ledger.hold(neededMB)
    }

    struct StartedContainer {
        var id: String
        var name: String
        var port: Int
        /// Host ports of `ContainerSpec.extraPorts`, by container port.
        var extraPorts: [Int: Int] = [:]
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
        name: String? = nil,
        server: String? = nil,
        part: String? = nil,
        port fixedPort: Int? = nil,
        extraArguments: [String] = []
    ) async throws -> StartedContainer {
        let name = name ?? "serverlab-\(recipe.name)-\(UUID().uuidString.prefix(8).lowercased())"
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
        if let server { labels[LabLabels.server] = server }
        if let part { labels[LabLabels.part] = part }
        labels[LabLabels.ports] = ([spec.internalPort] + spec.extraPorts).map(String.init).joined(separator: ",")

        // Secrets go through an env file (read by the local docker tool), not the command line.
        let envFile = FileManager.default.temporaryDirectory.appending(path: "serverlab-\(UUID().uuidString).env")
        try environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
            .write(to: envFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: envFile.path)
        defer { try? FileManager.default.removeItem(at: envFile) }

        // A fixed host port (not an ephemeral one), so the address survives stopping and starting
        // the container. The range is below Linux's and Docker's ephemeral ports; a taken port is retried.
        for _ in 1...(fixedPort == nil ? 10 : 1) {
            let port = fixedPort ?? Int.random(in: Self.hostPorts)
            let extraPorts = Dictionary(uniqueKeysWithValues: spec.extraPorts.map { ($0, Int.random(in: Self.hostPorts)) })
            let id = try await docker.run(
                ["create", "--name", name, "--env-file", envFile.path,
                 "--publish", "\(port):\(spec.internalPort)"]
                + extraPorts.sorted { $0.key < $1.key }.flatMap { ["--publish", "\($0.value):\($0.key)"] }
                + ["--memory", "\(spec.memoryMB)m", "--memory-swap", "\(spec.memoryMB)m"]
                + LabLabels.arguments(labels)
                + extraArguments
                + [image] + command
            )
            do {
                try await copy(spec.files, into: id)
            } catch {
                _ = try? await docker.runAllowingFailure(["rm", "--force", "--volumes", id])
                throw error
            }
            let started = try await docker.runAllowingFailure(["start", id])
            if started.status == 0 { return StartedContainer(id: id, name: name, port: port, extraPorts: extraPorts) }
            _ = try await docker.runAllowingFailure(["rm", "--force", "--volumes", id])
            let message = started.standardError
            guard message.contains("already allocated") || message.contains("address already in use") else {
                throw ServerLabError.dockerFailed(command: "start \(name)", status: started.status, output: message)
            }
        }
        throw ServerLabError.noPublishedPort(container: name)
    }

    static let hostPorts = 20_000...29_999

    /// Puts files into a created container (before it starts), with their owners and modes.
    func copy(_ files: [String: ContainerFile], into container: String) async throws {
        guard !files.isEmpty else { return }
        let archive = FileManager.default.temporaryDirectory.appending(path: "serverlab-files-\(UUID().uuidString).tar")
        try TarArchive.make(files).write(to: archive)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: archive.path)
        defer { try? FileManager.default.removeItem(at: archive) }
        let result = try await docker.runAllowingFailure(["cp", "--archive", "-", "\(container):/"], input: archive)
        guard result.status == 0 else {
            throw ServerLabError.dockerFailed(command: "cp into \(container)", status: result.status, output: result.standardError)
        }
    }

    /// A private network for a server's parts; each part is reachable there by its role.
    func createNetwork(forServer server: String) async throws -> String {
        let network = "serverlab-net-\(server.suffix(8))"
        try await docker.run(["network", "create", "--label", "\(LabLabels.managed)=true", "--label", "\(LabLabels.server)=\(server)", network])
        return network
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
    /// The main container's name of the server this container belongs to (its own name for older containers).
    public var server: String
    /// `server`, `primary`, `standby`, …; empty for builders and captures.
    public var part: String
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

/// Old captures are pruned once per process, not by every suite's reaper.
enum CapturePruning {
    private static let done = Mutex(false)

    static func claim() -> Bool {
        done.withLock { done in
            defer { done = true }
            return !done
        }
    }
}
