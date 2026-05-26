// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GrokestratorCore",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "GrokestratorCore",
            targets: ["GrokestratorCore"]
        ),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "GrokestratorCore",
            dependencies: []
        ),
        .testTarget(
            name: "GrokestratorCoreTests",
            dependencies: ["GrokestratorCore"]
        ),
    ]
)
