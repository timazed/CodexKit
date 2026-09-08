// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "CodexKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CodexKit",
            targets: ["CodexKit"]
        ),
        .library(
            name: "CodexKitUI",
            targets: ["CodexKitUI"]
        ),
        .library(
            name: "CodexKitSQLite",
            targets: ["CodexKitSQLite"]
        ),
        .library(
            name: "CodexKitRealm",
            targets: ["CodexKitRealm"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.10.0"),
        .package(url: "https://github.com/realm/realm-swift.git", from: "20.0.5"),
    ],
    targets: [
        .target(
            name: "CodexKit",
            dependencies: [],
            path: "Sources/CodexKit"
        ),
        .target(
            name: "CodexKitSQLite",
            dependencies: [
                "CodexKit",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/CodexKitSQLite"
        ),
        .target(
            name: "CodexKitRealm",
            dependencies: [
                "CodexKit",
                .product(name: "RealmSwift", package: "realm-swift"),
            ],
            path: "Sources/CodexKitRealm"
        ),
        .target(
            name: "CodexKitUI",
            dependencies: ["CodexKit"],
            path: "Sources/CodexKitUI"
        ),
        .testTarget(
            name: "CodexKitTests",
            dependencies: ["CodexKit", "CodexKitUI", "CodexKitSQLite", "CodexKitRealm"],
            path: "Tests/CodexKitTests"
        ),
    ]
)
