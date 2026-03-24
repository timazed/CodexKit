// swift-tools-version: 6.0
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
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.10.0"),
    ],
    targets: [
        .target(
            name: "CodexKit",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .target(
            name: "CodexKitUI",
            dependencies: ["CodexKit"]
        ),
        .testTarget(
            name: "CodexKitTests",
            dependencies: ["CodexKit", "CodexKitUI"]
        ),
    ]
)
