// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "StenoDrop",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "StenoDrop",
            path: "Sources/StenoDrop"
        ),
        .testTarget(
            name: "StenoDropTests",
            dependencies: ["StenoDrop"],
            path: "Tests/StenoDropTests"
        ),
    ]
)
