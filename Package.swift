// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "echo-server-lab",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ServerLabKit", targets: ["ServerLabKit"]),
        .library(name: "ServerLabCatalog", targets: ["ServerLabCatalog"]),
        .library(name: "ServerLabTesting", targets: ["ServerLabTesting"]),
        // For test targets that must not link the lab or its drivers (Echo): talks to the serverlab tool.
        .library(name: "ServerLabClient", targets: ["ServerLabClient"]),
        .executable(name: "serverlab", targets: ["serverlab"]),
    ],
    dependencies: [
        .package(url: "https://github.com/tashda/sqlserver-nio", branch: "dev"),
        .package(url: "https://github.com/tashda/postgres-wire", branch: "dev"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.4"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        // Recipes, Docker, seeded images and server lifetimes. Knows no database driver.
        .target(
            name: "ServerLabKit",
            dependencies: [.product(name: "Logging", package: "swift-log")]
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
        // The standard lab: every engine plus the recipes shipped in Recipes/.
        .target(
            name: "ServerLabCatalog",
            dependencies: ["ServerLabKit", "ServerLabSQLServer", "ServerLabPostgres"],
            resources: [.copy("Recipes")]
        ),
        // Swift Testing trait: @Suite(.server("recipe-name")).
        .target(
            name: "ServerLabTesting",
            dependencies: ["ServerLabCatalog"]
        ),
        .target(name: "ServerLabClient"),
        .executableTarget(
            name: "serverlab",
            dependencies: ["ServerLabCatalog", .product(name: "ArgumentParser", package: "swift-argument-parser")]
        ),
        .testTarget(
            name: "ServerLabKitTests",
            dependencies: ["ServerLabKit", "ServerLabCatalog"]
        ),
        .testTarget(
            name: "ServerLabIntegrationTests",
            dependencies: [
                "ServerLabTesting",
                .product(name: "SQLServerKit", package: "sqlserver-nio"),
                .product(name: "PostgresKit", package: "postgres-wire"),
            ]
        ),
    ]
)
