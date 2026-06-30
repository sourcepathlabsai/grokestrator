// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GrokestratorCore",
    platforms: [
        .macOS(.v15),
        .iOS(.v18)
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
            dependencies: [],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .testTarget(
            name: "GrokestratorCoreTests",
            dependencies: ["GrokestratorCore"]
        ),
    ]
)
