// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "DyskShot",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "DyskShot",
            path: "Sources/DyskShot",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
