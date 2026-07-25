// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Perch",
    platforms: [
        .macOS("26.0")
    ],
    // Source distributions are arm64-only. Invoke SwiftPM with
    // `--triple arm64-apple-macosx26.0`; build.sh enforces the same Xcode arch.
    dependencies: [],
    targets: [
        .target(
            name: "ExecutorCore",
            path: "Sources/Executor",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .executableTarget(
            name: "Perch",
            dependencies: ["ExecutorCore"],
            path: "Sources",
            exclude: ["Executor", "ExecutorService"],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .executableTarget(
            name: "PerchDaemonHost",
            path: "DaemonHost",
            linkerSettings: [
                .linkedFramework("Security")
            ]
        ),
        .testTarget(
            name: "PerchTests",
            dependencies: ["Perch", "ExecutorCore"],
            path: "Tests/PerchTests",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
