import Foundation

/// A third-party sample database file the lab can load. Files live on the lab host in
/// `LabHost.samplesDirectory` and are mirrored in the `samples-v1` release of tashda/echo-server-lab.
public struct LabSample: Sendable, Hashable {
    public var file: String
    public var source: URL
    public var sha256: String
    public var bytes: Int

    public init(file: String, source: String, sha256: String, bytes: Int) {
        self.file = file
        self.source = URL(string: source) ?? URL(fileURLWithPath: "/")
        self.sha256 = sha256
        self.bytes = bytes
    }
}

public enum LabSamples {
    /// Where samples appear inside builder containers (mounted read-only).
    public static let containerDirectory = "/samples"

    public static let all: [LabSample] = [
        LabSample(file: "AdventureWorks2017.bak",
                  source: "https://github.com/microsoft/sql-server-samples/releases/download/adventureworks/AdventureWorks2017.bak",
                  sha256: "449b862f7f8f16f5b984f85d17692a225299df1870372a9f8e50f99073b26e33", bytes: 50_286_592),
        LabSample(file: "AdventureWorksLT2017.bak",
                  source: "https://github.com/microsoft/sql-server-samples/releases/download/adventureworks/AdventureWorksLT2017.bak",
                  sha256: "b3e1bb04621a07aa35bf6f65e5351ee874d770620e83040dfa23e53135573377", bytes: 7_458_816),
        LabSample(file: "AdventureWorksDW2017.bak",
                  source: "https://github.com/microsoft/sql-server-samples/releases/download/adventureworks/AdventureWorksDW2017.bak",
                  sha256: "4856ce6ddbe36e3566594c39f8b67539071c8ffe8f91c5ad62c2c0c860033a5a", bytes: 23_436_800),
        LabSample(file: "WideWorldImporters-Full.bak",
                  source: "https://github.com/microsoft/sql-server-samples/releases/download/wide-world-importers-v1.0/WideWorldImporters-Full.bak",
                  sha256: "e842bad6ce02f74f166947e559dab1b476edd7eaae3da2ab9e3f522f1dd87124", bytes: 127_111_168),
        LabSample(file: "instnwnd.sql",
                  source: "https://raw.githubusercontent.com/microsoft/sql-server-samples/master/samples/databases/northwind-pubs/instnwnd.sql",
                  sha256: "3cc62b3fca6d244a47dbde698b809331e4f85988a0685b2b370717d431e94871", bytes: 1_049_720),
        LabSample(file: "instpubs.sql",
                  source: "https://raw.githubusercontent.com/microsoft/sql-server-samples/master/samples/databases/northwind-pubs/instpubs.sql",
                  sha256: "c66479d429f482ef788290dd94bb315f2277327765f480b2b21be6f359eb4bad", bytes: 125_718),
        LabSample(file: "pagila-schema.sql",
                  source: "https://raw.githubusercontent.com/devrimgunduz/pagila/master/pagila-schema.sql",
                  sha256: "071ee940a73c8f4fad2997185788065291607e2c55559e3747959e8275391536", bytes: 89_841),
        LabSample(file: "pagila-data.sql",
                  source: "https://raw.githubusercontent.com/devrimgunduz/pagila/master/pagila-data.sql",
                  sha256: "a88efa94c7ae8bc9cf55def4efc9f164d064d5b9cd93f11719ba3b5ace1602f7", bytes: 13_074_106),
        LabSample(file: "Chinook_PostgreSql.sql",
                  source: "https://github.com/lerocha/chinook-database/releases/download/v1.4.5/Chinook_PostgreSql.sql",
                  sha256: "e3fde5c1a5b51a2a91429a702c9ca6e69ba56e6c7f5e112724d70c3d03db695e", bytes: 600_200),
    ]

    public static func sample(named file: String) throws -> LabSample {
        guard let sample = all.first(where: { $0.file == file }) else {
            throw ServerLabError.invalidParameter("sample file \(file)", expected: "one of \(all.map(\.file).joined(separator: ", "))")
        }
        return sample
    }
}

/// What a pack gets besides the server: a progress log and access to sample files.
public struct PackContext: Sendable {
    public let log: LabLog
    /// Reads a sample's text from the lab host (for script samples).
    public let sampleText: @Sendable (_ file: String) async throws -> String

    public init(log: @escaping LabLog, sampleText: @escaping @Sendable (_ file: String) async throws -> String) {
        self.log = log
        self.sampleText = sampleText
    }
}
