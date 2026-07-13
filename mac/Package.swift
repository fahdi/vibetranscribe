// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "VibeTranscribe",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "VibeTranscribe",
            path: "Sources/VibeTranscribe"
        )
    ]
)
