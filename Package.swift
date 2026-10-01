// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "echo-server-lab",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "ServerLabKit", targets: ["ServerLabKit"]),
        .library(name: "ServerLabCatalog", targets: ["ServerLabCatalog"]),
        .library(name: "ServerLabTesting", targets: ["ServerLabTesting"]),
        .library(name: "ServerLabWorkloads", targets: ["ServerLabWorkloads"]),
        // For test targets that must not link the lab or its drivers (Echo): talks to the serverlab tool.
        .library(name: "ServerLabClient", targets: ["ServerLabClient"]),
        // The TDS protocol reference and a decoder that explains TDS bytes (was the tds-mcp repo).
        .library(name: "TDSSpec", targets: ["TDSSpec"]),
        .executable(name: "tds-mcp", targets: ["tds-mcp"]),
        .executable(name: "serverlab", targets: ["serverlab"]),
    ],
    dependencies: [
        .package(url: "https://github.com/tashda/sqlserver-nio", branch: "dev"),
        .package(url: "https://github.com/tashda/postgres-wire", branch: "dev"),
        .package(url: "https://github.com/tashda/mysql-wire", branch: "dev"),
        // SQLite files are made through sqlite-nio (no first-party SQLite driver), as Echo uses it.
        .package(url: "https://github.com/vapor/sqlite-nio", from: "1.12.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.4"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.10.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        // Recipes, Docker, seeded images and server lifetimes. Knows no database driver.
        .target(
            name: "ServerLabKit",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "CryptoExtras", package: "swift-crypto"),
                "WireExplanation",
                "TDSSpec",
                "PostgresProtocol",
                "MySQLProtocol",
            ]
        ),
        // SQL Server: container settings, readiness and content packs, through SQLServerKit only.
        .target(
            name: "ServerLabSQLServer",
            dependencies: ["ServerLabKit", .product(name: "SQLServerKit", package: "sqlserver-nio")]
        ),
        // PostgreSQL: container settings, readiness and content packs, through PostgresKit only.
        .target(
            name: "ServerLabPostgres",
            dependencies: ["ServerLabKit", .product(name: "PostgresKit", package: "postgres-wire")]
        ),
        // MySQL and MariaDB: container settings, readiness and content packs, through MySQLKit only.
        .target(
            name: "ServerLabMySQL",
            dependencies: ["ServerLabKit", .product(name: "MySQLKit", package: "mysql-wire")]
        ),
        // SQLite fixture files, built locally through sqlite-nio.
        .target(
            name: "ServerLabSQLite",
            dependencies: ["ServerLabKit", .product(name: "SQLiteNIO", package: "sqlite-nio")]
        ),
        // The standard lab: every engine plus the recipes shipped in Recipes/.
        .target(
            name: "ServerLabWorkloads",
            dependencies: ["ServerLabKit", .product(name: "SQLServerKit", package: "sqlserver-nio"),
                           .product(name: "PostgresKit", package: "postgres-wire"),
                           .product(name: "MySQLKit", package: "mysql-wire")]
        ),
        .target(
            name: "ServerLabCatalog",
            dependencies: ["ServerLabKit", "ServerLabSQLServer", "ServerLabPostgres", "ServerLabMySQL", "ServerLabSQLite", "ServerLabWorkloads"],
            resources: [.copy("Recipes")]
        ),
        // Swift Testing trait: @Suite(.server("recipe-name")).
        .target(
            name: "ServerLabTesting",
            dependencies: ["ServerLabCatalog", "ServerLabWorkloads"]
        ),
        .target(name: "ServerLabClient"),
        // Field trees for decoded protocol messages, shared by the TDS and PostgreSQL decoders.
        .target(name: "WireExplanation"),
        .target(name: "TDSSpec", dependencies: ["WireExplanation"], resources: [.copy("Resources/spec")]),
        // PostgreSQL frontend/backend protocol decoder.
        .target(name: "PostgresProtocol", dependencies: ["WireExplanation"]),
        // MySQL and MariaDB client/server protocol decoder.
        .target(name: "MySQLProtocol", dependencies: ["WireExplanation"]),
        // MCP server (stdio) over TDSSpec, and over lab captures through ServerLabKit.
        .executableTarget(name: "tds-mcp", dependencies: ["TDSSpec", "ServerLabCatalog"]),
        .testTarget(name: "TDSSpecTests", dependencies: ["TDSSpec", "PostgresProtocol", "MySQLProtocol"]),
        .executableTarget(
            name: "serverlab",
            dependencies: ["ServerLabCatalog", .product(name: "ArgumentParser", package: "swift-argument-parser")]
        ),
        .testTarget(
            name: "ServerLabKitTests",
            dependencies: ["ServerLabKit", "ServerLabCatalog", .product(name: "X509", package: "swift-certificates"),
                           .product(name: "SQLiteNIO", package: "sqlite-nio")]
        ),
        .testTarget(
            name: "ServerLabClientTests",
            dependencies: ["ServerLabClient", .product(name: "PostgresKit", package: "postgres-wire")]
        ),
        .testTarget(
            name: "ServerLabIntegrationTests",
            dependencies: [
                "ServerLabWorkloads",
                "ServerLabTesting",
                .product(name: "MySQLKit", package: "mysql-wire"),
                .product(name: "SQLServerKit", package: "sqlserver-nio"),
                .product(name: "PostgresKit", package: "postgres-wire"),
            ]
        ),
    ]
)
