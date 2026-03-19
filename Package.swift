// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ios-agentsdk",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "AssistantRuntimeKit",
            targets: ["AssistantRuntimeKit"]
        ),
        .library(
            name: "AssistantRuntimeDemo",
            targets: ["AssistantRuntimeDemo"]
        ),
    ],
    targets: [
        .target(
            name: "AssistantRuntimeKit"
        ),
        .target(
            name: "AssistantRuntimeDemo",
            dependencies: ["AssistantRuntimeKit"]
        ),
        .testTarget(
            name: "AssistantRuntimeKitTests",
            dependencies: ["AssistantRuntimeKit", "AssistantRuntimeDemo"]
        ),
    ]
)
