// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RealtimeTranslator",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "RealtimeTranslator",
            path: "Sources/RealtimeTranslator"
        )
    ]
)
