// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Danotch",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/httpswift/swifter.git", from: "1.5.0")
    ],
    targets: [
        .executableTarget(
            name: "Danotch",
            dependencies: [
                .product(name: "Swifter", package: "swifter")
            ],
            path: "Sources",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
