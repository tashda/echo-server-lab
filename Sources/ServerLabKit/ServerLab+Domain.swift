import Foundation

/// The lab's Active Directory domain: one Samba DC shared by every Kerberos server that runs, on a
/// fixed KDC port, so one krb5.conf serves every test process (GSS reads it once per process).
/// Each server adds its own service account and host name; the DC goes with the last server.
extension ServerLab {
    static let domainContainer = "serverlab-domain"
    static let domainNetwork = "serverlab-domain"
    /// Below the servers' port range, so a server never takes it.
    static let kdcHostPort = 19_088
    static let controllerMemoryMB = 768

    /// This machine's krb5.conf for the lab realm (`KRB5_CONFIG`).
    static var clientKerberosConfigurationPath: String {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".echo-testlab/krb5.conf").path
    }

    /// The DC image, built once per Dockerfile version.
    func domainControllerImage(log: LabLog) async throws -> String {
        let tag = "serverlab-part/samba-ad:" + String(RecipeFingerprint.digest(Self.domainControllerDockerfile).prefix(12))
        guard try await !imageExists(tag) else { return tag }
        log("Building \(tag) (Samba AD DC)")
        let file = FileManager.default.temporaryDirectory.appending(path: "serverlab-\(UUID().uuidString).Dockerfile")
        try Self.domainControllerDockerfile.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let result = try await docker.runAllowingFailure(["build", "--quiet", "--tag", tag, "-"], input: file)
        guard result.status == 0 else { throw ServerLabError.dockerFailed(command: "build \(tag)", status: result.status, output: result.standardError) }
        return tag
    }

    /// Starts the DC unless it runs, and waits until its KDC issues tickets. Returns its address on
    /// the domain network, which Kerberos servers join.
    func ensureDomainController(password: String, log: LabLog) async throws -> String {
        let image = try await domainControllerImage(log: log)
        let running = try await docker.runAllowingFailure(["inspect", "--format", "{{.State.Running}}", Self.domainContainer])
        if running.status != 0 || running.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) != "true" {
            if running.status == 0 { _ = try await docker.runAllowingFailure(["rm", "--force", "--volumes", Self.domainContainer]) }
            _ = try await docker.runAllowingFailure(["network", "create", "--label", "\(LabLabels.managed)=true", Self.domainNetwork])
            let envFile = FileManager.default.temporaryDirectory.appending(path: "serverlab-\(UUID().uuidString).env")
            try "ADMIN_PASSWORD=\(password)".write(to: envFile, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: envFile.path)
            defer { try? FileManager.default.removeItem(at: envFile) }
            let created = try await docker.runAllowingFailure(
                ["run", "--detach", "--name", Self.domainContainer, "--hostname", "dc", "--env-file", envFile.path,
                 "--network", Self.domainNetwork, "--network-alias", LabDomain.controller,
                 "--publish", "\(Self.kdcHostPort):88",
                 "--memory", "\(Self.controllerMemoryMB)m", "--memory-swap", "\(Self.controllerMemoryMB)m"]
                + LabLabels.arguments([LabLabels.managed: "true", LabLabels.role: "domain", LabLabels.recipe: "domain",
                                       LabLabels.owner: "lab", LabLabels.part: "kdc",
                                       // Removed with the last Kerberos server; this is only a backstop.
                                       LabLabels.expires: String(Int(Date().timeIntervalSince1970) + 24 * 3600)])
                + [image, "bash", "-c", Self.domainControllerScript]
            )
            // Another start may have created it at the same moment; then use that one.
            if created.status != 0, !created.standardError.contains("already in use") {
                throw ServerLabError.dockerFailed(command: "run \(Self.domainContainer)", status: created.status, output: created.standardError)
            }
            log("Waiting for the \(LabDomain.realm) domain controller")
        }
        try await retryUntilReady("domain controller", timeout: .seconds(180)) {
            _ = try await inController("echo \"$ADMIN_PASSWORD\" | kinit administrator@\(LabDomain.realm) >/dev/null")
        }
        try writeClientKerberosConfiguration()
        return try await docker.run(["inspect", "--format", "{{(index .NetworkSettings.Networks \"\(Self.domainNetwork)\").IPAddress}}", Self.domainContainer])
    }

    /// Runs a command in the DC as root and returns its output.
    func inController(_ script: String) async throws -> String {
        try await docker.run(["exec", Self.domainContainer, "bash", "-c", script])
    }

    /// Creates the service account with AES keys and its SPNs (and the shared test user once), and
    /// returns the service's keytab.
    func prepareDomain(service: KerberosService, password: String) async throws -> Data {
        let quoted = "'" + password.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let keytab = "/tmp/\(service.account).keytab"
        var script = """
            set -e
            samba-tool user show \(LabDomain.user) >/dev/null 2>&1 || samba-tool user create \(LabDomain.user) \(quoted) >/dev/null 2>&1 \
              || samba-tool user show \(LabDomain.user) >/dev/null
            samba-tool user setexpiry \(LabDomain.user) --noexpiry >/dev/null
            samba-tool user create \(service.account) \(quoted) >/dev/null
            samba-tool user setexpiry \(service.account) --noexpiry >/dev/null
            printf 'dn: CN=\(service.account),CN=Users,DC=lab,DC=test\\nchangetype: modify\\nreplace: msDS-SupportedEncryptionTypes\\nmsDS-SupportedEncryptionTypes: 24\\n' \
              | ldbmodify -H /var/lib/samba/private/sam.ldb >/dev/null
            rm -f \(keytab)

            """
        for principal in service.servicePrincipals {
            script += "samba-tool spn add \(principal) \(service.account) >/dev/null\n"
        }
        for principal in service.servicePrincipals + [service.account] {
            script += "samba-tool domain exportkeytab \(keytab) --principal=\(principal) >/dev/null\n"
        }
        _ = try await inController(script)
        let data = try await docker.runData(["exec", Self.domainContainer, "cat", keytab])
        _ = try? await inController("rm -f \(keytab)")
        return data
    }

    /// Deletes a removed server's service account, and the DC once no Kerberos server is left.
    func releaseDomain(account: String?) async throws {
        if let account { _ = try? await inController("samba-tool user delete \(account) >/dev/null 2>&1 || true") }
        let users = try await docker.run(["ps", "--all", "--quiet", "--filter", "label=\(LabLabels.kerberos)"])
        guard users.isEmpty else { return }
        _ = try await docker.runAllowingFailure(["rm", "--force", "--volumes", Self.domainContainer])
        _ = try await docker.runAllowingFailure(["network", "rm", Self.domainNetwork])
    }

    /// This machine's krb5.conf: the lab realm's KDC over TCP on the lab host.
    func writeClientKerberosConfiguration() throws {
        let file = URL(fileURLWithPath: Self.clientKerberosConfigurationPath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
            [libdefaults]
             default_realm = \(LabDomain.realm)
             dns_lookup_kdc = false
             dns_lookup_realm = false
             rdns = false
             dns_canonicalize_hostname = false
             udp_preference_limit = 0
            [realms]
             \(LabDomain.realm) = {
              kdc = tcp/\(host.address):\(Self.kdcHostPort)
             }
            [domain_realm]
             .\(LabDomain.dnsName) = \(LabDomain.realm)
             \(LabDomain.dnsName) = \(LabDomain.realm)

            """.write(to: file, atomically: true, encoding: .utf8)
    }

    func kerberosInfo(serviceHost: String) -> LabKerberosInfo {
        LabKerberosInfo(realm: LabDomain.realm, serviceHost: serviceHost, userPrincipal: "\(LabDomain.user)@\(LabDomain.realm)",
                        kdcHost: host.address, kdcPort: Self.kdcHostPort, configurationPath: Self.clientKerberosConfigurationPath)
    }
}
