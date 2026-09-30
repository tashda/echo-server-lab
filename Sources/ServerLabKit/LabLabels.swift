import Foundation

/// Docker labels the lab puts on its containers and images. Docker is the only record of what runs.
public enum LabLabels {
    public static let managed = "dev.echodb.lab.managed"
    /// `builder` (seeding a recipe), `server` (in use by a suite) or `seeded` (a saved image).
    public static let role = "dev.echodb.lab.role"
    public static let recipe = "dev.echodb.lab.recipe"
    public static let fingerprint = "dev.echodb.lab.fingerprint"
    public static let engine = "dev.echodb.lab.engine"
    public static let version = "dev.echodb.lab.version"
    /// Unix time after which `reapExpired` removes the container.
    public static let expires = "dev.echodb.lab.expires"
    /// Who asked for the server (a suite name, `cli`, `echo-labs`).
    public static let owner = "dev.echodb.lab.owner"
    /// The main container's name, on every container of a server (and its network).
    public static let server = "dev.echodb.lab.server"
    /// The part a container plays in its server: `server`, `primary`, `standby`, ….
    public static let part = "dev.echodb.lab.part"
    /// `<mode>/<certificate>` on servers started with TLS, so tools that did not start them can connect.
    public static let tls = "dev.echodb.lab.tls"

    enum Role: String {
        case builder, server, seeded
    }

    static func arguments(_ labels: [String: String]) -> [String] {
        labels.sorted { $0.key < $1.key }.flatMap { ["--label", "\($0.key)=\($0.value)"] }
    }
}
