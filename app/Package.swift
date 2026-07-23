// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Perch",
    platforms: [
        .macOS(.v14)
    ],
    // SwiftPM has one deployment floor for the whole package. The macOS 26
    // executor and its exact Containerization dependency are therefore wired
    // only in Perch.xcodeproj; raising this package would silently drop the
    // main app's macOS 14 support.
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
