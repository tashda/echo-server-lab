import Foundation

extension ServerLab {
    /// The seeded image for a recipe, built once and reused while the fingerprint matches.
    /// Building starts the base image, runs every pack through the driver, checks it, then commits.
    public func seededImage(for recipe: Recipe, log: @escaping LabLog = { _ in }) async throws -> String {
        try validate(recipe)
        let engine = try engine(for: recipe.engine)
        let password = try LabPassword.resolve()
        let spec = try engine.containerSpec(for: recipe, password: password)

        let baseImageID = try await baseImageID(spec.image, log: log)
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

        log("Building \(tag) from \(spec.image)")
        let builder = try await startContainer(
            image: spec.image,
            spec: spec,
            role: .builder,
            recipe: recipe,
            owner: "builder",
            lease: .seconds(2 * 3600),
            fingerprint: fingerprint,
            environment: spec.environment,
            command: spec.command
        )
        do {
            let endpoint = ServerEndpoint(host: host.address, port: builder.port, username: engine.adminUsername, password: password)
            log("Waiting for \(recipe.engine.rawValue) \(recipe.version) on port \(builder.port)")
            try await engine.waitUntilReady(endpoint, timeout: .seconds(300))
            for (use, pack) in packs {
                log("Pack \(pack.name): creating")
                try await pack.apply(to: endpoint, recipe: recipe, parameters: use.params, log: log)
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
            try await docker.run(["rm", "--force", builder.id])
            return tag
        } catch {
            log("Build failed; last lines of the server log:\n\(await tailLog(builder.id))")
            _ = try? await docker.runAllowingFailure(["rm", "--force", builder.id])
            throw error
        }
    }

    /// The local image ID of `reference`, pulled first when the host does not have it.
    func baseImageID(_ reference: String, log: LabLog) async throws -> String {
        if try await !imageExists(reference) {
            log("Pulling \(reference)")
            try await docker.run(["pull", "--quiet", reference])
        }
        return try await docker.run(["image", "inspect", "--format", "{{.Id}}", reference])
    }

    func imageExists(_ reference: String) async throws -> Bool {
        try await docker.runAllowingFailure(["image", "inspect", "--format", "{{.Id}}", reference]).status == 0
    }

    func tailLog(_ container: String) async -> String {
        guard let result = try? await docker.runAllowingFailure(["logs", "--tail", "30", container]) else { return "" }
        return result.standardOutput + result.standardError
    }
}
