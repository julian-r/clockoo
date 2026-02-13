// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "Clockoo",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "Clockoo",
            path: "Sources/Clockoo"
        )
    ]
)
