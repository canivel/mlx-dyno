// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Dyno",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "DynoKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Dyno",
            dependencies: ["DynoKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "probe",
            dependencies: ["DynoKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
