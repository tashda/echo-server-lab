import Foundation

/// What an engine gets to set a server up beyond its seeded image.
public struct ServerSetup: Sendable {
    public var password: String
    public var tls: ServerTLS?
    public var kerberos: ServerKerberos?

    public init(password: String, tls: ServerTLS? = nil, kerberos: ServerKerberos? = nil) {
        self.password = password
        self.tls = tls
        self.kerberos = kerberos
    }
}

/// The Active Directory domain every Kerberos server of the lab gets (its own Samba DC per server).
public enum LabDomain {
    public static let realm = "LAB.TEST"
    public static let netbiosName = "LAB"
    public static let dnsName = "lab.test"
    /// The domain controller's name inside the server's network.
    public static let controller = "dc.lab.test"
    /// The domain user tests log in as (password: the lab password); engines give it a login.
    public static let user = "labuser"
}

/// What an engine needs the domain to hold for its service: an account, its SPNs, and the keytab.
public struct KerberosService: Sendable, Hashable {
    /// The name clients connect to (`sql.lab.test`); resolves to the lab host through DNS.
    public var hostName: String
    /// The service account in the domain (`sqlsvc`).
    public var account: String
    /// SPNs registered for the account, without the realm (`MSSQLSvc/sql.lab.test:24000`).
    public var servicePrincipals: [String]

    public init(hostName: String, account: String, servicePrincipals: [String]) {
        self.hostName = hostName
        self.account = account
        self.servicePrincipals = servicePrincipals
    }
}

/// The domain side of a Kerberos server, handed to the engine: its service's keytab and the DC.
public struct ServerKerberos: Sendable, Hashable {
    public var service: KerberosService
    /// Keys for every SPN and the account (AES), as a keytab file.
    public var keytab: Data
    /// The DC's address on the server's network.
    public var controllerAddress: String

    /// krb5.conf for containers on the server's network.
    public var containerConfiguration: String {
        """
        [libdefaults]
         default_realm = \(LabDomain.realm)
         dns_lookup_kdc = false
         dns_lookup_realm = false
         rdns = false
        [realms]
         \(LabDomain.realm) = {
          kdc = \(LabDomain.controller)
          admin_server = \(LabDomain.controller)
          default_domain = \(LabDomain.realm)
         }
        [domain_realm]
         .\(LabDomain.dnsName) = \(LabDomain.realm)
         \(LabDomain.dnsName) = \(LabDomain.realm)

        """
    }
}

/// How a client reaches a Kerberos lab server: names, the KDC, and a krb5.conf for this machine.
public struct LabKerberosInfo: Sendable, Hashable, Codable {
    public var realm: String
    /// Connect to this name (not the IP): the service ticket is for it.
    public var serviceHost: String
    /// The domain user (`labuser@LAB.TEST`); its password is the lab password.
    public var userPrincipal: String
    public var kdcHost: String
    public var kdcPort: Int
    /// A krb5.conf for this machine (`KRB5_CONFIG`), pointing at the server's KDC over TCP.
    public var configurationPath: String
}

extension ServerLab {
    /// Samba 4.22 AD DC on Debian 13; built on the lab host the first time it is needed.
    static let domainControllerDockerfile = """
        FROM debian:trixie-slim
        RUN apt-get update \\
         && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \\
              samba samba-ad-dc samba-ad-provision samba-dsdb-modules samba-vfs-modules winbind krb5-user ldb-tools \\
         && rm -rf /var/lib/apt/lists/* /etc/samba/smb.conf /var/lib/samba/* /var/cache/samba/*
        """
    /// Provisions the domain on first start (xattrs in a tdb: overlayfs has no security xattrs),
    /// then runs the DC in the foreground.
    static let domainControllerScript = """
        set -e
        if [ ! -f /var/lib/samba/private/sam.ldb ]; then
          samba-tool domain provision --realm=\(LabDomain.realm) --domain=\(LabDomain.netbiosName) --server-role=dc \\
            --dns-backend=SAMBA_INTERNAL --adminpass="$ADMIN_PASSWORD" --use-rfc2307 \\
            --option="dns forwarder = 127.0.0.11" --option="vfs objects = dfs_samba4 acl_xattr xattr_tdb" \\
            >/tmp/provision.log 2>&1 || { cat /tmp/provision.log; exit 1; }
          samba-tool domain passwordsettings set --complexity=off --min-pwd-length=1 --max-pwd-age=0 >/dev/null
          printf '[libdefaults]\\n default_realm = \(LabDomain.realm)\\n dns_lookup_kdc = false\\n[realms]\\n \(LabDomain.realm) = {\\n  kdc = 127.0.0.1\\n }\\n' > /etc/krb5.conf
        fi
        exec samba --foreground --no-process-group
        """
}

extension LabKerberosInfo {
    /// How a test's Kerberos login gets its credentials.
    public enum Credentials: Sendable, Equatable {
        /// `kinit` into the lab's ticket cache first (`KRB5CCNAME=FILE:…`), as libpq-style clients expect.
        case ticketCache
        /// The driver gets a ticket itself from the user's password, into a MEMORY cache of its own
        /// (macOS GSS cannot move such credentials into a FILE cache).
        case password
    }

    /// Runs `body` with this process pointed at the lab realm (`KRB5_CONFIG`) and, for
    /// `.ticketCache`, holding a ticket for the domain user. The environment is process-wide, so
    /// Kerberos logins take turns here; do every Kerberos connect inside `body`.
    public func withTicket<T: Sendable>(password: String, credentials: Credentials = .ticketCache,
                                        _ body: () async throws -> T) async throws -> T {
        await KerberosTurn.shared.acquire()
        do {
            setenv("KRB5_CONFIG", configurationPath, 1)
            // A cache of its own per call: a failed GSS login can destroy the cache it used.
            let cachePath = ticketCachePath + "-" + UUID().uuidString.prefix(8)
            defer { try? FileManager.default.removeItem(atPath: cachePath) }
            switch credentials {
            case .ticketCache: try await logIn(password: password, cachePath: cachePath)
            case .password: setenv("KRB5CCNAME", "MEMORY:serverlab-\(UUID().uuidString.prefix(8))", 1)
            }
            let result = try await body()
            if credentials == .password { removeCollectionTickets() }
            await KerberosTurn.shared.release()
            return result
        } catch {
            if credentials == .password { removeCollectionTickets() }
            await KerberosTurn.shared.release()
            throw error
        }
    }

    /// A driver's password login stores its ticket in the user's credential collection; remove the
    /// lab user's so the machine's own Kerberos setup is left as it was.
    func removeCollectionTickets() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/kdestroy")
        process.arguments = ["-p", userPrincipal]
        var environment = ProcessInfo.processInfo.environment
        environment["KRB5CCNAME"] = nil
        process.environment = environment
        process.standardError = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    /// The lab's ticket cache on this machine.
    public var ticketCachePath: String {
        ((configurationPath as NSString).deletingLastPathComponent as NSString).appendingPathComponent("krb5cc_lab")
    }

    /// `kinit`s the domain user into the lab's ticket cache and points this process at it
    /// (`KRB5_CONFIG`, `KRB5CCNAME`). Returns the cache name. macOS only.
    @discardableResult
    public func logIn(password: String, cachePath: String? = nil) async throws -> String {
        let cache = "FILE:\(cachePath ?? ticketCachePath)"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/kinit")
        // -c: with a cache for the principal already in the user's collection, macOS kinit would
        // ignore KRB5CCNAME and write there.
        process.arguments = ["-c", cache, "--password-file=STDIN", userPrincipal]
        var environment = ProcessInfo.processInfo.environment
        environment["KRB5_CONFIG"] = configurationPath
        environment["KRB5CCNAME"] = cache
        process.environment = environment
        let input = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: Data(password.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: (try? errors.fileHandleForReading.readToEnd()) ?? Data(), as: UTF8.self)
            throw ServerLabError.notReady("kinit \(userPrincipal)", lastError: message)
        }
        setenv("KRB5_CONFIG", configurationPath, 1)
        setenv("KRB5CCNAME", cache, 1)
        return cache
    }
}

/// One Kerberos login at a time in this process (see `LabKerberosInfo.withTicket`).
actor KerberosTurn {
    static let shared = KerberosTurn()
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if busy {
            await withCheckedContinuation { waiting.append($0) }
        }
        busy = true
    }

    func release() {
        if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
    }
}
