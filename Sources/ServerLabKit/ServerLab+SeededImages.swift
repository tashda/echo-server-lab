import Foundation

extension ServerLab {
    /// The seeded image for a recipe, built once and reused while the fingerprint matches.
    /// Building starts the base image, runs every pack through the driver, checks it, then commits.
    public func seededImage(for recipe: Recipe, log: @escaping LabLog = { _ in }) async throws -> String {
        try validate(recipe)
        let engine = try engine(for: recipe.engine)
        let password = try LabPassword.resolve()
        let spec = try engine.containerSpec(for: recipe, password: password)

        let baseImageID = try await baseImageID(spec, log: log)
        let packs = try recipe.packs.map { use in
            guard let pack = engine.pack(named: use.pack) else { throw ServerLabError.unknownPack(use.pack, engine: recipe.engine) }
            return (use: use, pack: pack)
        }
        let fingerprint = try RecipeFingerprint.compute(
            recipe: recipe,
            packVersions: Dictionary(packs.map { ($0.pack.name, $0.pack.version) }, uniquingKeysWith: max),
            baseImageID: baseImageID,
            password: password
        )
        let tag = RecipeFingerprint.imageTag(recipe: recipe.name, fingerprint: fingerprint)
        if try await imageExists(tag) {
            log("Using seeded image \(tag)")
            return tag
        }

        let samples = try packs.flatMap { try $0.pack.requiredSamples(parameters: $0.use.params) }
        try await ensureSamples(samples, log: log)
        log("Building \(tag) from \(spec.image)")
        let builder = try await startContainer(
            image: spec.image,
            spec: spec,
            role: .builder,
            recipe: recipe,
            owner: "builder",
            // A builder outlives a crashed build only this long before the reaper removes it;
            // the slowest build (a large sample restore) takes about twenty minutes.
            lease: .seconds(45 * 60),
            fingerprint: fingerprint,
            environment: spec.environment,
            command: spec.command,
            extraArguments: (samples.isEmpty ? [] : ["--volume", "\(host.samplesDirectory):\(LabSamples.containerDirectory):ro"])
                + (spec.hostname.map { ["--hostname", $0] } ?? [])
        )
        do {
            let endpoint = ServerEndpoint(host: host.address, port: builder.port, username: engine.adminUsername, password: password)
            log("Waiting for \(recipe.engine.rawValue) \(recipe.version) on port \(builder.port)")
            try await engine.waitUntilReady(endpoint, timeout: .seconds(300))
            for (use, pack) in packs {
                log("Pack \(pack.name): creating")
                let lab = self
                let context = PackContext(log: log, sampleText: { try await lab.sampleText($0) })
                try await pack.apply(to: endpoint, recipe: recipe, parameters: use.params, context: context)
                log("Pack \(pack.name): checking")
                try await pack.verify(on: endpoint, recipe: recipe, parameters: use.params)
            }
            log("Saving \(tag)")
            try await docker.run(["stop", "--time", "120", builder.id])
            try await docker.run(
                ["commit"]
                + [LabLabels.role: LabLabels.Role.seeded.rawValue, LabLabels.expires: "0", LabLabels.owner: "none",
                   LabLabels.fingerprint: fingerprint]
                    .sorted { $0.key < $1.key }
                    .flatMap { ["--change", "LABEL \($0.key)=\($0.value)"] }
                + [builder.id, tag]
            )
            try await docker.run(["rm", "--force", "--volumes", builder.id])
            return tag
        } catch {
            log("Build failed; last lines of the server log:\n\(await tailLog(builder.id))")
            _ = try? await docker.runAllowingFailure(["rm", "--force", "--volumes", builder.id])
            throw error
        }
    }

    /// The tag the recipe's seeded image has today, without building it. Nil when the base image
    /// is not on the host yet (then no seeded image for it can be current either).
    public func currentImageTag(for recipe: Recipe) async throws -> String? {
        let engine = try engine(for: recipe.engine)
        let password = try LabPassword.resolve()
        let spec = try engine.containerSpec(for: recipe, password: password)
        guard try await imageExists(spec.image) else { return nil }
        let baseImageID = try await docker.run(["image", "inspect", "--format", "{{.Id}}", spec.image])
        let versions = Dictionary(recipe.packs.compactMap { use in engine.pack(named: use.pack).map { ($0.name, $0.version) } },
                                  uniquingKeysWith: max)
        let fingerprint = try RecipeFingerprint.compute(recipe: recipe, packVersions: versions, baseImageID: baseImageID, password: password)
        return RecipeFingerprint.imageTag(recipe: recipe.name, fingerprint: fingerprint)
    }

    /// Removes seeded images that no shipped recipe would use any more (an older fingerprint, or a
    /// recipe that no longer exists). Returns the removed tags.
    @discardableResult
    public func pruneOutdatedImages() async throws -> [String] {
        var current: Set<String> = []
        for recipe in recipes.recipes {
            if let tag = try await currentImageTag(for: recipe) { current.insert(tag) }
        }
        let outdated = try await seededImages().map(\.tag).filter { !current.contains($0) }
        for tag in outdated {
            _ = try await docker.runAllowingFailure(["image", "rm", tag])
        }
        return outdated
    }

    /// The local image ID of `reference`, pulled first when the host does not have it.
    func baseImageID(_ reference: String, log: LabLog) async throws -> String {
        try await baseImageID(ContainerSpec(image: reference, internalPort: 0, environment: [:], memoryMB: 0), log: log)
    }

    /// The local image ID of the spec's image: pulled, or built from its Dockerfile, the first time.
    func baseImageID(_ spec: ContainerSpec, log: LabLog) async throws -> String {
        let reference = spec.image
        if try await !imageExists(reference) {
            if let dockerfile = spec.dockerfile {
                log("Building base image \(reference) (once per host)")
                try await buildImage(reference, dockerfile: dockerfile)
            } else {
                log("Pulling \(reference)")
                try await docker.run(["pull", "--quiet", reference])
            }
        }
        return try await docker.run(["image", "inspect", "--format", "{{.Id}}", reference])
    }

    /// `docker build` with the Dockerfile on standard input (no build context).
    func buildImage(_ tag: String, dockerfile: String) async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "serverlab-\(UUID().uuidString).Dockerfile")
        try dockerfile.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let result = try await docker.runAllowingFailure(
            ["build", "--quiet", "--label", "\(LabLabels.managed)=true", "--tag", tag, "-"], input: file)
        guard result.status == 0 else {
            throw ServerLabError.dockerFailed(command: "build \(tag)", status: result.status,
                                              output: String((result.standardError + result.standardOutput).suffix(2_000)))
        }
    }

    func imageExists(_ reference: String) async throws -> Bool {
        try await docker.runAllowingFailure(["image", "inspect", "--format", "{{.Id}}", reference]).status == 0
    }

    func tailLog(_ container: String) async -> String {
        guard let result = try? await docker.runAllowingFailure(["logs", "--tail", "30", container]) else { return "" }
        return result.standardOutput + result.standardError
    }
}
