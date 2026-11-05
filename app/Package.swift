// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EOU",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "EOU",
            path: "Sources/EOU",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("Carbon")]
        )
    ]
)
