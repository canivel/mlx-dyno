// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MLXStation",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "MLXStationKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "MLXStation",
            dependencies: ["MLXStationKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "probe",
            dependencies: ["MLXStationKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
