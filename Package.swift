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
    targets: [
        .target(
            name: "CodexKit"
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
